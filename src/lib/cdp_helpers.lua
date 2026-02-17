--- CDP Helpers
---
--- Shared helper functions for common CDP patterns: polling conditions,
--- event waiting, JavaScript snippet generation.

local time = require("time")

local helpers = {}

--- Default polling interval for wait operations (ms).
helpers.POLL_INTERVAL_MS = 100

--- Generate JavaScript to check if a selector exists in the DOM.
--- @param selector string CSS selector
--- @return string js JavaScript expression returning boolean
function helpers.js_selector_exists(selector: string): string
    return string.format("document.querySelector(%q) !== null", selector)
end

--- Generate JavaScript to check if a selector is visible.
--- Checks: exists, display != none, visibility != hidden, opacity != 0, has dimensions.
--- @param selector string CSS selector
--- @return string js JavaScript expression returning boolean or null
function helpers.js_selector_visible(selector: string): string
    return string.format([[
        (function() {
            var el = document.querySelector(%q);
            if (!el) return false;
            var rect = el.getBoundingClientRect();
            var style = window.getComputedStyle(el);
            if (style.display === 'none') return false;
            if (style.visibility === 'hidden') return false;
            if (style.opacity === '0') return false;
            if (rect.width === 0 && rect.height === 0) return false;
            return true;
        })()
    ]], selector)
end

--- Generate JavaScript to get the text content of an element.
--- @param selector string CSS selector
--- @return string js JavaScript expression returning string or null
function helpers.js_text_content(selector: string): string
    return string.format(
        "(() => { var el = document.querySelector(%q); return el ? el.textContent : null; })()",
        selector
    )
end

--- Generate JavaScript to get an attribute of an element.
--- @param selector string CSS selector
--- @param attr string Attribute name
--- @return string js JavaScript expression returning string or null
function helpers.js_get_attribute(selector: string, attr: string): string
    return string.format(
        "(() => { var el = document.querySelector(%q); return el ? el.getAttribute(%q) : null; })()",
        selector, attr
    )
end

--- Generate JavaScript to count matching elements.
--- @param selector string CSS selector
--- @return string js JavaScript expression returning number
function helpers.js_count(selector: string): string
    return string.format("document.querySelectorAll(%q).length", selector)
end

--- Evaluate a JavaScript expression and return the primitive value.
--- @param tab table Tab object (must have send_command)
--- @param expression string JavaScript expression
--- @param timeout string|nil Timeout override
--- @return any|nil value Result value
--- @return string|nil error
function helpers.eval_value(tab: table, expression: string, timeout: string?): (any?, string?)
    local result, err = tab:send_command("Runtime.evaluate", {
        expression = expression,
        returnByValue = true,
    }, timeout)

    if err then
        return nil, err
    end

    if result.exceptionDetails then
        local exc = result.exceptionDetails
        local msg = "EVAL_ERROR: "
        if exc.exception and exc.exception.description then
            msg = msg .. exc.exception.description
        elseif exc.text then
            msg = msg .. exc.text
        else
            msg = msg .. "JavaScript evaluation error"
        end
        return nil, msg
    end

    if result.result then
        return result.result.value, nil
    end

    return nil, nil
end

--- Poll a condition by repeatedly evaluating JavaScript until truthy or timeout.
--- @param tab table Tab object
--- @param expression string JavaScript expression that should return truthy when ready
--- @param timeout_str string Timeout duration string (e.g. "30s")
--- @param poll_ms integer|nil Poll interval in ms (default 100)
--- @return boolean|nil result true when condition met
--- @return string|nil error
function helpers.poll_condition(tab: table, expression: string, timeout_str: string, poll_ms: integer?): (boolean?, string?)
    local interval = poll_ms or helpers.POLL_INTERVAL_MS
    local deadline = time.after(timeout_str)

    while true do
        local value, eval_err = helpers.eval_value(tab, expression, "5s")

        -- If eval succeeded and value is truthy, done
        if not eval_err and value then
            return true, nil
        end

        -- Check if we've timed out (non-blocking)
        local r = channel.select {
            deadline:case_receive(),
            default = true,
        }
        if not r.default then
            return nil, nil -- caller should build error message
        end

        -- Sleep before next poll
        time.sleep(tostring(interval) .. "ms")
    end
end

return helpers
