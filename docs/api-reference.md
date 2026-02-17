# API Reference

## Module: `browser`

```lua
local browser = require("browser")
```

### `browser.new_tab(registry_name?, options?) → (Tab?, string?)`

Creates a new browser tab with an isolated browsing context (separate cookies, storage, cache).

**Parameters:**

| Name            | Type     | Default          | Description                              |
|-----------------|----------|------------------|------------------------------------------|
| `registry_name` | `string?` | `nil`          | Process registry name for the manager    |
| `options`       | `table?`  | `{}`           | Tab options (see below)                  |

**Options:**

| Key                          | Type      | Default | Description                                  |
|------------------------------|-----------|---------|----------------------------------------------|
| `default_timeout`            | `string`  | `"30s"` | Default timeout for most operations          |
| `default_navigation_timeout` | `string`  | `"60s"` | Default timeout for navigation operations    |

**Returns:** `Tab` object on success, or `nil, error_string` on failure.

**Errors:** `CDP_CONNECTION_FAILED`, `TIMEOUT`, `MAX_TABS_REACHED`

```lua
local tab, err = browser.new_tab()
if err then return nil, err end

-- With options
local tab, err = browser.new_tab(nil, {
    default_timeout = "15s",
    default_navigation_timeout = "30s",
})
```

---

## Object: `Tab`

All Tab methods block the calling process until complete or timeout. They do not block other Wippy processes.

All fallible methods return `(value?, string?)` — check the error before using the value.

---

### Navigation

#### `tab:goto(url, options?) → (table?, string?)`

Navigates to a URL and waits for the page load event.

| Parameter        | Type     | Default               | Description               |
|------------------|----------|-----------------------|---------------------------|
| `url`            | `string` | —                     | URL to navigate to        |
| `options.timeout`| `string?`| navigation timeout    | Override timeout           |

Returns `{ url, frame_id, loader_id }` on success.

```lua
local resp, err = tab:goto("https://example.com")
local resp, err = tab:goto("https://slow-site.com", { timeout = "120s" })
```

#### `tab:reload(options?) → (table?, string?)`

Reloads the current page and waits for the load event.

| Parameter        | Type     | Default               | Description       |
|------------------|----------|-----------------------|-------------------|
| `options.timeout`| `string?`| navigation timeout    | Override timeout  |

#### `tab:back() → (table?, string?)`

Navigates back in history. Returns error if there is no previous entry.

#### `tab:forward() → (table?, string?)`

Navigates forward in history. Returns error if there is no next entry.

#### `tab:url() → (string?, string?)`

Returns the current page URL.

#### `tab:wait_for_navigation(options?) → (table?, string?)`

Waits for a `Page.loadEventFired` event. Use this after an action that triggers navigation (e.g., clicking a link).

| Parameter        | Type     | Default               | Description       |
|------------------|----------|-----------------------|-------------------|
| `options.timeout`| `string?`| navigation timeout    | Override timeout  |

```lua
tab:click("a.next-page")
local resp, err = tab:wait_for_navigation({ timeout = "30s" })
```

---

### Waiting

#### `tab:wait_for_selector(selector, options?) → (boolean?, string?)`

Waits for an element matching the CSS selector to appear in the DOM.

| Parameter         | Type      | Default           | Description                          |
|-------------------|-----------|-------------------|--------------------------------------|
| `selector`        | `string`  | —                 | CSS selector                         |
| `options.timeout` | `string?` | default timeout   | Override timeout                     |
| `options.visible` | `boolean?`| `false`           | Wait until the element is visible    |

```lua
tab:wait_for_selector("#results")
tab:wait_for_selector(".modal", { visible = true, timeout = "10s" })
```

#### `tab:wait_for_function(js_fn, options?) → (boolean?, string?)`

Waits for a JavaScript function to return a truthy value.

