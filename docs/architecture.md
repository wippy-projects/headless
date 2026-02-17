# Architecture

## Process Model

The SDK uses three layers of processes to bridge user code and the Chrome browser:

```
Wippy Runtime
├── User Process A ─── Tab object (in-memory) ───┐
├── User Process B ─── Tab object (in-memory) ───┤  process.send()
├── User Process C ─── Tab object (in-memory) ───┤
│                                                 ▼
├── Connection Manager Process (singleton service)
│       │
│       │  WebSocket (JSON-RPC)
│       ▼
│   Chromium (headless)
│   ├── BrowserContext 1 → Target 1 → Session 1
│   ├── BrowserContext 2 → Target 2 → Session 2
│   └── BrowserContext 3 → Target 3 → Session 3
```

### User Process

The process where your Lua code runs. It holds a `Tab` object, which is a lightweight handle that sends messages to the
manager and waits for replies. The Tab itself does not own any connection — it only knows the manager's PID and its CDP
session ID.

### Connection Manager

A singleton process registered in the Wippy process registry as `headless.manager`. It is auto-started as a supervised
service (restarts up to 5 times with exponential backoff).

Responsibilities:

- **Owns the single WebSocket** connection to Chrome's CDP endpoint
- **Multiplexes CDP sessions** — routes commands from many Tab objects to the correct `sessionId`
- **Forwards CDP events** from Chrome back to the owning Tab process
- **Monitors owner processes** — auto-closes tabs when owner exits (via `process.monitor`)
- **Enforces max tabs** — queues excess requests and serves them as slots free up
- **Health checks** — periodically pings Chrome, reconnects on disconnect

### Chrome (CDP)

Headless Chromium with remote debugging enabled. Each tab in the SDK maps to three CDP objects:

| CDP Object     | Purpose                                          |
|----------------|--------------------------------------------------|
| BrowserContext | Isolated environment (separate cookies, storage) |
| Target         | A page (tab) within the context                  |
| Session        | A debugging session attached to the target       |

---

## How URL Navigation Works

When you call `tab:goto("https://example.com")`, the request travels through the full process chain. Here is the
step-by-step flow:

### Step 1 — Tab sends command to the Manager

`tab:goto(url)` calls `tab:send_command("Page.navigate", { url = url })`, which:

1. Creates a reply listener on topic `"tab.command.reply"`
2. Sends a message to the manager via `process.send()`:
   ```
   topic:   "tab.command"
   payload: { sender_pid, session_id, method="Page.navigate", params={url=...}, timeout }
   ```
3. Blocks the current process via `channel.select` waiting for a reply or timeout

### Step 2 — Manager routes command to Chrome

The manager's main event loop receives the `"tab.command"` message and:

1. Verifies the session exists in its tab registry
2. Checks that the CDP WebSocket is alive
3. Calls `conn:send("Page.navigate", params, session_id, timeout)`
4. Sends the result back via `process.send(sender, "tab.command.reply", { result, error })`

### Step 3 — CDP connection encodes and sends

`conn:send()` in `cdp_connection.lua`:

1. Encodes the command as JSON-RPC: `{"id": N, "method": "Page.navigate", "params": {...}, "sessionId": "..."}`
2. Sends the JSON over WebSocket
3. Pumps the WebSocket in a loop, processing incoming messages:
    - **Matching response** (same `id`) — returns immediately
    - **Other responses** — buffered for their callers
    - **Events** — dispatched to per-session subscriber channels

### Step 4 — Chrome responds

Chrome sends back two things:

1. **Immediate response** — `{"id": N, "result": {"frameId": "...", "loaderId": "..."}}` — confirming navigation started
2. **Load event** (later) — `{"method": "Page.loadEventFired", "params": {...}, "sessionId": "..."}` — page finished
   loading

### Step 5 — Tab waits for page load

After receiving the `Page.navigate` response, `tab:goto()` calls `wait_for_event("Page.loadEventFired")`, which:

1. Listens on the `"tab.cdp_event"` topic
2. Blocks via `channel.select` until the matching event arrives or timeout
3. While waiting, handles inline events (e.g., `Fetch.requestPaused` for resource blocking)

### Step 6 — Manager forwards the load event

When the CDP connection receives `Page.loadEventFired`:

