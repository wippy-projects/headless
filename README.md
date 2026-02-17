# Headless Browser SDK

A low-level Lua SDK for controlling headless Chromium via Chrome DevTools Protocol (CDP), designed for web scraping,
document extraction, and browser automation tasks within the Wippy runtime.

Each Wippy process gets its own isolated browser tab, enabling natural parallelism through the actor model — spawn N
processes, get N concurrent browser sessions.

## Features

- **Tab-per-process isolation** — incognito-like browser contexts with independent cookies, storage, and cache
- **Non-blocking connection manager** — async CDP command routing, concurrent tabs never block each other
- **Full navigation control** — goto, reload, back/forward, wait for load/network idle
- **Element interaction** — click, type, select dropdowns, check/uncheck, hover, focus, upload files
- **Content extraction** — text, attributes, values, visibility checks, element counting
- **JavaScript execution** — sync and async eval with argument passing
- **Screenshots & PDF** — viewport, element, full-page screenshots; PDF generation with paper size and margin options
- **Download interception** — capture file downloads in-memory without disk I/O, detects by content-disposition and
  content-type (PDF, ZIP, binary, etc.)
- **Resource blocking** — block images, stylesheets, fonts, etc. for faster scraping
- **Connection pooling** — max tabs enforcement with backpressure and automatic queuing
- **Fault tolerance** — automatic Chrome disconnect detection, tab cleanup on process exit, supervisor-friendly

## Documentation

- [API Reference](docs/api-reference.md) — full method signatures, parameters, return types, and examples
- [Architecture](docs/architecture.md) — process model, navigation flow, message protocol, tab lifecycle
- [Error Handling](docs/error-handling.md) — error types, CDP error mapping, handling patterns

## Requirements

- Wippy runtime
- Chromium with remote debugging enabled (Docker recommended)

## Chrome Setup

### Docker (recommended)

```bash
docker run -d \
  --name chrome-headless \
  -p 9222:9222 \
  --shm-size=2g \
  docker.io/chromedp/headless-shell:latest\
  --no-sandbox \
  --disable-gpu \
  --remote-debugging-address=0.0.0.0 \
  --remote-debugging-port=9222
```

### System Chrome

```bash
google-chrome \
  --headless=new \
  --disable-gpu \
  --remote-debugging-port=9222
```

## Installation

Add the dependency to your project's `_index.yaml`:

```yaml
- name: dependency.headless
  kind: ns.dependency
  component: userspace/headless
  version: ">=0.1.0"
```

### Configuration Requirements

| Requirement      | Default          | Description                             |
|------------------|------------------|-----------------------------------------|
| `chrome_address` | `localhost:9222` | CDP endpoint address                    |
| `process_host`   | `app:processes`  | Process host for the connection manager |

Override in your `_index.yaml`:

```yaml
- name: headless.chrome_address
  kind: ns.requirement.value
  value: "chrome-host:9222"
```

## Quick Start

### Registry

```yaml
version: "1.0"
namespace: app

entries:
  - name: processes
    kind: process.host
    host:
      workers: 16
    lifecycle:
      auto_start: true

  - name: my_scraper
    kind: function.lua
    source: file://scraper.lua
    method: main
    modules: [ browser, json, store ]
```

### Lua

```lua
local browser = require("browser")

local function main()
    local tab, err = browser.new_tab("app:chrome")
    if err then return nil, err end

    tab:goto("https://example.com")
    tab:wait_for_selector("h1")

    local title = tab:text("h1")
    print("Title:", title)

    tab:close()
    return 0
end

return { main = main }
```

## API Reference

See the full [API Reference](docs/api-reference.md) for all methods with parameters, return types, and examples.

### Quick Overview