| Parameter              | Type       | Default   | Description                           |
|------------------------|------------|-----------|---------------------------------------|
| `js_fn`                | `string`   | —         | JS function (arrow or regular)        |
| `options.timeout`      | `string?`  | default   | Override timeout                      |
| `options.poll_interval`| `integer?` | `100`     | Polling interval in milliseconds      |

```lua
tab:wait_for_function("() => document.querySelectorAll('.item').length > 5")
tab:wait_for_function("() => window.dataReady === true", { timeout = "15s" })
```

#### `tab:wait_for_network_idle(options?) → (boolean?, string?)`

Waits until no network requests have been sent or completed for a specified duration.

| Parameter          | Type       | Default   | Description                         |
|--------------------|------------|-----------|-------------------------------------|
| `options.idle_time`| `integer?` | `500`     | Quiet period in milliseconds        |
| `options.timeout`  | `string?`  | default   | Override timeout                    |

```lua
tab:wait_for_network_idle()
tab:wait_for_network_idle({ idle_time = 1000, timeout = "30s" })
```

---

### Content Extraction

#### `tab:content() → (string?, string?)`

Returns the full HTML of the page (`document.documentElement.outerHTML`).

#### `tab:text(selector) → (string?, string?)`

Returns the trimmed text content of the first element matching the selector.

```lua
local title = tab:text("h1")
```

#### `tab:text_all(selector) → ({string}?, string?)`

Returns an array of trimmed text contents for all matching elements.

```lua
local items = tab:text_all(".product-name")
for _, name in ipairs(items) do
    print(name)
end
```

#### `tab:attribute(selector, attr) → (string?, string?)`

Returns the value of an attribute on the first matching element.

```lua
local href = tab:attribute("a.download", "href")
```

#### `tab:attribute_all(selector, attr) → ({string}?, string?)`

Returns an array of attribute values for all matching elements.

```lua
local links = tab:attribute_all("nav a", "href")
```

#### `tab:value(selector) → (string?, string?)`

Returns the value of an input, select, or textarea element.

```lua
local search_text = tab:value("#search-input")
```

#### `tab:is_visible(selector) → boolean`

Returns `true` if the element exists and is visible (has non-zero dimensions and is not hidden via CSS). Returns `false` on any error.

#### `tab:exists(selector) → boolean`

Returns `true` if the element exists in the DOM. Returns `false` otherwise.

#### `tab:is_enabled(selector) → boolean`

Returns `true` if the element is not disabled. Returns `false` otherwise.

#### `tab:is_checked(selector) → boolean`

Returns `true` if a checkbox or radio button is checked. Returns `false` otherwise.

#### `tab:count(selector) → integer`

Returns the number of elements matching the selector. Returns `0` if none match.

```lua
local n = tab:count(".search-result")
```

---

### Element Interaction

#### `tab:click(selector) → (boolean?, string?)`

Clicks the center of the first element matching the selector. Scrolls the element into view if needed.

```lua
tab:click("#submit")
```

#### `tab:type(selector, text, options?) → (boolean?, string?)`

Types text into an input element character by character, dispatching key events.

| Parameter       | Type      | Default | Description                        |
|-----------------|-----------|---------|-------------------------------------|
| `selector`      | `string`  | —       | CSS selector for the input          |
| `text`          | `string`  | —       | Text to type                        |
| `options.clear` | `boolean?`| `true`  | Clear existing value before typing  |

```lua
tab:type("#email", "user@example.com")
tab:type("#search", " more text", { clear = false })  -- append
```

#### `tab:press(key_name) → (boolean?, string?)`

Presses a special key by name.

**Supported keys:** `Enter`, `Tab`, `Escape`, `Backspace`, `Delete`, `ArrowUp`, `ArrowDown`, `ArrowLeft`, `ArrowRight`, `Home`, `End`, `PageUp`, `PageDown`, `Space`

```lua
tab:press("Enter")
tab:press("Escape")
```

#### `tab:select(selector, value) → (boolean?, string?)`

