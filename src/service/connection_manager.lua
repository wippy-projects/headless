--- Connection Manager Process
---
--- Long-running process that owns the CDP WebSocket connection.
--- Handles tab creation/destruction, routes CDP commands from Tab objects,
--- and dispatches CDP events to per-session subscriber channels.
---
--- Message protocol (Tab/browser lib → Manager):
---   topic "tab.create"  → payload { sender_pid, options }
---   topic "tab.command"  → payload { sender_pid, sid, method, params }
---   topic "tab.close"    → payload { sid }
---
--- Manager → Tab (event forwarding):
---   topic "tab.cdp_event" → CDP event table { method, params, ... }
---
--- The manager monitors the PID of each tab's owning process.
--- On EXIT, it auto-cleans the tab resources (safety net).

local logger = require("logger")
local env = require("env")
local time = require("time")
local cdp_connection = require("cdp_connection")

local REGISTRY_NAME = "headless.manager"

--- Create a BrowserContext + Target + attach session.
--- Returns session info or nil, error.
local function create_tab(conn, opts)
    local log = logger:named("headless.manager")

    -- 1. Create isolated BrowserContext
    local ctx_result, ctx_err = conn:send("Target.createBrowserContext", {
        disposeOnDetach = true,
    })
    if ctx_err then
        return nil, "Failed to create browser context: " .. tostring(ctx_err)
    end
    local context_id = ctx_result.browserContextId

    -- 2. Create a new page target in that context
    local target_result, target_err = conn:send("Target.createTarget", {
        url = "about:blank",
        browserContextId = context_id,
    })
    if target_err then
        -- Cleanup context on failure
        conn:send("Target.disposeBrowserContext", { browserContextId = context_id })
        return nil, "Failed to create target: " .. tostring(target_err)
    end
    local target_id = target_result.targetId

    -- 3. Attach to the target to get a session
    local attach_result, attach_err = conn:send("Target.attachToTarget", {
        targetId = target_id,
        flatten = true,
    })
    if attach_err then
        conn:send("Target.closeTarget", { targetId = target_id })
        conn:send("Target.disposeBrowserContext", { browserContextId = context_id })
        return nil, "Failed to attach to target: " .. tostring(attach_err)
    end
    local session_id = attach_result.sessionId :: string

    -- 4. Enable essential CDP domains on the session
    local domains = { "Page", "Runtime", "Network", "DOM" }
    for _, domain in ipairs(domains) do
        local _, enable_err = conn:send(domain .. ".enable", {}, session_id)
        if enable_err then
            log:warn("Failed to enable domain", { domain = domain, error = tostring(enable_err) })
        end
    end

    return {
        session_id = session_id,
        target_id = target_id,
        context_id = context_id,
    }, nil
end

--- Close a tab: close target and dispose browser context.
local function close_tab(conn, tab_info)
    local log = logger:named("headless.manager")

    -- Detach from target (ignore errors — might already be detached)
    if tab_info.session_id then
        conn:send("Target.detachFromTarget", {
            sessionId = tab_info.session_id,
        })
    end

    -- Close the target
    if tab_info.target_id then
        local _, err = conn:send("Target.closeTarget", {
            targetId = tab_info.target_id,
        })
        if err then
            log:debug("Close target error (may be expected)", { error = tostring(err) })
        end
    end

    -- Dispose browser context
    if tab_info.context_id then
        local _, err = conn:send("Target.disposeBrowserContext", {
            browserContextId = tab_info.context_id,
        })
        if err then
            log:debug("Dispose context error (may be expected)", { error = tostring(err) })
        end
    end
end

