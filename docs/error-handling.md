# Error Handling

## Convention

All fallible functions return `(value?, string?)`. The error string follows the format:

```
ERROR_TYPE: description
```

Always check the error before using the value:

```lua
local tab, err = browser.new_tab()
if err then return nil, err end

local resp, err = tab:goto("https://example.com")
if err then
    tab:close()
    return nil, err
end
```

---

## Error Types

### Connection Errors

| Error Type              | Description                                         |
|-------------------------|-----------------------------------------------------|
| `CDP_CONNECTION_FAILED` | Cannot connect to Chrome or the manager is not running |
| `CDP_DISCONNECTED`      | Chrome connection was lost during an operation       |
| `CDP_ERROR`             | Generic CDP protocol error                          |

### Navigation Errors

| Error Type          | Description                                           |
|---------------------|-------------------------------------------------------|
| `NAVIGATION_FAILED` | Page navigation failed (DNS resolution, SSL error, net::ERR_*, etc.) |

### Element Errors

| Error Type                | Description                                   |
|---------------------------|-----------------------------------------------|
| `ELEMENT_NOT_FOUND`       | No element matched the CSS selector           |
| `ELEMENT_NOT_VISIBLE`     | Element exists in the DOM but is hidden        |
| `ELEMENT_NOT_INTERACTABLE`| Element is covered by another element or not interactive |

### Execution Errors

| Error Type   | Description                                               |
|--------------|-----------------------------------------------------------|
| `EVAL_ERROR` | JavaScript execution error (TypeError, ReferenceError, etc.) |

### Download Errors

| Error Type         | Description                                    |
|--------------------|------------------------------------------------|
| `DOWNLOAD_TIMEOUT` | No download started within the timeout period  |
| `DOWNLOAD_FAILED`  | Download was cancelled or body could not be read |

### Resource Errors

| Error Type        | Description                                       |
|-------------------|---------------------------------------------------|
| `MAX_TABS_REACHED`| All tab slots are occupied and the wait timed out  |
| `TAB_CLOSED`      | Tab was closed, crashed, or its context was destroyed |
| `TIMEOUT`         | Operation exceeded its timeout                     |
| `INVALID`         | Invalid parameter or state                         |

---

## Error Mapping from CDP

The SDK translates raw CDP error codes and messages into the types above. For example:

| CDP Error                                      | Mapped To            |
|------------------------------------------------|----------------------|
| `Target closed` / `Session not found`          | `TAB_CLOSED`         |
| `net::ERR_NAME_NOT_RESOLVED`                   | `NAVIGATION_FAILED`  |
| `net::ERR_CONNECTION_REFUSED`                  | `NAVIGATION_FAILED`  |
| `Could not find node with given id`            | `ELEMENT_NOT_FOUND`  |
| `TypeError` / `ReferenceError` in JS           | `EVAL_ERROR`         |

---

## Handling Patterns

### Retry on transient errors

```lua
local function goto_with_retry(tab, url, retries)
    for i = 1, retries do
        local resp, err = tab:goto(url)
        if not err then return resp end
        if not err:match("^TIMEOUT") and not err:match("^NAVIGATION_FAILED") then
            return nil, err  -- non-retryable
        end
    end
    return nil, "TIMEOUT: All retries exhausted"
end
```

### Let it crash

For unexpected failures (Chrome crash, connection lost), let the process crash. The supervisor will restart it with clean state.

```lua
-- If Chrome crashes, tab:goto returns a CDP_DISCONNECTED error.
-- Returning the error from main causes the process to exit.
-- The supervisor restarts the process and it reconnects.
local resp, err = tab:goto(url)
if err then return nil, err end
```

### Check element before interacting

```lua
if tab:exists("#captcha") then
    -- handle captcha
end

if tab:is_visible("#error-message") then
    local msg = tab:text("#error-message")
    return nil, "Page error: " .. msg
end
```