Selects an option in a `<select>` dropdown.

| Parameter  | Type              | Description                          |
|------------|-------------------|--------------------------------------|
| `selector` | `string`          | CSS selector for the `<select>`      |
| `value`    | `string`          | Select by value attribute            |
| `value`    | `{ value = "..." }` | Select by value attribute         |
| `value`    | `{ index = N }`   | Select by 0-based index             |
| `value`    | `{ text = "..." }`| Select by visible text               |

```lua
tab:select("#country", "US")
tab:select("#country", { index = 0 })
tab:select("#country", { text = "United States" })
```

#### `tab:check(selector) → (boolean?, string?)`

Checks a checkbox if it is not already checked.

#### `tab:uncheck(selector) → (boolean?, string?)`

Unchecks a checkbox if it is currently checked.

#### `tab:hover(selector) → (boolean?, string?)`

Moves the mouse to the center of the element.

#### `tab:focus(selector) → (boolean?, string?)`

Focuses the element via JavaScript.

#### `tab:upload(selector, file_path) → (boolean?, string?)`

Sets files on a `<input type="file">` element.

| Parameter   | Type               | Description                         |
|-------------|---------------------|-------------------------------------|
| `selector`  | `string`            | CSS selector for the file input     |
| `file_path` | `string \| {string}` | Path or array of paths to upload   |

```lua
tab:upload("#avatar", "/path/to/photo.jpg")
tab:upload("#docs", { "/path/a.pdf", "/path/b.pdf" })
```

---

### JavaScript Execution

#### `tab:eval(expression, ...) → (any?, string?)`

Evaluates a JavaScript expression and returns the result.

When called with extra arguments, the expression is treated as a function and called with those arguments.

```lua
-- Simple expression
local title = tab:eval("document.title")
local count = tab:eval("document.querySelectorAll('.item').length")

-- With arguments (expression used as function body)
local text = tab:eval(
    "(sel) => document.querySelector(sel)?.textContent",
    "#my-element"
)

-- Multiple arguments
local result = tab:eval(
    "(a, b) => a + b",
    10, 20
)
```

#### `tab:eval_async(expression) → (any?, string?)`

Evaluates a JavaScript expression that returns a Promise. Waits for the Promise to resolve.

```lua
local data = tab:eval_async([[
    const resp = await fetch('/api/data');
    return await resp.json();
]])
```

---

### Screenshots and PDF

#### `tab:screenshot(selector_or_options?) → (string?, string?)`

Captures a screenshot and returns the raw image bytes.

**Calling conventions:**

```lua
-- Viewport screenshot (PNG)
local bytes = tab:screenshot()

-- Element screenshot
local bytes = tab:screenshot("#chart")

-- Full page screenshot
local bytes = tab:screenshot({ full_page = true })

-- JPEG with quality
local bytes = tab:screenshot({ format = "jpeg", quality = 80 })
```

**Options (when passing a table):**

| Key         | Type      | Default | Description                          |
|-------------|-----------|---------|--------------------------------------|
| `full_page` | `boolean?`| `false` | Capture the entire scrollable page   |
| `format`    | `string?` | `"png"` | Image format: `"png"` or `"jpeg"`   |
| `quality`   | `integer?`| —       | JPEG quality 1-100 (JPEG only)      |

#### `tab:pdf(options?) → (string?, string?)`

Generates a PDF of the current page and returns the raw bytes.

| Key                | Type     | Default | Description                        |
|--------------------|----------|---------|------------------------------------|
| `format`           | `string?`| `"A4"` | Paper size: A3, A4, A5, Letter, Legal, Tabloid |
| `landscape`        | `boolean?`| `false`| Landscape orientation              |
| `print_background` | `boolean?`| `true` | Include CSS backgrounds            |
| `margin`           | `table?` | `{}`   | `{ top, bottom, left, right }` with CSS units |

