--- CDP WebSocket Connection
---
--- Manages a WebSocket connection to Chrome's DevTools Protocol endpoint.
--- Handles discovery of the debugger URL, message routing (responses to callers,
--- events to session subscribers), and clean shutdown.
---
--- Architecture:
---   1. HTTP GET /json/version -> discover webSocketDebuggerUrl
---   2. WebSocket connect to debugger URL
---   3. send() writes command to WS, then pumps incoming messages until
---      the matching response arrives (or timeout), dispatching events along the way
---   4. In Stage 2, a dedicated manager process will own this connection
---      and route messages via process.send + channels

local websocket = require("websocket")
local http_client = require("http_client")
local json = require("json")
local time = require("time")
local cdp_protocol = require("cdp_protocol")

local connection = {}

--- Default options for CDP connections.
local DEFAULTS = {
    connect_timeout = "10s",
    default_timeout = "30s",
    read_timeout = "120s",
}

--- Discover the WebSocket debugger URL from Chrome's HTTP endpoint.
--- @param address string Chrome address in "host:port" format
--- @param timeout string Connection timeout
--- @return string|nil ws_url WebSocket debugger URL
--- @return string|nil error
local function discover_ws_url(address: string, timeout: string): (string?, string?)
    local url = "http://" .. address .. "/json/version"

    local resp, err = http_client.get(url, { timeout = timeout })
    if err then
        return nil, "CDP discovery failed at " .. url .. ": " .. tostring(err)
    end

    if resp.status_code ~= 200 then
        return nil, "CDP discovery returned HTTP " .. resp.status_code
    end

    local body = resp.body
    if type(body) == "string" then
        local ok, parsed = pcall(json.decode, body)
        if ok and parsed then
            body = parsed
        else
            return nil, "CDP discovery returned invalid JSON"
        end
    end

    if type(body) ~= "table" or not body.webSocketDebuggerUrl then
        return nil, "CDP discovery response missing webSocketDebuggerUrl"
    end

    return body.webSocketDebuggerUrl :: string, nil
end

