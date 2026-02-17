--- Tab Object
---
--- Represents a single browser tab/page. All operations communicate with the
--- connection manager process via message passing + one-shot reply channels.
---
--- Provides:
---   - Navigation: goto, reload, back, forward, url, wait_for_navigation
---   - Waiting: wait_for_selector, wait_for_function, wait_for_network_idle
---   - Extraction: content, text, text_all, attribute, attribute_all, value,
---                 is_visible, exists, is_enabled, is_checked, count
---   - Interaction: click, type, press, select, check, uncheck, hover, focus, upload
---   - JavaScript: eval, eval_async
---   - Capture: screenshot, pdf
---   - Low-level: send_command, event_channel
---   - Lifecycle: close, is_alive

local time = require("time")
local base64 = require("base64")
local cdp_helpers = require("cdp_helpers")
local dom_helpers = require("dom_helpers")
local error_map = require("errors")

local tab_mod = {}

--- Internal: process a Fetch.requestPaused event for resource blocking.
--- Sends Fetch.failRequest or Fetch.continueRequest as appropriate.
--- Returns true if the event was handled, false otherwise.
--- @param self table Tab object
--- @param evt table CDP event
--- @return boolean handled
local function process_fetch_event(self: table, evt: table): boolean
    if evt.method ~= "Fetch.requestPaused" then
        return false
    end
    if not self._blocked_resources then
        -- No blocking configured, continue the request
        pcall(function()
            self:send_command("Fetch.continueRequest", {
                requestId = evt.params.requestId,
            })
        end)
        return true
    end
    local resource_type = evt.params.resourceType
    if self._blocked_resources[resource_type] then
        pcall(function()
            self:send_command("Fetch.failRequest", {
                requestId = evt.params.requestId,
                errorReason = "BlockedByClient",
            })
        end)
    else
        pcall(function()
            self:send_command("Fetch.continueRequest", {
                requestId = evt.params.requestId,
            })
        end)
    end
    return true
end

--- Convert CSS margin string to inches for Page.printToPDF.
--- Supports cm, mm, in, px units. Defaults to cm.
--- @param value string CSS value like "1cm", "10mm", "0.5in"
--- @return number inches
local function parse_margin(value: string): number
    if not value then return 1.0 / 2.54 end
    local raw_num, unit = value:match("^([%d%.]+)(%a+)$")
    local num: number = tonumber(raw_num) or 1.0
    if unit == "cm" then return num / 2.54
    elseif unit == "mm" then return num / 25.4
    elseif unit == "in" then return num
    elseif unit == "px" then return num / 96
    else return num / 2.54 end
end