```lua
local browser = require("browser")
local tab, err = browser.new_tab()

-- Navigation
tab:goto(url)                    tab:reload()
tab:back()                       tab:forward()
tab:url()                        tab:wait_for_navigation()

-- Waiting
tab:wait_for_selector(sel)       tab:wait_for_function(js_fn)
tab:wait_for_network_idle()

-- Content extraction
tab:content()                    tab:text(sel)
tab:text_all(sel)                tab:attribute(sel, attr)
tab:attribute_all(sel, attr)     tab:value(sel)
tab:is_visible(sel)              tab:exists(sel)
tab:is_enabled(sel)              tab:is_checked(sel)
tab:count(sel)

-- Interaction
tab:click(sel)                   tab:type(sel, text)
tab:press(key)                   tab:select(sel, value)
tab:check(sel)                   tab:uncheck(sel)
tab:hover(sel)                   tab:focus(sel)
tab:upload(sel, path)

-- JavaScript
tab:eval(expr, ...)              tab:eval_async(expr)

-- Capture
tab:screenshot()                 tab:pdf()
tab:expect_download(fn)

-- Configuration
tab:set_viewport(w, h)           tab:set_user_agent(ua)
tab:set_headers(h)               tab:set_timeout(t)
tab:block_resources(types)

-- Lifecycle
tab:close()                      tab:is_alive()
tab:session_id()

-- Low-level
tab:send_command(method, params)
```

---

## How Navigation Works

This section explains what happens internally when you call `tab:goto(url)`. Understanding the flow helps with debugging
and tuning timeouts.

### Processes Involved

| Process                | Role                                                                 |
|------------------------|----------------------------------------------------------------------|
| **User process**       | Your Lua code. Holds a `Tab` object (lightweight handle)             |
| **Connection Manager** | Singleton service (`headless.manager`). Owns the WebSocket to Chrome |
| **Chrome**             | Headless Chromium. Executes page loads via CDP                       |

### Flow

```
User Process              Manager Process            Chrome (CDP)
     │                         │                          │
     │  tab:goto(url)          │                          │
     │                         │                          │
     │  ─"tab.command"───────> │                          │
     │   method=Page.navigate  │                          │
     │   params={url=...}      │                          │
     │   [blocks on reply]     │                          │
     │                         │  conn:send_async(...)    │
     │                         │  ──────────────────────> │
     │                         │  (non-blocking, manager  │  start loading page
     │                         │   continues event loop)  │
     │                         │                          │
     │                         │  <── {id, result} ────── │
     │                         │  route_response() →      │
     │  <─"tab.command.reply"─ │                          │
     │   result.frameId        │                          │
     │   result.loaderId       │                          │
     │                         │                          │
     │  wait_for_event(        │                          │
     │   "Page.loadEventFired")│                          │
     │  [blocks on cdp_event]  │                          │  page finishes loading
     │                         │                          │
     │                         │  <── Page.loadEventFired │
     │                         │  (event dispatched to    │
     │                         │   session subscriber)    │
     │                         │                          │
     │  <─"tab.cdp_event"───── │                          │
     │   Page.loadEventFired   │                          │
     │                         │                          │
     │  return {url,           │                          │
     │    frame_id, loader_id} │                          │
```

**Step by step:**

1. `tab:goto(url)` calls `tab:send_command("Page.navigate", {url})`, which sends a `"tab.command"` message to the
   connection manager via `process.send()` and blocks the user process waiting for a `"tab.command.reply"`.

2. The manager receives the command in its event loop and forwards it to Chrome via `conn:send_async()` — a non-blocking
   call that sends the CDP command and tracks the response by ID. The manager's event loop continues processing other
   events immediately.

3. Chrome starts loading the page and responds with a result containing `frameId` and `loaderId`. The manager receives
   the response on the WebSocket channel, matches it to the pending command, and forwards it to the user process.

4. `tab:goto()` then calls `wait_for_event("Page.loadEventFired")`, which blocks the user process again, now waiting for
   a `"tab.cdp_event"` message.

5. When Chrome finishes loading the page, it emits a `Page.loadEventFired` event over the WebSocket. The CDP connection
   dispatches it to the session's subscriber channel. The manager picks it up and forwards it to the tab's owner
   process.

6. The tab receives the event, and `tab:goto()` returns `{ url, frame_id, loader_id }` to the caller.

