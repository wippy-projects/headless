--- Browser Public API
---
--- User-facing module for headless browser automation.
---
--- Usage:
---   local browser = require("browser")
---   local tab, err = browser.new_tab("app:chrome")
---   -- use tab...
---   tab:close()

local time = require("time")
local tab_mod = require("tab")

local MANAGER_REGISTRY_NAME = "headless.manager"

local browser = {}

--- Create a new browser tab connected to the headless Chrome instance.
---
--- The tab is an isolated browsing context (incognito-like). Each tab has
--- its own cookies, storage, and cache. The connection manager must be
--- running (auto-started via process.service).
---
--- @param registry_name string|nil Registry name (currently unused, reserved for multi-browser)
--- @param options table|nil Tab options
--- @return table|nil tab Tab object
--- @return string|nil error
function browser.new_tab(registry_name: string?, options: table?): (table?, string?)
    -- Look up the connection manager process
    local manager_pid, lookup_err = process.registry.lookup(MANAGER_REGISTRY_NAME)
    if lookup_err or not manager_pid then
        return nil, "CDP_CONNECTION_FAILED: Browser manager not found. "
            .. "Ensure the headless module is configured and Chrome is running. "
            .. "Error: " .. tostring(lookup_err or "manager not registered")
    end

    -- Listen for the reply on a dedicated topic
    local reply_ch = process.listen("tab.created")

    -- Send tab creation request to manager
    process.send(manager_pid, "tab.create", {
        sender_pid = process.pid(),
        options = options or {},
    })

    -- Wait for response
    local timeout_ch = time.after("30s")
    local r = channel.select {
        reply_ch:case_receive(),
        timeout_ch:case_receive(),
    }
    process.unlisten(reply_ch)

    if r.channel == timeout_ch then
        return nil, "TIMEOUT: Tab creation timed out after 30s"
    end

    if not r.ok then
        return nil, "CDP_CONNECTION_FAILED: Reply channel closed unexpectedly"
    end

    local payload = r.value
    if payload.error then
        return nil, "CDP_CONNECTION_FAILED: " .. tostring(payload.error)
    end

    -- Create Tab object
    local tab = tab_mod.new(
        manager_pid,
        payload.session_id :: string,
        payload.target_id :: string,
        payload.context_id :: string,
        (payload.options or {}) :: table
    )

    return tab :: table, nil
end

return browser
