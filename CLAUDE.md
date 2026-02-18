# CLAUDE.md

Headless Browser SDK — a Wippy module for controlling headless Chromium via Chrome DevTools Protocol (CDP).

## Tech Stack

- **Language**: Lua 5.3 with gradual type system (non-nullable by default, use `?` for optional)
- **Runtime**: Wippy (Go-based runtime — docs at https://wippy.ai/llm.txt)
- **Module**: `butschster/headless-browser` (namespace: `headless`)

## Commands

- `wippy lint` — type-check all Lua code (must pass with 0 errors before committing)
- `wippy lint --rules` — lint with style/quality warnings
- `wippy lint --level hint` — show all diagnostics including hints
- `wippy run` — start the runtime (requires Chrome on `localhost:9222`)
- `wippy init` — regenerate `wippy.lock` (run after changing `_index.yaml` files)

## Project Structure

```
src/
├── _index.yaml                  # Root namespace, requirements (chrome_address, process_host)
├── wippy.yaml                   # Module metadata
├── lib/
│   ├── _index.yaml              # Library entries with module/import declarations
│   ├── browser.lua              # Public API: browser.new_tab() → Tab
│   ├── tab.lua                  # Tab object — navigation, extraction, interaction, screenshots
│   ├── cdp_connection.lua       # WebSocket connection, message routing, session subscriptions
│   ├── cdp_protocol.lua         # CDP JSON-RPC encode/decode
│   ├── cdp_helpers.lua          # Polling, JS evaluation helpers
│   ├── dom_helpers.lua          # DOM interaction JS snippets, KEY_MAP
│   └── errors.lua               # CDP → Wippy error type mapping
└── service/
    ├── _index.yaml              # Service entries (process + process.service)
    └── connection_manager.lua   # Long-running process: owns WebSocket, tab pool, event routing
```

## Architecture

- **Connection Manager** (`service/connection_manager.lua`) — singleton process registered as `headless.manager`, owns
  the CDP WebSocket, multiplexes sessions, enforces max tabs
- **Tab** (`lib/tab.lua`) — user-facing object, communicates with manager via `process.send` + reply channels
- **Browser** (`lib/browser.lua`) — thin public API, looks up manager via `process.registry`, creates tabs

Message flow: `Tab:send_command()` → `process.send(manager, "tab.command", ...)` → manager calls `conn:send()` → replies
via `process.send(sender, "tab.command.reply", ...)`

## Type System Conventions

- Types are **non-nullable by default**; use `?` suffix for optional (`string?`, `table?`)
- Use `:: type` casts when the linter can't infer narrowed types (e.g. after nil checks, from `any`/`unknown` table
  fields)
- Common patterns requiring casts:
    - `r.value` from `channel.select` is `any` — cast fields: `r.value.field :: string`
    - `result.field` from `send_command` returns `table?` — inner fields are `unknown`
    - Multi-return `eval()` returning `(any?, string?)` needs unwrap + cast when caller expects `(string?, string?)`
- Function signatures use typed params: `function foo(x: string, y: table?): (string?, string?)`
- Type annotations on locals: `local x: number = tonumber(s) or 0`

## Registry Configuration (`_index.yaml`)

- `kind: library.lua` — library entries declare `modules` (runtime builtins) and `imports` (other entries)
- `kind: process.lua` — long-running process entry
- `kind: process.service` — auto-started supervised process with restart policy
- `kind: ns.requirement` — configurable values with defaults and target bindings

## Coding Patterns

- **Error handling**: all fallible functions return `(value?, string?)` — check error before using value
- **Process communication**: `process.send(pid, topic, payload)` + `process.listen(topic)` + `channel.select`
- **CDP commands**: routed through `Tab:send_command(method, params?, timeout?)`, never called directly on the
  connection
- **Event waiting**: `channel.select` with timeout channels from `time.after(duration_string)`
- **Resource cleanup**: tabs auto-clean on owner process exit via `process.monitor` + EXIT events
