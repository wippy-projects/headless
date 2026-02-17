--- CDP JSON-RPC Protocol
---
--- Handles encoding CDP commands and decoding responses/events
--- following the Chrome DevTools Protocol message format.
---
--- Command format (client -> Chrome):
---   {"id": N, "method": "Domain.method", "params": {...}}
---   {"id": N, "method": "Domain.method", "params": {...}, "sessionId": "..."}
---
--- Response format (Chrome -> client):
---   {"id": N, "result": {...}}
---   {"id": N, "error": {"code": N, "message": "..."}}
---
--- Event format (Chrome -> client, no "id"):
---   {"method": "Domain.event", "params": {...}, "sessionId": "..."}

local json = require("json")

local protocol = {}

--- Create a new CDP protocol instance with its own ID counter.
--- @return table protocol instance
function protocol.new()
    local self = {
        _next_id = 0,
    }

    --- Encode a CDP command into a JSON string.
    --- @param method string CDP method (e.g. "Browser.getVersion")
    --- @param params table|nil Parameters for the command
    --- @param session_id string|nil Target session ID (nil for browser-level commands)
    --- @return string json_str Encoded JSON message
    --- @return integer id Command ID for response correlation
    function self:encode_command(method: string, params: table?, session_id: string?): (string, integer)
        self._next_id = self._next_id + 1
        local id = self._next_id

        local msg: {[string]: any} = {
            id = id,
            method = method,
        }

        if params and next(params) then
            msg.params = params
        end

        if session_id then
            msg.sessionId = session_id
        end

        return json.encode(msg), id
    end

    --- Decode a raw JSON message from Chrome into a structured table.
    --- @param raw string JSON string received from WebSocket
    --- @return table decoded message with `type` field:
    ---   {type="response", id=N, result={...}}
    ---   {type="error", id=N, error={code=N, message="..."}}
    ---   {type="event", method="...", params={...}, session_id="..."|nil}
    ---   {type="unknown", raw=...} for unrecognized messages
    function self:decode_message(raw: string): table
        local ok, msg = pcall(json.decode, raw)
        if not ok or type(msg) ~= "table" then
            return { type = "unknown", raw = raw }
        end

        -- Response or error (has "id" field)
        if msg.id ~= nil then
            if msg.error then
                return {
                    type = "error",
                    id = msg.id,
                    error = {
                        code = msg.error.code,
                        message = msg.error.message or "Unknown CDP error",
                        data = msg.error.data,
                    },
                }
            end

            return {
                type = "response",
                id = msg.id,
                result = msg.result or {},
            }
        end

        -- Event (has "method" but no "id")
        if msg.method then
            return {
                type = "event",
                method = msg.method,
                params = msg.params or {},
                session_id = msg.sessionId,
            }
        end

        return { type = "unknown", raw = raw }
    end

    --- Get current ID counter value (for diagnostics).
    --- @return integer
    function self:last_id(): integer
        return self._next_id
    end

    return self
end

return protocol