--- Main entry point for the connection manager process.
--- @param config table { address = "host:port", options = {...} }
local function main(config)
    local log = logger:named("headless.manager")
    local cfg = config or {}

    local address = cfg.address
        or env.get("headless.chrome_address")
        or "localhost:9222"

    local options = cfg.options or {}
    local max_tabs = options.max_tabs or 0  -- 0 = unlimited

    -- Connect to Chrome
    log:info("Connecting to Chrome", { address = address })
    local conn_opt, conn_err = cdp_connection.new(address, options)
    if not conn_opt then
        log:error("Failed to connect to Chrome", { error = tostring(conn_err) })
        return nil, conn_err
    end
    local conn = conn_opt
    log:info("Connected to Chrome", { ws_url = conn:ws_url() })

    -- Verify connection
    local version, ver_err = conn:send("Browser.getVersion")
    if ver_err then
        log:error("Failed to get browser version", { error = tostring(ver_err) })
        conn:close()
        return nil, ver_err
    end
    log:info("Chrome version", {
        product = version.product,
        protocol = version.protocolVersion,
    })

    -- Register in process registry so Tab objects can find us
    process.registry.register(REGISTRY_NAME)

    -- Tab tracking: session_id → { target_id, context_id, owner_pid, event_ch }
    local tabs = {}
    -- Reverse mapping: owner_pid → { session_id, ... }
    local pid_tabs = {}
    -- Monitored PIDs (to avoid double monitoring)
    local monitored_pids = {}
    -- Active tab count
    local active_tab_count = 0
    -- Waiters queue: list of { options, sender } waiting for a tab slot
    local waiters = {}
    -- Pending async commands: CDP command ID → { sender, method }
    local pending = {}

    --- Route a CDP response to the pending async command that sent it.
    --- Replies to the tab's sender process and removes from pending.
    local function route_response(resp: table)
        local cmd_id = resp.id
        local cmd = pending[cmd_id]
        if not cmd then return end
        pending[cmd_id] = nil

        if resp.type == "error" then
            local cdp_err = resp.error or {}
            pcall(function()
                process.send(cmd.sender, "tab.command.reply", {
                    result = nil,
                    error = "CDP error (" .. tostring(cdp_err.code) .. "): " .. tostring(cdp_err.message),
                })
            end)
        else
            pcall(function()
                process.send(cmd.sender, "tab.command.reply", { result = resp.result, error = nil })
            end)
        end
    end

    --- Drain any responses buffered during a blocking conn:send() call
    --- and route them to their pending async commands.
    local function drain_buffered()
        for _, resp in ipairs(conn:drain_responses()) do
            route_response(resp :: table)
        end
    end

    --- Fail all pending async commands with an error message.
    --- Used on disconnect/shutdown.
    local function fail_all_pending(error_msg: string)
        for _, cmd in pairs(pending) do
            pcall(function()
                process.send(cmd.sender :: string, "tab.command.reply", { result = nil, error = error_msg })
            end)
        end
        pending = {}
    end

    local ch_create = process.listen("tab.create")
    local ch_command = process.listen("tab.command")
    local ch_close = process.listen("tab.close")
    local events = process.events()

    --- Helper: actually create a tab and register tracking.
    --- @param tab_opts table Tab options
    --- @param sender any Sender PID
    local function do_create_tab(tab_opts, sender)
        local info, err = create_tab(conn, tab_opts)
        if err then
            if sender then
                process.send(sender, "tab.created", { error = err })
            end
            return
        end

        local sid = info.session_id :: string

        -- Subscribe to CDP events for this session
        local event_ch = conn:subscribe(sid)

        -- Track the tab
        tabs[sid] = {
            session_id = sid,
            target_id = info.target_id,
            context_id = info.context_id,
            owner_pid = sender,
            event_ch = event_ch,
        }
        active_tab_count = active_tab_count + 1

        -- Track by owner PID
        if sender then
            local owner = tostring(sender)
            if not pid_tabs[owner] then
                pid_tabs[owner] = {}
            end
            table.insert(pid_tabs[owner], sid)

            -- Monitor owner for cleanup on exit
            if not monitored_pids[owner] then
                process.monitor(sender)
                monitored_pids[owner] = true
            end
        end

        -- Reply to sender via process.send
        if sender then
            process.send(sender, "tab.created", {
                session_id = sid,
                target_id = info.target_id,
                context_id = info.context_id,
                options = {
                    default_timeout = options.default_timeout or "30s",
                    default_navigation_timeout = options.default_navigation_timeout or "60s",
                },
            })
        end

        log:info("Tab created", {
            session_id = sid,
            owner_pid = sender and tostring(sender) or "unknown",
            active_tabs = active_tab_count,
        })
    end

    --- Helper: remove a tab from all tracking structures.
    --- @param sid string Session ID
    local function remove_tab(sid)
        local info = tabs[sid]
        if not info then return end

        close_tab(conn, info)

        if info.event_ch then
            pcall(function() info.event_ch:close() end)
        end
        conn:unsubscribe(sid)

        -- Remove from owner tracking
        if info.owner_pid then
            local owner = tostring(info.owner_pid)
            if pid_tabs[owner] then
                local filtered = {}
                for _, s in ipairs(pid_tabs[owner]) do
                    if s ~= sid then
                        table.insert(filtered, s)
                    end
                end
                if #filtered > 0 then
                    pid_tabs[owner] = filtered
                else
                    pid_tabs[owner] = nil
                end
            end
        end

        tabs[sid] = nil
        active_tab_count = active_tab_count - 1
        if active_tab_count < 0 then active_tab_count = 0 end
    end

    --- Helper: try to serve the next waiter in queue after a tab was released.
    local function serve_next_waiter()
        while #waiters > 0 do
            local waiter = table.remove(waiters, 1)
            -- Check if the reply channel is still valid (waiter might have timed out)
            local ok = pcall(function()
                do_create_tab(waiter.options :: table, waiter.sender)
            end)
            if ok then
                return  -- Successfully served one waiter
            end
            -- If send failed (waiter timed out and closed channel), try next
        end
    end

    log:info("Manager ready", { max_tabs = max_tabs })

    -- Health check timer: periodically verify Chrome is still reachable
    local health_interval = options.health_check_interval or "30s"
    local health_timer = time.after(health_interval)

    local ws_ch = conn:ws_channel()

    while true do
        -- Build select cases: fixed channels + per-tab event channels + WebSocket
        local cases = {
            ch_create:case_receive(),
            ch_command:case_receive(),
            ch_close:case_receive(),
            events:case_receive(),
            health_timer:case_receive(),
            ws_ch:case_receive(),
        }
        -- Add per-tab CDP event channels for forwarding
        local evt_ch_to_sid = {}
        for sid, info in pairs(tabs) do
            if info.event_ch and info.owner_pid then
                table.insert(cases, info.event_ch:case_receive())
                evt_ch_to_sid[info.event_ch] = sid
            end
        end
        local r = channel.select(cases)

        if r.channel == ws_ch then
            -- WebSocket message: dispatch events, route responses to pending commands
            if r.ok then
                local resp = conn:pump_message(r.value)
                if resp then
                    route_response(resp :: table)
                end
            end

        elseif r.channel == health_timer then
            -- Periodic health check: verify Chrome connection
            if conn:is_alive() then
                local _, hc_err = conn:send("Browser.getVersion", nil, nil, "5s")
                drain_buffered()
                if hc_err then
                    log:error("Chrome health check failed", { error = tostring(hc_err) })
                    -- Fail all pending async commands
                    fail_all_pending("CDP_DISCONNECTED: Chrome connection lost")
                    -- Invalidate all tabs
                    for sid, info in pairs(tabs) do
                        if info.event_ch then
                            pcall(function() info.event_ch:close() end)
                        end
                        conn:unsubscribe(sid)
                    end
                    tabs = {}
                    pid_tabs = {}
                    monitored_pids = {}
                    active_tab_count = 0

                    -- Reject all waiters
                    for _, waiter in ipairs(waiters) do
                        pcall(function()
                            process.send(waiter.sender :: string, "tab.created", { error = "CDP_DISCONNECTED: Chrome connection lost" })
                        end)
                    end
                    waiters = {}

                    -- Attempt reconnection
                    conn:close()
                    log:info("Attempting reconnection to Chrome", { address = address })
                    local new_conn, reconn_err = cdp_connection.new(address, options)
                    if not new_conn then
                        log:error("Reconnection failed, exiting", { error = tostring(reconn_err) })
                        return 1  -- Supervisor will restart us
                    end
                    conn = new_conn
                    ws_ch = conn:ws_channel()
                    log:info("Reconnected to Chrome", { ws_url = conn:ws_url() })
                end
            else
                -- Connection already known dead, attempt reconnect
                log:info("Attempting reconnection to Chrome", { address = address })
                local new_conn, reconn_err = cdp_connection.new(address, options)
                if not new_conn then
                    log:error("Reconnection failed, exiting", { error = tostring(reconn_err) })
                    return 1
                end
                conn = new_conn
                log:info("Reconnected to Chrome", { ws_url = conn:ws_url() })
            end
            health_timer = time.after(health_interval)

        elseif r.channel == events then
            local event = r.value

            if event.kind == process.event.CANCEL then
                log:info("Shutting down, closing all tabs", {
                    active_tabs = active_tab_count,
                })
                -- Fail all pending async commands
                fail_all_pending("CDP_DISCONNECTED: Manager shutting down")
                for sid, _ in pairs(tabs) do
                    remove_tab(sid)
                end
                -- Reject all waiters
                for _, waiter in ipairs(waiters) do
                    pcall(function()
                        process.send(waiter.sender :: string, "tab.created", { error = "CDP_DISCONNECTED: Manager shutting down" })
                    end)
                end
                conn:close()
                return 0
            end

            if event.kind == process.event.EXIT and event.from then
                -- Owner process exited — clean up its tabs
                local owner = tostring(event.from)
                local owner_sessions = pid_tabs[owner]
                if owner_sessions then
                    -- Copy list since remove_tab modifies pid_tabs
                    local sessions_copy = {}
                    for _, sid in ipairs(owner_sessions) do
                        table.insert(sessions_copy, sid)
                    end
                    for _, sid in ipairs(sessions_copy) do
                        log:info("Cleaning up tab (owner exited)", {
                            session_id = sid,
                            owner_pid = owner,
                        })
                        remove_tab(sid)
                    end
                    monitored_pids[owner] = nil
                    drain_buffered()

                    -- A tab was freed, serve waiting requests
                    serve_next_waiter()
                    drain_buffered()
                end
            end

        elseif r.channel == ch_create then
            local payload = r.value
            local sender = payload.sender_pid
            local tab_opts = payload.options or {}

            -- Check max_tabs limit
            if max_tabs > 0 and active_tab_count >= max_tabs then
                -- Queue the waiter — reply via process.send when slot opens
                table.insert(waiters, {
                    options = tab_opts,
                    sender = sender,
                })
                log:debug("Tab creation queued (pool full)", {
                    active_tabs = active_tab_count,
                    max_tabs = max_tabs,
                    waiters = #waiters,
                })
            else
                do_create_tab(tab_opts, sender)
                drain_buffered()
            end

        elseif r.channel == ch_command then
            local payload = r.value
            local sender = payload.sender_pid :: string
            local sid = payload.sid
            local method = payload.method
            local params = payload.params or {}

            if not tabs[sid] then
                process.send(sender, "tab.command.reply", { result = nil, error = "TAB_CLOSED: Tab session not found" })
            elseif not conn:is_alive() then
                process.send(sender, "tab.command.reply", { result = nil, error = "CDP_DISCONNECTED: Chrome connection lost" })
            else
                -- Non-blocking: send command, track by ID, response routed via ws_ch handler
                local cmd_id, send_err = conn:send_async(method, params, sid)
                if send_err then
                    process.send(sender, "tab.command.reply", { result = nil, error = send_err })
                else
                    pending[cmd_id :: integer] = { sender = sender, method = method }
                end
            end

        elseif r.channel == ch_close then
            local payload = r.value
            local sid = payload.sid

            if tabs[sid] then
                remove_tab(sid)
                drain_buffered()
                log:info("Tab closed", {
                    session_id = sid,
                    active_tabs = active_tab_count,
                })

                -- A tab was freed, serve waiting requests
                serve_next_waiter()
                drain_buffered()
            end

        else
            -- Check if it's a per-tab CDP event channel
            local fwd_sid = evt_ch_to_sid[r.channel]
            if fwd_sid and r.ok then
                local info = tabs[fwd_sid]
                if info and info.owner_pid then
                    -- Forward CDP event to the tab's owner process
                    pcall(function()
                        process.send(info.owner_pid, "tab.cdp_event", r.value)
                    end)
                end
            end
        end
    end
end

return { main = main }