If anything fails — DNS error, SSL error, timeout — an error string is returned instead.
See [Error Handling](docs/error-handling.md) for all error types.

For a deeper dive into the architecture, message protocol, and tab lifecycle, see [Architecture](docs/architecture.md).

---

## Download Interception

`expect_download` intercepts file downloads in-memory by pausing responses at the CDP Fetch layer.

### Detection

A response is recognized as a download if any of these conditions are met:

- `Content-Disposition` header contains `attachment` or a `filename` parameter
- `Content-Type` is a known binary/document type: `application/pdf`, `application/octet-stream`, `application/zip`, etc.

### Error Propagation

If the action function returns an error (e.g. element not found), `expect_download` fails immediately instead of
waiting for timeout. Use `return` in the action function:

```lua
local dl, err = tab:expect_download(function()
    return tab:click("#download-btn")
end, { timeout = "30s" })
```

### JavaScript Click

For buttons with JavaScript event handlers, use `tab:eval()` to trigger the click directly — CDP mouse events may not
always fire JS handlers:

```lua
local dl, err = tab:expect_download(function()
    return tab:eval([[
        document.querySelector('#download-btn').click()
    ]])
end, { timeout = "30s" })
```

---

## Concurrency Patterns

### Parallel Scraping (Tab-per-Process)

```lua
-- supervisor.lua
local function main()
    local urls = {
        "https://site-a.com",
        "https://site-b.com",
        "https://site-c.com",
    }

    local children = {}
    for _, url in ipairs(urls) do
        local pid = process.spawn_monitored(
            "app:scraper_process", "app:processes", url
        )
        table.insert(children, pid)
    end

    local events = process.events()
    local results = {}

    while #results < #urls do
        local event = events:receive()
        if event.kind == process.event.EXIT then
            table.insert(results, event.result)
        end
    end

    return results
end
```

```lua
-- scraper.lua
local browser = require("browser")

local function main(url)
    local tab, err = browser.new_tab("app:chrome")
    if err then return nil, err end

    tab:goto(url)
    tab:wait_for_selector("#content")
    local data = tab:text("#content")

    tab:close()
    return data
end

return { main = main }
```

### Max Tabs Backpressure

When `max_tabs` is configured and all slots are in use, `browser.new_tab()` blocks the calling process until a tab is
released. If no tab becomes available within 30 seconds, an error is returned.

```lua
-- The 6th call blocks until one of the first 5 tabs closes
local tab, err = browser.new_tab("app:chrome")
-- err = "TIMEOUT: Tab creation timed out after 30s"
```

---

## Error Handling

All fallible functions return `(value?, string?)`. Error strings follow the format `ERROR_TYPE: description`.

| Error Type              | Description                                     |
|-------------------------|-------------------------------------------------|
| `CDP_CONNECTION_FAILED` | Cannot connect to Chrome or manager not running |
| `CDP_DISCONNECTED`      | Chrome connection lost during operation         |
| `NAVIGATION_FAILED`     | Page navigation error (DNS, SSL, etc.)          |
| `ELEMENT_NOT_FOUND`     | CSS selector matched no elements                |
| `EVAL_ERROR`            | JavaScript execution error                      |
| `TAB_CLOSED`            | Tab was closed, crashed, or context destroyed   |
| `TIMEOUT`               | Operation exceeded its timeout                  |
| `DOWNLOAD_TIMEOUT`      | No download detected within timeout             |
| `DOWNLOAD_FAILED`       | Download action or body retrieval failed        |

```lua
local tab, err = browser.new_tab()
if err then return nil, err end

local resp, err = tab:goto("https://example.com")
if err then
    tab:close()
    return nil, err
end
```

See [Error Handling](docs/error-handling.md) for the full list, CDP error mapping, and handling patterns.

