# Headless Browser SDK

A low-level Lua SDK for controlling headless Chromium via Chrome DevTools Protocol (CDP), designed for web scraping,
document extraction, and browser automation tasks within the Wippy runtime.

Each Wippy process gets its own isolated browser tab, enabling natural parallelism through the actor model — spawn N
processes, get N concurrent browser sessions.

## Features

- **Tab-per-process isolation** — incognito-like browser contexts with independent cookies, storage, and cache
- **Full navigation control** — goto, reload, back/forward, wait for load/network idle
- **Element interaction** — click, type, select dropdowns, check/uncheck, hover, focus, upload files
- **Content extraction** — text, attributes, values, visibility checks, element counting
- **JavaScript execution** — sync and async eval with argument passing
- **Screenshots & PDF** — viewport, element, full-page screenshots; PDF generation with paper size and margin options
- **Download interception** — capture file downloads in-memory without disk I/O
- **Resource blocking** — block images, stylesheets, fonts, etc. for faster scraping
- **Connection pooling** — max tabs enforcement with backpressure and automatic queuing
- **Fault tolerance** — automatic Chrome disconnect detection, tab cleanup on process exit, supervisor-friendly

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

### Module: `browser`

```lua
local browser = require("browser")
```

#### `browser.new_tab(registry_name?, options?) → Tab, error?`

Creates a new browser tab connected to the CDP instance. The tab is an isolated browsing context (incognito-like).
Blocks if the max tab limit is reached, returning an error on timeout.

```lua
local tab, err = browser.new_tab("app:chrome")
if err then return nil, err end

-- Use tab...
tab:close()
```

---

### Object: `Tab`

All operations block the calling coroutine (not the process) until complete or timeout.

#### Navigation

```lua
-- Navigate to URL (blocks until page load event)
local response, err = tab:goto("https://example.com")
-- response.url, response.frame_id, response.loader_id

tab:reload()
tab:back()
tab:forward()

local url = tab:url()

-- Wait for navigation after an action that triggers it
local response, err = tab:wait_for_navigation()
```

#### Waiting

```lua
-- Wait for element to appear in DOM
local ok, err = tab:wait_for_selector("#result", {
    timeout = "10s",
    visible = true,      -- wait until visible, not just in DOM
})

-- Wait for a JS condition to become truthy
tab:wait_for_function("() => document.querySelectorAll('.item').length > 5", {
    timeout = "15s",
})

-- Wait for no network requests for 500ms
tab:wait_for_network_idle({
    idle_time = 500,     -- ms
    timeout = "30s",
})
```

#### Content Extraction

```lua
local html = tab:content()                            -- full page HTML
local text = tab:text("#message")                     -- element text
local items = tab:text_all(".result .title")          -- multiple elements
local href = tab:attribute("a.link", "href")          -- attribute value
local links = tab:attribute_all(".nav a", "href")     -- multiple attributes
local val = tab:value("#search-input")                -- input/select value
local visible = tab:is_visible("#error")              -- boolean
local exists = tab:exists("#captcha")                 -- boolean
local enabled = tab:is_enabled("#submit")             -- boolean
local checked = tab:is_checked("#remember-me")        -- boolean
local count = tab:count(".search-result")             -- integer
```

#### Element Interaction

```lua
tab:click("#submit-button")

-- Type into input (clears first by default)
tab:type("#search", "query text")
tab:type("#search", " more", { clear = false })    -- append

tab:press("Enter")
tab:press("Tab")
tab:press("Escape")

-- Select dropdown
tab:select("#country", "RU")                        -- by value
tab:select("#country", { index = 3 })               -- by index
tab:select("#country", { text = "Russia" })         -- by visible text

tab:check("#agree-terms")
tab:uncheck("#newsletter")
tab:hover("#tooltip-trigger")
tab:focus("#input-field")

-- File upload
tab:upload("#file-input", "/path/to/file.pdf")
```

#### JavaScript Execution

```lua
-- Evaluate expression, get return value
local title = tab:eval("document.title")
local count = tab:eval("document.querySelectorAll('.item').length")

-- With arguments (expression treated as function)
local text = tab:eval(
    "(selector) => document.querySelector(selector)?.textContent",
    "#my-element"
)

-- Async (waits for Promise resolution)
local data = tab:eval_async([[
    const resp = await fetch('/api/data');
    return await resp.json();
]])
```

#### Screenshots & PDF