--- Create a new CDP connection to a Chrome instance.
---
--- The connection communicates with Chrome over a single WebSocket.
--- Commands are sent with monotonically increasing IDs, and responses are
--- correlated by ID. CDP events are dispatched to per-session subscriber
--- channels as they arrive during send() calls.
---
--- @param address string Chrome address in "host:port" format
--- @param options table|nil Connection options
--- @return table|nil conn Connection object
--- @return string|nil error
function connection.new(address: string, options: table?): (table?, string?)
    local opts = options or {}
    local connect_timeout = opts.connect_timeout or DEFAULTS.connect_timeout
    local default_timeout = opts.default_timeout or DEFAULTS.default_timeout
    local read_timeout = opts.read_timeout or DEFAULTS.read_timeout

    -- Step 1: Discover WebSocket debugger URL
    local ws_url, disc_err = discover_ws_url(address, connect_timeout)
    if disc_err then
        return nil, disc_err
    end

    -- Step 2: Connect WebSocket
    local ws, ws_err = websocket.connect(ws_url, {
        dial_timeout = connect_timeout,
        read_timeout = read_timeout,
        channel_capacity = 256,
    })
    if ws_err then
        return nil, "CDP WebSocket connection failed: " .. tostring(ws_err)
    end

    -- Internal state
    local proto_opt = cdp_protocol.new()
    if not proto_opt then
        return nil, "Failed to initialize CDP protocol"
    end
    local proto = proto_opt :: table
    local ws_ch = ws:channel()
    local session_subs = {}         -- session_id -> event channel
    local browser_events = {}               -- buffer for browser-level events
    local closed = false

    -- Buffered responses that arrived while we were waiting for a different ID
    local buffered_responses = {}

    local self = {}

    --- Dispatch a CDP event to the appropriate subscriber channel.
    --- Events without a matching subscriber are silently dropped.
    local function dispatch_event(decoded: table)
        local sid = decoded.session_id
        if sid and session_subs[sid] then
            -- Non-blocking send: if buffer full, drop (subscriber too slow)
            pcall(function() (session_subs[sid] :: table):send(decoded) end)
        elseif not sid then
            table.insert(browser_events, decoded)
        end
    end

    --- Pump the WebSocket: read and process one incoming message.
    --- Routes responses to the buffer and events to subscribers.
    --- @return table|nil decoded message (if it was a response/error)
    --- @return boolean ok false if WebSocket closed
    local function pump_one(): (table?, boolean)
        local msg, ok = ws_ch:receive()
        if not ok then
            closed = true
            return nil, false
        end

        if msg.type == "text" and msg.data then
            local decoded = proto:decode_message(msg.data)

            if decoded.type == "response" or decoded.type == "error" then
                return decoded, true
            elseif decoded.type == "event" then
                dispatch_event(decoded)
                return nil, true
            end
        end

        return nil, true
    end

    --- Send a CDP command and wait for the matching response.
    ---
    --- This method sends the command, then pumps incoming WebSocket messages
    --- until the matching response (by ID) arrives or the timeout expires.
    --- Events received while waiting are dispatched to their subscribers.
    --- Non-matching responses are buffered.
    ---
    --- @param method string CDP method (e.g. "Browser.getVersion")
    --- @param params table|nil Command parameters
    --- @param session_id string|nil Target session ID
    --- @param timeout_str string|nil Timeout override
    --- @return table|nil result CDP response result
    --- @return string|nil error
    function self:send(method: string, params: table?, session_id: string?, timeout_str: string?): (table?, string?)
        if closed then
            return nil, "CDP connection is closed"
        end

        local encoded, id = proto:encode_command(method, params, session_id)

        -- Send command over WebSocket
        local ok, send_err = ws:send(encoded)
        if send_err then
            return nil, "CDP send failed: " .. tostring(send_err)
        end

        -- Check if response was already buffered (from a previous pump cycle)
        if buffered_responses[id] then
            local resp = buffered_responses[id]
            buffered_responses[id] = nil
            if resp.type == "error" then
                return nil, "CDP error (" .. tostring(resp.error.code) .. "): " .. tostring(resp.error.message)
            end
            return resp.result :: table, nil
        end

        -- Pump messages until we get our response or timeout
        local t = timeout_str or default_timeout
        local timeout_ch = time.after(t)

        while true do
            local r = channel.select {
                ws_ch:case_receive(),
                timeout_ch:case_receive(),
            }

            if r.channel == timeout_ch then
                return nil, "CDP timeout: " .. method .. " did not respond within " .. t
            end

            -- WebSocket closed
            if not r.ok then
                closed = true
                return nil, "CDP connection closed while waiting for " .. method
            end

            local msg = r.value
            if msg.type == "text" and msg.data then
                local decoded = proto:decode_message(msg.data)

                if (decoded.type == "response" or decoded.type == "error") and decoded.id == id then
                    -- This is our response
                    if decoded.type == "error" then
                        local cdp_err = decoded.error
                        return nil, "CDP error (" .. tostring(cdp_err.code) .. "): " .. tostring(cdp_err.message)
                    end
                    return decoded.result :: table, nil
                elseif decoded.type == "response" or decoded.type == "error" then
                    -- Response for a different command, buffer it
                    buffered_responses[decoded.id] = decoded
                elseif decoded.type == "event" then
                    dispatch_event(decoded)
                end
            end
        end
    end

    --- Send a CDP command without waiting for a response (fire-and-forget).
    --- Useful for enabling domains or sending notifications.
    --- @param method string CDP method
    --- @param params table|nil Command parameters
    --- @param session_id string|nil Target session ID
    --- @return boolean ok
    --- @return string|nil error
    function self:send_no_reply(method: string, params: table?, session_id: string?): (boolean, string?)
        if closed then
            return false, "CDP connection is closed"
        end

        local encoded, _ = proto:encode_command(method, params, session_id)

        local ok, send_err = ws:send(encoded)
        if send_err then
            return false, "CDP send failed: " .. tostring(send_err)
        end

        return true, nil
    end

    --- Send a CDP command and return the command ID without waiting for the response.
    --- The caller is responsible for matching the response by ID (e.g. via pump_message).
    --- @param method string CDP method (e.g. "Page.navigate")
    --- @param params table|nil Command parameters
    --- @param session_id string|nil Target session ID
    --- @return integer|nil id Command ID for matching the response
    --- @return string|nil error
    function self:send_async(method: string, params: table?, session_id: string?): (integer?, string?)
        if closed then
            return nil, "CDP connection is closed"
        end

        local encoded, id = proto:encode_command(method, params, session_id)

        local ok, send_err = ws:send(encoded)
        if send_err then
            return nil, "CDP send failed: " .. tostring(send_err)
        end

        return id, nil
    end

    --- Subscribe to CDP events for a specific session.
    --- Returns a buffered channel that receives event messages.
    --- @param session_id string Session ID to subscribe to
    --- @param buffer_size integer|nil Channel buffer size (default 64)
    --- @return any ch Event channel
    function self:subscribe(session_id: string, buffer_size: integer?): any
        local buf = buffer_size or 64
        local ch = channel.new(buf)
        session_subs[session_id] = ch
        return ch
    end

    --- Unsubscribe from CDP events for a session.
    --- Closes and removes the event channel.
    --- @param session_id string Session ID to unsubscribe from
    function self:unsubscribe(session_id: string)
        local ch = session_subs[session_id]
        if ch then
            session_subs[session_id] = nil
            pcall(function() ch:close() end)
        end
    end

    --- Get and clear buffered browser-level events.
    --- @return {table} events Array of event messages
    function self:drain_browser_events(): {table}
        local evts = browser_events
        browser_events = {}
        return evts
    end

    --- Get the raw WebSocket channel for use in channel.select.
    --- Allows the manager to include the WebSocket in its select loop.
    --- When data arrives, call pump_message() with the received value.
    --- @return any ch WebSocket receive channel
    function self:ws_channel(): any
        return ws_ch
    end

    --- Process a WebSocket message already received from ws_channel().
    --- Dispatches events to subscribers. Returns decoded response/error
    --- for the caller to route (e.g. to a pending async command).
    --- @param msg table The WebSocket message from channel.select r.value
    --- @return table|nil response Decoded response or error table, nil for events
    function self:pump_message(msg: table): table?
        if msg.type == "text" and msg.data then
            local decoded = proto:decode_message(msg.data :: string)
            if decoded.type == "response" or decoded.type == "error" then
                return decoded
            elseif decoded.type == "event" then
                dispatch_event(decoded)
            end
        end
        return nil
    end

    --- Check if the connection is still alive.
    --- @return boolean
    function self:is_alive(): boolean
        return not closed
    end

    --- Get the discovered WebSocket URL (for diagnostics).
    --- @return string
    function self:ws_url(): string
        return ws_url
    end

    --- Get and clear all buffered responses.
    --- Used after blocking conn:send() calls to retrieve responses for
    --- async commands that arrived while send() was pumping the WebSocket.
    --- @return {table} responses Array of decoded response/error tables
    function self:drain_responses(): {table}
        local resps: {table} = {}
        for _, resp in pairs(buffered_responses) do
            table.insert(resps, resp)
        end
        buffered_responses = {}
        return resps
    end

    --- Close the CDP connection. Cleans up WebSocket and all channels.
    function self:close()
        if closed then
            return
        end
        closed = true

        -- Close WebSocket
        pcall(function() ws:close() end)

        -- Close all session subscriber channels
        for sid, ch in pairs(session_subs) do
            pcall(function() ch:close() end)
            session_subs[sid] = nil
        end
    end

    return self, nil
end

return connection