--- Create a new Tab object.
--- @param manager_pid string PID of the connection manager process
--- @param session_id string CDP session ID
--- @param target_id string CDP target ID
--- @param context_id string CDP browser context ID
--- @param options table|nil Options { default_timeout, default_navigation_timeout }
--- @return table tab Tab object
function tab_mod.new(manager_pid: string, session_id: string, target_id: string, context_id: string, options: table?)
    local opts = options or {}

    local self = {
        _manager_pid = manager_pid,
        _session_id = session_id,
        _target_id = target_id,
        _context_id = context_id,
        _default_timeout = opts.default_timeout or "30s",
        _default_navigation_timeout = opts.default_navigation_timeout or "60s",
        _alive = true,
        _event_ch = nil,
    }

    -- ─── Internal helpers ──────────────────────────────────────────────

    local function get_event_ch(): (any?, string?)
        if self._event_ch then
            return self._event_ch, nil
        end
        -- Events are forwarded by the manager via process.send on topic "tab.cdp_event"
        self._event_ch = process.listen("tab.cdp_event")
        return self._event_ch, nil
    end

    local function wait_for_event(method: string, predicate: any?, timeout_str: string?): (table?, string?)
        local evt_ch, ch_err = get_event_ch()
        if ch_err then
            return nil, ch_err
        end
        local t = timeout_str or self._default_navigation_timeout
        local deadline = time.after(t)
        while true do
            local r = channel.select {
                evt_ch:case_receive(),
                deadline:case_receive(),
            }
            if r.channel == deadline then
                return nil, "TIMEOUT: Waiting for " .. method .. " timed out after " .. t
            end
            if not r.ok then
                return nil, "TAB_CLOSED: Event channel closed"
            end
            local evt = r.value
            -- Handle Fetch events inline (resource blocking)
            if process_fetch_event(self, evt) then
                -- Handled, continue waiting
            elseif evt.method == method then
                if not predicate or predicate(evt.params) then
                    return evt.params :: table, nil
                end
            end
        end
    end

    --- Evaluate JS and return primitive value (convenience wrapper).
    local function eval(expression: string, timeout: string?): (any?, string?)
        return cdp_helpers.eval_value(self, expression, timeout)
    end

    --- Get bounding box of an element (scroll into view first).
    --- Returns {x, y, width, height} or nil.
    local function get_bounding_box(selector: string): (table?, string?)
        local js = dom_helpers.js_bounding_box(selector)
        local result, err = self:send_command("Runtime.evaluate", {
            expression = js,
            returnByValue = true,
        })
        if err then
            return nil, err
        end
        if result.exceptionDetails then
            return nil, "EVAL_ERROR: " .. tostring(result.exceptionDetails.text)
        end
        local box = result.result and result.result.value
        if not box then
            return nil, "ELEMENT_NOT_FOUND: Selector '" .. selector .. "' not found"
        end
        return box, nil
    end

    -- ─── Low-level API ────────────────────────────────────────────────

    function self:send_command(method: string, params: table?, timeout: string?): (table?, string?)
        if not self._alive then
            return nil, "TAB_CLOSED: Tab was closed"
        end
        local reply_ch = process.listen("tab.command.reply")
        process.send(self._manager_pid, "tab.command", {
            sender_pid = process.pid(),
            sid = self._session_id,
            method = method,
            params = params or {},
            timeout = timeout,
        })
        local t = timeout or self._default_timeout
        local timeout_ch = time.after(t)
        local r = channel.select {
            reply_ch:case_receive(),
            timeout_ch:case_receive(),
        }
        process.unlisten(reply_ch)
        if r.channel == timeout_ch then
            return nil, "TIMEOUT: CDP command timed out: " .. method
        end
        if not r.ok then
            return nil, "TAB_CLOSED: Reply channel closed"
        end
        local resp = r.value
        if resp.error then
            -- Map raw CDP errors to descriptive Wippy error types
            local err_str = tostring(resp.error)
            if err_str:find("^CDP error") then
                local code = tonumber(err_str:match("%((-?%d+)%)"))
                local msg = err_str:match(":%s*(.+)$") or err_str
                return nil, error_map.from_cdp(code :: integer, msg, method)
            end
            return nil, err_str
        end
        return resp.result :: table, nil
    end

    function self:event_channel(): (any?, string?)
        return get_event_ch()
    end

    -- ─── Navigation ───────────────────────────────────────────────────

    self["goto"] = function(self, url: string, options: table?): (table?, string?)
        local nav_opts = options or {}
        local timeout: string = nav_opts.timeout or self._default_navigation_timeout
        local result, err = self:send_command("Page.navigate", { url = url }, timeout)
        if err then
            return nil, "NAVIGATION_FAILED: " .. tostring(err)
        end
        if not result then
            return nil, "NAVIGATION_FAILED: No response from Page.navigate"
        end
        if result.errorText and result.errorText ~= "" then
            return nil, "NAVIGATION_FAILED: " .. result.errorText
        end
        local _, wait_err = wait_for_event("Page.loadEventFired", nil, timeout)
        if wait_err then
            return nil, wait_err
        end
        return {
            url = url,
            frame_id = result.frameId,
            loader_id = result.loaderId,
        }, nil
    end

    function self:reload(options: table?): (table?, string?)
        local nav_opts = options or {}
        local timeout: string = nav_opts.timeout or self._default_navigation_timeout
        local _, err = self:send_command("Page.reload", {}, timeout)
        if err then
            return nil, "NAVIGATION_FAILED: " .. tostring(err)
        end
        return wait_for_event("Page.loadEventFired", nil, timeout)
    end

    function self:back(): (table?, string?)
        local history, err = self:send_command("Page.getNavigationHistory")
        if err then return nil, err end
        if history.currentIndex <= 0 then
            return nil, "NAVIGATION_FAILED: No previous history entry"
        end
        local prev_entry = history.entries[history.currentIndex]
        if not prev_entry then
            return nil, "NAVIGATION_FAILED: History entry not found"
        end
        local _, nav_err = self:send_command("Page.navigateToHistoryEntry", {
            entryId = prev_entry.id,
        })
        if nav_err then return nil, nav_err end
        return wait_for_event("Page.loadEventFired", nil, self._default_navigation_timeout)
    end

    function self:forward(): (table?, string?)
        local history, err = self:send_command("Page.getNavigationHistory")
        if err then return nil, err end
        local next_index = (history.currentIndex :: integer) + 2
        if next_index > #history.entries then
            return nil, "NAVIGATION_FAILED: No forward history entry"
        end
        local next_entry = history.entries[next_index]
        if not next_entry then
            return nil, "NAVIGATION_FAILED: History entry not found"
        end
        local _, nav_err = self:send_command("Page.navigateToHistoryEntry", {
            entryId = next_entry.id,
        })
        if nav_err then return nil, nav_err end
        return wait_for_event("Page.loadEventFired", nil, self._default_navigation_timeout)
    end

    function self:url(): (string?, string?)
        local val, err = eval("location.href")
        return val :: string, err
    end

    function self:wait_for_navigation(options: table?): (table?, string?)
        local nav_opts = options or {}
        local timeout: string = nav_opts.timeout or self._default_navigation_timeout
        return wait_for_event("Page.loadEventFired", nil, timeout)
    end

    -- ─── Waiting ──────────────────────────────────────────────────────

    function self:wait_for_selector(selector: string, options: table?): (boolean?, string?)
        local wait_opts = options or {}
        local timeout = wait_opts.timeout or self._default_timeout
        local check_visible = wait_opts.visible or false
        local expression
        if check_visible then
            expression = cdp_helpers.js_selector_visible(selector)
        else
            expression = cdp_helpers.js_selector_exists(selector)
        end
        local ok, _ = cdp_helpers.poll_condition(self, expression, timeout)
        if ok then
            return true, nil
        end
        local kind = check_visible and "visible" or "in DOM"
        return nil, "ELEMENT_NOT_FOUND: Selector '" .. selector .. "' not " .. kind .. " within " .. timeout
    end

    function self:wait_for_function(js_fn: string, options: table?): (boolean?, string?)
        local wait_opts = options or {}
        local timeout = wait_opts.timeout or self._default_timeout
        local poll_ms = wait_opts.poll_interval or 100
        local expression = "(" .. js_fn .. ")()"
        local ok, _ = cdp_helpers.poll_condition(self, expression, timeout, poll_ms)
        if ok then
            return true, nil
        end
        return nil, "TIMEOUT: wait_for_function did not return truthy within " .. timeout
    end

    function self:wait_for_network_idle(options: table?): (boolean?, string?)
        local wait_opts = options or {}
        local idle_time_ms = wait_opts.idle_time or 500
        local timeout = wait_opts.timeout or self._default_timeout
        local evt_ch, ch_err = get_event_ch()
        if ch_err then return nil, ch_err end

        local in_flight = 0
        local deadline = time.after(timeout)
        local idle_timer = time.after(tostring(idle_time_ms) .. "ms")

        while true do
            local r = channel.select {
                evt_ch:case_receive(),
                idle_timer:case_receive(),
                deadline:case_receive(),
            }
            if r.channel == deadline then
                return nil, "TIMEOUT: Network not idle within " .. timeout
            end
            if r.channel == idle_timer then
                if in_flight <= 0 then
                    return true, nil
                end
                idle_timer = time.after(tostring(idle_time_ms) .. "ms")
            end
            if r.channel == evt_ch then
                if not r.ok then
                    return nil, "TAB_CLOSED: Event channel closed"
                end
                local evt = r.value
                -- Handle Fetch events inline (resource blocking)
                if process_fetch_event(self, evt) then
                    -- Handled, continue
                elseif evt.method == "Network.requestWillBeSent" then
                    in_flight = in_flight + 1
                elseif evt.method == "Network.loadingFinished"
                    or evt.method == "Network.loadingFailed" then
                    in_flight = in_flight - 1
                    if in_flight < 0 then in_flight = 0 end
                    if in_flight == 0 then
                        idle_timer = time.after(tostring(idle_time_ms) .. "ms")
                    end
                end
            end
        end
    end

    -- ─── Content Extraction ───────────────────────────────────────────

    --- Get full page HTML.
    --- @return string|nil html
    --- @return string|nil error
    function self:content(): (string?, string?)
        local val, err = eval("document.documentElement.outerHTML")
        return val :: string, err
    end

    --- Get text content of the first element matching selector.
    --- @param selector string CSS selector
    --- @return string|nil text
    --- @return string|nil error
    function self:text(selector: string): (string?, string?)
        local val, err = eval(dom_helpers.js_text(selector))
        return val :: string, err
    end

    --- Get text content of all elements matching selector.
    --- @param selector string CSS selector
    --- @return {string}|nil texts Array of strings
    --- @return string|nil error
    function self:text_all(selector: string): ({string}?, string?)
        local result, err = self:send_command("Runtime.evaluate", {
            expression = dom_helpers.js_text_all(selector),
            returnByValue = true,
        })
        if err then return nil, err end
        if result.exceptionDetails then
            return nil, "EVAL_ERROR: " .. tostring(result.exceptionDetails.text)
        end
        if result.result then
            return result.result.value or {}, nil
        end
        return {}, nil
    end

    --- Get attribute value of the first element matching selector.
    --- @param selector string CSS selector
    --- @param attr string Attribute name
    --- @return string|nil value
    --- @return string|nil error
    function self:attribute(selector: string, attr: string): (string?, string?)
        local val, err = eval(dom_helpers.js_attribute(selector, attr))
        return val :: string, err
    end

    --- Get attribute values of all elements matching selector.
    --- @param selector string CSS selector
    --- @param attr string Attribute name
    --- @return {string}|nil values
    --- @return string|nil error
    function self:attribute_all(selector: string, attr: string): ({string}?, string?)
        local result, err = self:send_command("Runtime.evaluate", {
            expression = dom_helpers.js_attribute_all(selector, attr),
            returnByValue = true,
        })
        if err then return nil, err end
        if result.exceptionDetails then
            return nil, "EVAL_ERROR: " .. tostring(result.exceptionDetails.text)
        end
        if result.result then
            return result.result.value or {}, nil
        end
        return {}, nil
    end

    --- Get value of an input/select/textarea element.
    --- @param selector string CSS selector
    --- @return string|nil value
    --- @return string|nil error
    function self:value(selector: string): (string?, string?)
        local val, err = eval(dom_helpers.js_value(selector))
        return val :: string, err
    end

    --- Check if element is visible.
    --- @param selector string CSS selector
    --- @return boolean
    function self:is_visible(selector: string): boolean
        local val, _ = eval(dom_helpers.js_is_visible(selector))
        return val == true
    end

    --- Check if element exists in the DOM.
    --- @param selector string CSS selector
    --- @return boolean
    function self:exists(selector: string): boolean
        local val, _ = eval(dom_helpers.js_exists(selector))
        return val == true
    end

    --- Check if element is enabled.
    --- @param selector string CSS selector
    --- @return boolean
    function self:is_enabled(selector: string): boolean
        local val, _ = eval(dom_helpers.js_is_enabled(selector))
        return val == true
    end

    --- Check if checkbox/radio is checked.
    --- @param selector string CSS selector
    --- @return boolean
    function self:is_checked(selector: string): boolean
        local val, _ = eval(dom_helpers.js_is_checked(selector))
        return val == true
    end

    --- Count elements matching selector.
    --- @param selector string CSS selector
    --- @return integer count
    function self:count(selector: string): integer
        local val, _ = eval(dom_helpers.js_count(selector))
        return val or 0
    end

    -- ─── Element Interaction ──────────────────────────────────────────

    --- Click on an element. Scrolls into view, then dispatches mouse events.
    --- @param selector string CSS selector
    --- @return boolean|nil ok
    --- @return string|nil error
    function self:click(selector: string): (boolean?, string?)
        local box, err = get_bounding_box(selector)
        if err then return nil, err end

        local x, y = box.x, box.y

        -- mouseMoved → mousePressed → mouseReleased
        self:send_command("Input.dispatchMouseEvent", {
            type = "mouseMoved", x = x, y = y,
        })
        self:send_command("Input.dispatchMouseEvent", {
            type = "mousePressed", x = x, y = y,
            button = "left", clickCount = 1,
        })
        local _, rel_err = self:send_command("Input.dispatchMouseEvent", {
            type = "mouseReleased", x = x, y = y,
            button = "left", clickCount = 1,
        })
        if rel_err then return nil, rel_err end

        return true, nil
    end

    --- Type text into an input element. Focuses the element first.
    --- @param selector string CSS selector
    --- @param text string Text to type
    --- @param options table|nil { clear = true (default) }
    --- @return boolean|nil ok
    --- @return string|nil error
    function self:type(selector: string, text: string, options: table?): (boolean?, string?)
        local type_opts = options or {}
        local should_clear = type_opts.clear ~= false

        -- Focus the element
        local focused, focus_err = eval(dom_helpers.js_focus(selector))
        if focus_err then return nil, focus_err end
        if not focused then
            return nil, "ELEMENT_NOT_FOUND: Selector '" .. selector .. "' not found"
        end

        -- Clear existing value if needed
        if should_clear then
            eval(dom_helpers.js_clear(selector))
        end

        -- Type each character via Input.dispatchKeyEvent
        for i = 1, #text do
            local ch = text:sub(i, i)
            self:send_command("Input.dispatchKeyEvent", {
                type = "keyDown",
                text = ch,
            })
            self:send_command("Input.dispatchKeyEvent", {
                type = "keyUp",
            })
        end

        -- Dispatch input and change events
        eval(string.format([[
            (function() {
                var el = document.querySelector(%q);
                if (el) {
                    el.dispatchEvent(new Event('input', {bubbles: true}));
                    el.dispatchEvent(new Event('change', {bubbles: true}));
                }
            })()
        ]], selector))

        return true, nil
    end

    --- Press a special keyboard key (Enter, Tab, Escape, etc.).
    --- @param key_name string Key name (e.g. "Enter", "Tab", "Escape")
    --- @return boolean|nil ok
    --- @return string|nil error
    function self:press(key_name: string): (boolean?, string?)
        local key = (dom_helpers.KEY_MAP :: table)[key_name]
        if not key then
            return nil, "INVALID: Unknown key: " .. key_name
        end

        self:send_command("Input.dispatchKeyEvent", {
            type = "rawKeyDown",
            key = key.key,
            code = key.code,
            windowsVirtualKeyCode = key.keyCode,
        })
        local _, err = self:send_command("Input.dispatchKeyEvent", {
            type = "keyUp",
            key = key.key,
            code = key.code,
            windowsVirtualKeyCode = key.keyCode,
        })
        if err then return nil, err end

        return true, nil
    end

    --- Select a dropdown option.
    --- @param selector string CSS selector for <select> element
    --- @param value string|table String value, or table { value, index, text }
    --- @return boolean|nil ok
    --- @return string|nil error
    function self:select(selector: string, value: any): (boolean?, string?)
        local js
        if type(value) == "string" then
            js = dom_helpers.js_select_by_value(selector, value)
        elseif type(value) == "table" then
            if value.index then
                js = dom_helpers.js_select_by_index(selector, value.index :: integer)
            elseif value.text then
                js = dom_helpers.js_select_by_text(selector, value.text :: string)
            elseif value.value then
                js = dom_helpers.js_select_by_value(selector, value.value :: string)
            else
                return nil, "INVALID: select value must have 'value', 'index', or 'text'"
            end
        else
            return nil, "INVALID: select value must be string or table"
        end

        local ok, err = eval(js)
        if err then return nil, err end
        if not ok then
            return nil, "ELEMENT_NOT_FOUND: Select '" .. selector .. "' not found or option not matched"
        end
        return true, nil
    end

    --- Check a checkbox (no-op if already checked).
    --- @param selector string CSS selector
    --- @return boolean|nil ok
    --- @return string|nil error
    function self:check(selector: string): (boolean?, string?)
        local ok, err = eval(dom_helpers.js_check(selector))
        if err then return nil, err end
        if not ok then
            return nil, "ELEMENT_NOT_FOUND: Selector '" .. selector .. "' not found"
        end
        return true, nil
    end

    --- Uncheck a checkbox (no-op if already unchecked).
    --- @param selector string CSS selector
    --- @return boolean|nil ok
    --- @return string|nil error
    function self:uncheck(selector: string): (boolean?, string?)
        local ok, err = eval(dom_helpers.js_uncheck(selector))
        if err then return nil, err end
        if not ok then
            return nil, "ELEMENT_NOT_FOUND: Selector '" .. selector .. "' not found"
        end
        return true, nil
    end

    --- Hover over an element. Moves mouse to element's center.
    --- @param selector string CSS selector
    --- @return boolean|nil ok
    --- @return string|nil error
    function self:hover(selector: string): (boolean?, string?)
        local box, err = get_bounding_box(selector)
        if err then return nil, err end

        local _, cmd_err = self:send_command("Input.dispatchMouseEvent", {
            type = "mouseMoved", x = box.x, y = box.y,
        })
        if cmd_err then return nil, cmd_err end
        return true, nil
    end

    --- Focus an element.
    --- @param selector string CSS selector
    --- @return boolean|nil ok
    --- @return string|nil error
    function self:focus(selector: string): (boolean?, string?)
        local ok, err = eval(dom_helpers.js_focus(selector))
        if err then return nil, err end
        if not ok then
            return nil, "ELEMENT_NOT_FOUND: Selector '" .. selector .. "' not found"
        end
        return true, nil
    end

    --- Upload file(s) to a file input element.
    --- @param selector string CSS selector for <input type="file">
    --- @param file_path string|{string} File path(s)
    --- @return boolean|nil ok
    --- @return string|nil error
    function self:upload(selector: string, file_path: any): (boolean?, string?)
        -- Get the DOM document and resolve the node
        local doc, doc_err = self:send_command("DOM.getDocument", {})
        if doc_err then return nil, doc_err end

        local node, node_err = self:send_command("DOM.querySelector", {
            nodeId = doc.root.nodeId,
            selector = selector,
        })
        if node_err then return nil, node_err end
        if not node or node.nodeId == 0 then
            return nil, "ELEMENT_NOT_FOUND: Selector '" .. selector .. "' not found"
        end

        local files
        if type(file_path) == "string" then
            files = { file_path }
        elseif type(file_path) == "table" then
            files = file_path
        else
            return nil, "INVALID: file_path must be string or array of strings"
        end

        local _, err = self:send_command("DOM.setFileInputFiles", {
            nodeId = node.nodeId,
            files = files,
        })
        if err then return nil, err end

        return true, nil
    end

    -- ─── JavaScript Execution ─────────────────────────────────────────

    --- Evaluate a JavaScript expression and return the result.
    --- If additional arguments are provided, the expression is treated as a
    --- function string and called with those arguments.
    ---
    --- @param expression string JavaScript expression or function string
    --- @param ... any Arguments to pass (when expression is a function)
    --- @return any|nil value Result value
    --- @return string|nil error
    function self:eval(expression: string, ...): (any?, string?)
        local args = {...}

        local js = expression
        if #args > 0 then
            -- Serialize arguments into JS literals and wrap as IIFE call
            local parts = {}
            for _, arg in ipairs(args) do
                if type(arg) == "string" then
                    -- Escape for JS string literal
                    local escaped = arg:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r")
                    table.insert(parts, '"' .. escaped .. '"')
                elseif type(arg) == "number" then
                    table.insert(parts, tostring(arg))
                elseif type(arg) == "boolean" then
                    table.insert(parts, arg and "true" or "false")
                elseif arg == nil then
                    table.insert(parts, "null")
                else
                    table.insert(parts, tostring(arg))
                end
            end
            js = "(" .. expression .. ")(" .. table.concat(parts, ",") .. ")"
        end

        local result, err = self:send_command("Runtime.evaluate", {
            expression = js,
            returnByValue = true,
        })
        if err then return nil, err end

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

    --- Evaluate JavaScript that returns a Promise, waiting for resolution.
    --- @param expression string JavaScript expression returning a Promise
    --- @return any|nil value Resolved value
    --- @return string|nil error
    function self:eval_async(expression: string): (any?, string?)
        local result, err = self:send_command("Runtime.evaluate", {
            expression = expression,
            returnByValue = true,
            awaitPromise = true,
        })
        if err then return nil, err end

        if result.exceptionDetails then
            local exc = result.exceptionDetails
            local msg = "EVAL_ERROR: "
            if exc.exception and exc.exception.description then
                msg = msg .. exc.exception.description
            elseif exc.text then
                msg = msg .. exc.text
            else
                msg = msg .. "Async JavaScript evaluation error"
            end
            return nil, msg
        end

        if result.result then
            return result.result.value, nil
        end

        return nil, nil
    end

    -- ─── Screenshots & PDF ────────────────────────────────────────────

    --- Capture a screenshot of the page or a specific element.
    ---
    --- Usage:
    ---   tab:screenshot()                              -- viewport PNG
    ---   tab:screenshot("#chart")                      -- element PNG
    ---   tab:screenshot({ full_page = true })          -- full scrollable page
    ---   tab:screenshot({ format = "jpeg", quality = 80 })
    ---
    --- @param selector_or_options string|table|nil CSS selector, options table, or nil
    --- @return string|nil bytes Raw image bytes
    --- @return string|nil error
    function self:screenshot(selector_or_options: any?): (string?, string?)
        local params: {[string]: any} = { format = "png" }
        local reset_viewport = false

        if type(selector_or_options) == "string" then
            -- Element screenshot: get bounding box as clip region
            local box_js = string.format([[
                (function() {
                    var el = document.querySelector(%q);
                    if (!el) return null;
                    el.scrollIntoView({block: 'center', inline: 'center'});
                    var rect = el.getBoundingClientRect();
                    return {
                        x: rect.x, y: rect.y,
                        width: rect.width, height: rect.height,
                        scale: window.devicePixelRatio || 1
                    };
                })()
            ]], selector_or_options)

            local box_result, box_err = self:send_command("Runtime.evaluate", {
                expression = box_js,
                returnByValue = true,
            })
            if box_err then return nil, box_err end

            local box = box_result.result and box_result.result.value
            if not box then
                return nil, "ELEMENT_NOT_FOUND: Selector '" .. selector_or_options .. "' not found for screenshot"
            end

            params.clip = {
                x = box.x,
                y = box.y,
                width = box.width,
                height = box.height,
                scale = box.scale or 1,
            }

        elseif type(selector_or_options) == "table" then
            local ss_opts = selector_or_options
            params.format = ss_opts.format or "png"

            if ss_opts.quality and params.format == "jpeg" then
                params.quality = ss_opts.quality
            end

            if ss_opts.full_page then
                -- Get full scrollable dimensions
                local dims_result, dims_err = self:send_command("Runtime.evaluate", {
                    expression = [[({
                        width: Math.max(
                            document.documentElement.scrollWidth,
                            document.body ? document.body.scrollWidth : 0
                        ),
                        height: Math.max(
                            document.documentElement.scrollHeight,
                            document.body ? document.body.scrollHeight : 0
                        ),
                        dpr: window.devicePixelRatio || 1
                    })]],
                    returnByValue = true,
                })
                if dims_err then return nil, dims_err end

                local dims = dims_result.result and dims_result.result.value
                if dims then
                    self:send_command("Emulation.setDeviceMetricsOverride", {
                        width = dims.width,
                        height = dims.height,
                        deviceScaleFactor = dims.dpr,
                        mobile = false,
                    })
                    reset_viewport = true
                    params.captureBeyondViewport = true
                end
            end
        end

        local result, err = self:send_command("Page.captureScreenshot", params)

        -- Reset viewport if we changed it
        if reset_viewport then
            self:send_command("Emulation.clearDeviceMetricsOverride", {})
        end

        if err then return nil, err end

        if not result.data then
            return nil, "SCREENSHOT_FAILED: No image data returned"
        end

        -- CDP returns base64-encoded image
        return base64.decode(result.data :: string), nil
    end

    --- Generate a PDF of the current page (headless Chrome only).
    ---
    --- Usage:
    ---   tab:pdf()
    ---   tab:pdf({ format = "A4", landscape = true })
    ---   tab:pdf({ margin = { top = "1cm", bottom = "1cm", left = "1cm", right = "1cm" } })
    ---
    --- @param options table|nil PDF options
    --- @return string|nil bytes Raw PDF bytes
    --- @return string|nil error
    function self:pdf(options: table?): (string?, string?)
        local pdf_opts = options or {}

        -- Paper size lookup (dimensions in inches)
        local paper_sizes = {
            A4     = { width = 8.27,  height = 11.69 },
            Letter = { width = 8.5,   height = 11.0 },
            Legal  = { width = 8.5,   height = 14.0 },
            A3     = { width = 11.69, height = 16.54 },
            A5     = { width = 5.83,  height = 8.27 },
            Tabloid= { width = 11.0,  height = 17.0 },
        }

        local paper = paper_sizes[pdf_opts.format or "A4"] or paper_sizes.A4

        local params: {[string]: any} = {
            landscape = pdf_opts.landscape or false,
            printBackground = pdf_opts.print_background ~= false,
            paperWidth = paper.width,
            paperHeight = paper.height,
        }

        -- Parse margin values (CSS units → inches)
        if pdf_opts.margin then
            params.marginTop    = parse_margin(pdf_opts.margin.top or "1cm")
            params.marginBottom = parse_margin(pdf_opts.margin.bottom or "1cm")
            params.marginLeft   = parse_margin(pdf_opts.margin.left or "1cm")
            params.marginRight  = parse_margin(pdf_opts.margin.right or "1cm")
        end

        local result, err = self:send_command("Page.printToPDF", params)
        if err then return nil, err end

        if not result.data then
            return nil, "PDF_FAILED: No PDF data returned"
        end

        return base64.decode(result.data :: string), nil
    end

    -- ─── Downloads ────────────────────────────────────────────────────

    --- Intercept a download triggered by an action.
    --- Enables Fetch interception, executes the action function, then captures
    --- the download response body in-memory.
    ---
    --- Usage:
    ---   local dl, err = tab:expect_download(function()
    ---       tab:click("#download-btn")
    ---   end, { timeout = "30s" })
    ---   -- dl.data, dl.filename, dl.mime_type, dl.size
    ---
    --- @param action_fn function Function that triggers the download (e.g. a click)
    --- @param options table|nil { timeout = "30s" }
    --- @return table|nil download { data, filename, mime_type, size }
    --- @return string|nil error
    function self:expect_download(action_fn: any, options: table?): (table?, string?)
        local dl_opts = options or {}
        local timeout = dl_opts.timeout or self._default_timeout

        local evt_ch, ch_err = get_event_ch()
        if ch_err then return nil, ch_err end

        -- Build Fetch patterns that cover both resource blocking (Request stage)
        -- and download interception (Response stage)
        local patterns = {{ requestStage = "Response" }}
        if self._blocked_resources then
            -- Already blocking resources at Request stage — need both stages
            patterns = {
                { requestStage = "Request" },
                { requestStage = "Response" },
            }
        end

        -- Re-enable Fetch with combined patterns
        self:send_command("Fetch.disable", {})
        self:send_command("Fetch.enable", {
            patterns = patterns,
            handleAuthRequests = false,
        })

        -- Enable download events
        self:send_command("Page.setDownloadBehavior", {
            behavior = "allowAndName",
            downloadPath = "/tmp",
            eventsEnabled = true,
        })

        -- Execute the action that triggers the download
        action_fn()

        -- Wait for Fetch.requestPaused with download content
        local deadline = time.after(timeout)

        while true do
            local r = channel.select {
                evt_ch:case_receive(),
                deadline:case_receive(),
            }

            if r.channel == deadline then
                self:_restore_fetch_state()
                return nil, "DOWNLOAD_TIMEOUT: No download completed within " .. timeout
            end

            if not r.ok then
                return nil, "TAB_CLOSED: Event channel closed during download"
            end

            local evt = r.value

            if evt.method == "Fetch.requestPaused" then
                local params = evt.params

                -- Check if this is at Response stage (has responseStatusCode)
                if params.responseStatusCode then
                    -- Response stage: check for download
                    local is_download = false
                    local filename = nil
                    local mime_type = nil

                    for _, header in ipairs(params.responseHeaders or {}) do
                        local name_lower = header.name:lower()
                        if name_lower == "content-disposition" then
                            if header.value:find("attachment") then
                                is_download = true
                            end
                            filename = header.value:match('filename="?([^";\n]+)"?')
                        elseif name_lower == "content-type" then
                            mime_type = header.value:match("^([^;]+)")
                        end
                    end

                    if is_download then
                        -- Get the response body
                        local body_result, body_err = self:send_command("Fetch.getResponseBody", {
                            requestId = params.requestId,
                        })

                        if body_err then
                            pcall(function()
                                self:send_command("Fetch.continueResponse", {
                                    requestId = params.requestId,
                                })
                            end)
                            self:_restore_fetch_state()
                            return nil, "DOWNLOAD_FAILED: Could not read response body: " .. tostring(body_err)
                        end

                        local data
                        if body_result.base64Encoded then
                            data = base64.decode(body_result.body :: string)
                        else
                            data = body_result.body
                        end

                        -- Fulfill with empty body to prevent Chrome from writing to disk
                        pcall(function()
                            self:send_command("Fetch.fulfillRequest", {
                                requestId = params.requestId,
                                responseCode = 200,
                                responseHeaders = params.responseHeaders or {},
                                body = "",
                            })
                        end)

                        self:_restore_fetch_state()

                        return {
                            data = data,
                            filename = filename or "download",
                            mime_type = mime_type or "application/octet-stream",
                            size = data and #data or 0,
                        }, nil
                    else
                        -- Not a download response, continue normally
                        pcall(function()
                            self:send_command("Fetch.continueResponse", {
                                requestId = params.requestId,
                            })
                        end)
                    end
                else
                    -- Request stage: handle resource blocking
                    process_fetch_event(self, evt :: table)
                end
            end
            -- Other events (Page.downloadWillBegin, etc.) are consumed and ignored
        end
    end

    --- Internal: restore Fetch domain state after download interception.
    --- Re-enables resource blocking if it was active, otherwise disables Fetch.
    function self:_restore_fetch_state()
        if self._blocked_resources then
            -- Re-enable Fetch for resource blocking only (Request stage)
            pcall(function() self:send_command("Fetch.disable", {}) end)
            pcall(function()
                self:send_command("Fetch.enable", {
                    patterns = {{ requestStage = "Request" }},
                })
            end)
        else
            pcall(function() self:send_command("Fetch.disable", {}) end)
        end
    end

    -- ─── Tab Configuration ────────────────────────────────────────────

    --- Override the viewport dimensions for this tab.
    --- @param width integer Viewport width in pixels
    --- @param height integer Viewport height in pixels
    --- @return table|nil result
    --- @return string|nil error
    function self:set_viewport(width: integer, height: integer): (table?, string?)
        return self:send_command("Emulation.setDeviceMetricsOverride", {
            width = width,
            height = height,
            deviceScaleFactor = 1,
            mobile = false,
        })
    end

    --- Set a custom user agent string for this tab.
    --- @param ua string User agent string
    --- @return table|nil result
    --- @return string|nil error
    function self:set_user_agent(ua: string): (table?, string?)
        return self:send_command("Emulation.setUserAgentOverride", {
            userAgent = ua,
        })
    end

    --- Set extra HTTP headers sent with every request from this tab.
    --- @param headers table Header map { ["Name"] = "value", ... }
    --- @return table|nil result
    --- @return string|nil error
    function self:set_headers(headers: table): (table?, string?)
        return self:send_command("Network.setExtraHTTPHeaders", {
            headers = headers,
        })
    end

    --- Update the default timeout for this tab's operations.
    --- @param timeout string Timeout duration (e.g. "15s", "5000ms")
    function self:set_timeout(timeout: string)
        self._default_timeout = timeout
    end

    --- Block specific resource types to speed up scraping.
    --- Enables Fetch interception and fails matching requests.
    ---
    --- @param resource_types {string} Array of types: "image", "stylesheet", "font",
    ---   "media", "script", "xhr", "fetch", "websocket"
    --- @return boolean|nil ok
    --- @return string|nil error
    function self:block_resources(resource_types: {string}): (boolean?, string?)
        -- Map friendly names to CDP Network.ResourceType values
        local type_map = {
            image      = "Image",
            stylesheet = "Stylesheet",
            font       = "Font",
            media      = "Media",
            script     = "Script",
            xhr        = "XHR",
            fetch      = "Fetch",
            websocket  = "WebSocket",
            document   = "Document",
            manifest   = "Manifest",
            texttrack  = "TextTrack",
            eventsource= "EventSource",
            other      = "Other",
        }

        local blocked = {}
        for _, t in ipairs(resource_types) do
            blocked[type_map[t] or t] = true
        end

        self._blocked_resources = blocked

        -- Enable Fetch interception at Request stage
        local _, err = self:send_command("Fetch.enable", {
            patterns = {{ requestStage = "Request" }},
        })
        if err then return nil, err end

        -- Resource blocking events are now handled inline by wait_for_event,
        -- wait_for_network_idle, and expect_download. No manual event loop needed.
        return true, nil
    end

    -- ─── Lifecycle ────────────────────────────────────────────────────

    function self:close()
        if not self._alive then return end
        self._alive = false
        if self._event_ch then
            pcall(function() process.unlisten(self._event_ch) end)
            self._event_ch = nil
        end
        process.send(self._manager_pid, "tab.close", {
            sid = self._session_id,
        })
    end

    function self:is_alive(): boolean
        return self._alive
    end

    function self:session_id(): string
        return self._session_id
    end

    function self:default_timeout(): string
        return self._default_timeout
    end

    function self:default_navigation_timeout(): string
        return self._default_navigation_timeout
    end

    return self
end

return tab_mod