```lua
-- Viewport screenshot (PNG)
local png = tab:screenshot()

-- Element screenshot
local png = tab:screenshot("#chart")

-- Full scrollable page
local png = tab:screenshot({ full_page = true })

-- JPEG with quality
local jpg = tab:screenshot({ format = "jpeg", quality = 80 })

-- PDF generation
local pdf = tab:pdf()
local pdf = tab:pdf({
    format = "A4",            -- A3, A4, A5, Letter, Legal, Tabloid
    landscape = true,
    print_background = true,
    margin = { top = "1cm", bottom = "1cm", left = "2cm", right = "2cm" },
})
```

#### File Downloads

Downloads are intercepted in-memory via the Fetch domain — no disk I/O required.

```lua
local download, err = tab:expect_download(function()
    tab:click("#download-pdf-button")
end, { timeout = "30s" })

if err then return nil, err end

-- download.data      → raw bytes (string)
-- download.filename  → "report.pdf"
-- download.mime_type → "application/pdf"
-- download.size      → 145832
```

#### Tab Configuration

```lua
tab:set_viewport(1280, 720)
tab:set_user_agent("Mozilla/5.0 ...")
tab:set_headers({
    ["Accept-Language"] = "ru-RU,ru;q=0.9",
})
tab:set_timeout("15s")

-- Block resource types for faster scraping
tab:block_resources({"image", "stylesheet", "font", "media"})
```

#### Lifecycle

```lua
tab:close()
tab:is_alive()    -- boolean
tab:session_id()  -- CDP session ID
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

### Error Types

| Error Type                 | Description                                     |
|----------------------------|-------------------------------------------------|
| `CDP_CONNECTION_FAILED`    | Cannot connect to Chrome or manager not running |
| `CDP_DISCONNECTED`         | Chrome connection lost during operation         |
| `CDP_ERROR`                | Generic CDP protocol error                      |
| `NAVIGATION_FAILED`        | Page navigation error (DNS, SSL, etc.)          |
| `ELEMENT_NOT_FOUND`        | CSS selector matched no elements                |
| `ELEMENT_NOT_VISIBLE`      | Element exists but is hidden                    |
| `ELEMENT_NOT_INTERACTABLE` | Element is covered or not interactive           |
| `EVAL_ERROR`               | JavaScript execution error                      |
| `DOWNLOAD_TIMEOUT`         | No download started within timeout              |
| `DOWNLOAD_FAILED`          | Download cancelled or body unreadable           |
| `MAX_TABS_REACHED`         | Tab pool exhausted and timeout expired          |
| `TAB_CLOSED`               | Tab was closed, crashed, or context destroyed   |
| `TIMEOUT`                  | Operation exceeded its timeout                  |

### Patterns

```lua
-- Expected failures: check error returns
local tab, err = browser.new_tab("app:chrome")
if err then return nil, err end

local resp, err = tab:goto("https://example.com")
if err then
    tab:close()
    return nil, err
end

-- Unexpected failures: let it crash
-- If Chrome crashes mid-operation, the process crashes,
-- and the supervisor restarts it with clean state.
```

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
│       │    (CDP WebSocket + tab pool)    │                    │
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
- Multiplexes CDP sessions by `sessionId`
- Routes commands from Tab objects via `process.send` + channels
- Monitors tab owner PIDs and auto-cleans on process exit
- Runs periodic health checks and attempts reconnection on disconnect
- Enforces max tab limits with a waiter queue

---

## Real-World Example: EGRUL Document Extraction

```lua
local browser = require("browser")
local store = require("store")
local logger = require("logger")

local function extract_egrul(inn)
    local tab, err = browser.new_tab("app:chrome")
    if err then return nil, err end

    local resp, err = tab:goto("https://egrul.nalog.ru/index.html")
    if err then
        tab:close()
        return nil, err
    end

    -- Block unnecessary resources
    tab:block_resources({"image", "stylesheet", "font"})

    -- Fill search
    tab:wait_for_selector("#query")
    tab:type("#query", inn)
    tab:click("#btnSearch")

    -- Wait for results
    tab:wait_for_selector(".res-row", { timeout = "15s" })

    -- Download PDF
    local download, err = tab:expect_download(function()
        tab:click(".res-row:first-child .op-excerpt a")
    end, { timeout = "30s" })

    if err then
        logger:warn("Download failed", { inn = inn, error = tostring(err) })
        tab:close()
        return nil, err
    end

    -- Save to store
    local s = store.get("app:documents")
    local key = string.format("egrul/%s/%s", inn, download.filename)
    s:set(key, download.data)
    s:release()

    tab:close()

    return {
        inn = inn,
        filename = download.filename,
        size = download.size,
        store_key = key,
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