1. It dispatches the event to the session's subscriber channel
2. The manager's event loop picks it up from the per-tab event channel
3. The manager forwards it via `process.send(owner_pid, "tab.cdp_event", event)`

### Step 7 — Tab returns the result

The Tab's `wait_for_event` receives the forwarded event, and `tab:goto()` returns:

```lua
{
    url = "https://example.com",
    frame_id = "ABC123",
    loader_id = "DEF456",
}
```

### Sequence Diagram

```
User Process              Manager Process            CDP Connection            Chrome
     │                         │                          │                      │
     │ tab:goto(url)           │                          │                      │
     │                         │                          │                      │
     │ send_command()          │                          │                      │
     │ ─"tab.command"────────> │                          │                      │
     │ [blocks on reply]       │                          │                      │
     │                         │ conn:send()              │                      │
     │                         │ ───────────────────────> │                      │
     │                         │                          │ ws:send(JSON)        │
     │                         │                          │ ───────────────────> │
     │                         │                          │                      │
     │                         │                          │ <── response {id, result}
     │                         │                          │ (pump returns)       │
     │                         │ <─── result ──────────── │                      │
     │                         │                          │                      │
     │ <─"tab.command.reply"── │                          │                      │
     │                         │                          │                      │
     │ wait_for_event()        │                          │                      │
     │ [blocks on cdp_event]   │                          │                      │
     │                         │                          │                      │
     │                         │                          │ <── Page.loadEventFired
     │                         │                          │ dispatch_event()     │
     │                         │ <── event channel ────── │                      │
     │                         │                          │                      │
     │ <─"tab.cdp_event"────── │                          │                      │
     │                         │                          │                      │
     │ return { url,           │                          │                      │
     │   frame_id, loader_id } │                          │                      │
```

---

## Message Protocol

### User Process → Manager

| Topic         | Payload                                        | Purpose             |
|---------------|------------------------------------------------|---------------------|
| `tab.create`  | `{ sender_pid, options }`                      | Create a new tab    |
| `tab.command` | `{ sender_pid, sid, method, params, timeout }` | Execute CDP command |
| `tab.close`   | `{ sid }`                                      | Close a tab         |

### Manager → User Process

| Topic               | Payload                                          | Purpose              |
|---------------------|--------------------------------------------------|----------------------|
| `tab.created`       | `{ session_id, target_id, context_id, options }` | Tab creation result  |
| `tab.command.reply` | `{ result, error }`                              | CDP command response |
| `tab.cdp_event`     | `{ method, params, session_id }`                 | CDP event forwarding |

---

## Tab Creation Flow

When `browser.new_tab()` is called, the manager creates three CDP objects:

```
1. Target.createBrowserContext({ disposeOnDetach = true })
   └─ Returns: browserContextId

2. Target.createTarget({ url = "about:blank", browserContextId = ... })
   └─ Returns: targetId

3. Target.attachToTarget({ targetId = ..., flatten = true })
   └─ Returns: sessionId

4. Enable domains: Page, Runtime, Network, DOM
```

The manager then:

- Stores the tab in its registry: `tabs[session_id] = { session_id, target_id, context_id, owner_pid }`
- Subscribes to CDP events for this session
- Monitors the owner process for EXIT events
- Sends the `"tab.created"` reply

---

## Tab Cleanup

Tabs are cleaned up in three scenarios:

1. **Explicit close** — `tab:close()` sends `"tab.close"` to the manager
2. **Owner process exit** — the manager detects it via `process.monitor` and auto-closes all tabs owned by that PID
3. **Chrome disconnect** — the manager invalidates all tabs and attempts reconnection

Cleanup steps:

```
1. Target.closeTarget({ targetId = ... })
2. Target.disposeBrowserContext({ browserContextId = ... })
3. Remove from tab registry
4. Unsubscribe from CDP events
5. Serve any queued waiters (if max_tabs is set)
```

---

## Health Checks and Reconnection

The manager runs a periodic health check (default: every 30 seconds):

1. Sends `Browser.getVersion` via CDP
2. If it fails or the WebSocket drops, attempts reconnection
3. Reconnection: HTTP GET to `http://<chrome_address>/json/version` → WebSocket connect
4. On reconnect, all existing tabs are invalidated (sessions are lost)
5. If reconnection fails after 5 attempts, the manager process exits and the supervisor restarts it