---

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                      Wippy Runtime                           │
│                                                              │
│  ┌───────────┐  ┌───────────┐  ┌───────────┐                │
│  │ Process A  │  │ Process B  │  │ Process C  │               │
│  │  tab:goto  │  │  tab:click │  │  tab:eval  │               │
│  └─────┬─────┘  └─────┬─────┘  └─────┬─────┘                │
│        └───────┬───────┴───────┬──────┘                      │
│                ▼               ▼                             │
│       ┌─────────────────────────────────┐                    │
│       │    Connection Manager Process    │                    │
│       │  (non-blocking CDP + tab pool)  │                    │
│       └───────────────┬─────────────────┘                    │
└───────────────────────┼──────────────────────────────────────┘
                        │ WebSocket (CDP)
                        ▼
             ┌──────────────────────┐
             │  Chromium (headless)  │
             │  Tab 1  Tab 2  Tab 3 │
             └──────────────────────┘
```

The connection manager is a long-running Wippy process that:

- Owns the single WebSocket connection to Chrome
- **Non-blocking command routing** — sends CDP commands via `send_async()`, tracks responses by ID, routes replies when
  they arrive on the WebSocket. The event loop never blocks on individual commands.
- Multiplexes CDP sessions by `sessionId`
- Routes commands from Tab objects via `process.send` + channels
- Monitors tab owner PIDs and auto-cleans on process exit
- Runs periodic health checks and attempts reconnection on disconnect
- Enforces max tab limits with a waiter queue

See [Architecture](docs/architecture.md) for the full process model, message protocol, tab lifecycle, and health check
details.

---

## Real-World Example: EGRUL Document Extraction

Extract company registration documents from egrul.nalog.ru by INN:

```lua
local browser = require("browser")
local fs = require("fs")
local logger = require("logger")

local function extract_egrul(inn)
    local log = logger:named("egrul")
    local tab, err = browser.new_tab()
    if err then return nil, err end

    -- Block unnecessary resources for faster loading
    tab:block_resources({"image", "font", "media"})

    local _, nav_err = tab:goto("https://egrul.nalog.ru/index.html")
    if nav_err then
        tab:close()
        return nil, nav_err
    end

    -- Fill search form
    tab:wait_for_selector("#query", { timeout = "15s", visible = true })
    tab:type("#query", inn)
    tab:click("#btnSearch")

    -- Wait for results
    tab:wait_for_selector(".res-row", { timeout = "20s", visible = true })
    local company_name = tab:text(".res-row:first-child .res-caption a")

    -- Download PDF — use JS click to reliably trigger the handler
    local download, dl_err = tab:expect_download(function()
        return tab:eval([[
            (function() {
                var btn = document.querySelector('.res-row:first-child button.op-excerpt');
                if (!btn) throw new Error('Button not found');
                btn.click();
                return true;
            })()
        ]])
    end, { timeout = "60s" })

    if dl_err then
        tab:close()
        return nil, dl_err
    end

    -- Save PDF to filesystem
    local vol = fs.get("app:downloads")
    vol:mkdir("/egrul")
    vol:mkdir("/egrul/" .. inn)
    vol:writefile("/egrul/" .. inn .. "/" .. download.filename, download.data, "w")

    tab:close()
    log:info("Extraction complete", {
        inn = inn,
        company = company_name,
        file = download.filename,
        size = download.size,
    })

    return {
        inn = inn,
        company_name = company_name,
        filename = download.filename,
        size = download.size,
    }
end

return { main = extract_egrul }
```

---

## Project Structure

```
src/
├── _index.yaml                     # Root namespace, requirements
├── wippy.yaml                      # Module metadata
├── lib/
│   ├── _index.yaml                 # Library entries
│   ├── browser.lua                 # Public API: browser.new_tab()
│   ├── tab.lua                     # Tab object with all user-facing methods
│   ├── cdp_connection.lua          # WebSocket connection, message routing
│   ├── cdp_protocol.lua            # CDP JSON-RPC encode/decode
│   ├── cdp_helpers.lua             # Polling, JS snippet helpers
│   ├── dom_helpers.lua             # DOM interaction JS snippets, key map
│   └── errors.lua                  # CDP → Wippy error type mapping
└── service/
    ├── _index.yaml                 # Service entries
    └── connection_manager.lua      # Manager process (owns WebSocket, tab pool)
```

## License

Apache-2.0