```lua
local pdf = tab:pdf()
local pdf = tab:pdf({
    format = "Letter",
    landscape = true,
    margin = { top = "1in", bottom = "1in", left = "0.5in", right = "0.5in" },
})
```

---

### Download Interception

#### `tab:expect_download(action_fn, options?) → (table?, string?)`

Intercepts a file download triggered by the action function. The download is captured in-memory — no disk I/O required.

| Parameter        | Type       | Default         | Description                           |
|------------------|------------|-----------------|---------------------------------------|
| `action_fn`      | `function` | —               | Function that triggers the download   |
| `options.timeout`| `string?`  | default timeout | Max time to wait for download         |

**Download detection:** A response is treated as a download if any of these conditions are met:
- `Content-Disposition` header contains `attachment`
- `Content-Disposition` header contains a `filename` parameter
- `Content-Type` is a known binary/document type (`application/pdf`, `application/octet-stream`, `application/zip`, etc.)

**Error propagation:** If `action_fn` returns `(nil, error_string)`, the error is propagated immediately instead of waiting for timeout. Use `return` in the action function:

```lua
local dl, err = tab:expect_download(function()
    return tab:click("#download-btn")  -- error propagated if element not found
end, { timeout = "30s" })
```

**Returns:**

```lua
{
    data      = "...",              -- raw bytes (string)
    filename  = "report.pdf",      -- from Content-Disposition or URL
    mime_type = "application/pdf",  -- from Content-Type header
    size      = 145832,            -- byte count
}
```

```lua
local dl, err = tab:expect_download(function()
    tab:click("#download-btn")
end, { timeout = "30s" })

if err then return nil, err end
print(dl.filename, dl.size)
```

---

### Tab Configuration

#### `tab:set_viewport(width, height) → (table?, string?)`

Sets the viewport dimensions.

```lua
tab:set_viewport(1920, 1080)
```

#### `tab:set_user_agent(ua) → (table?, string?)`

Overrides the User-Agent header.

```lua
tab:set_user_agent("MyBot/1.0")
```

#### `tab:set_headers(headers) → (table?, string?)`

Sets extra HTTP headers sent with every request.

```lua
tab:set_headers({
    ["Accept-Language"] = "en-US",
    ["X-Custom"] = "value",
})
```

#### `tab:set_timeout(timeout)`

Changes the default timeout for all subsequent operations on this tab.

```lua
tab:set_timeout("15s")
```

#### `tab:block_resources(resource_types) → (boolean?, string?)`

Blocks network requests for specified resource types. Useful for faster scraping.

**Supported types:** `image`, `stylesheet`, `font`, `media`, `script`, `xhr`, `fetch`, `websocket`, `document`, `manifest`, `texttrack`, `eventsource`, `other`

```lua
tab:block_resources({ "image", "stylesheet", "font", "media" })
```

---

### Lifecycle

#### `tab:close()`

Closes the tab and releases its browser context. The tab object becomes unusable.

#### `tab:is_alive() → boolean`

Returns `true` if the tab is still open.

#### `tab:session_id() → string`

Returns the CDP session ID.

#### `tab:default_timeout() → string`

Returns the current default timeout.

#### `tab:default_navigation_timeout() → string`

Returns the current default navigation timeout.

---

### Low-Level

#### `tab:send_command(method, params?, timeout?) → (table?, string?)`

Sends a raw CDP command through the manager and returns the result. Use this for CDP methods not covered by the high-level API.

| Parameter | Type     | Default         | Description           |
|-----------|----------|-----------------|-----------------------|
| `method`  | `string` | —               | CDP method name       |
| `params`  | `table?` | `{}`            | CDP method parameters |
| `timeout` | `string?`| default timeout | Override timeout      |

```lua
local result, err = tab:send_command("Page.getNavigationHistory")
local result, err = tab:send_command("Network.setCacheDisabled", { cacheDisabled = true })
```

#### `tab:event_channel() → (channel?, string?)`

Returns the raw CDP event channel for building custom event loops.
