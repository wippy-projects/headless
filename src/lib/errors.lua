--- Error Mapping
---
--- Centralizes CDP error → Wippy error type mapping.
--- Provides factory functions for common headless browser error scenarios.

local error_map = {}

--- Error type constants used across the headless module.
error_map.CDP_CONNECTION_FAILED = "CDP_CONNECTION_FAILED"
error_map.CDP_DISCONNECTED = "CDP_DISCONNECTED"
error_map.CDP_ERROR = "CDP_ERROR"
error_map.NAVIGATION_FAILED = "NAVIGATION_FAILED"
error_map.NAVIGATION_TIMEOUT = "NAVIGATION_TIMEOUT"
error_map.ELEMENT_NOT_FOUND = "ELEMENT_NOT_FOUND"
error_map.ELEMENT_NOT_VISIBLE = "ELEMENT_NOT_VISIBLE"
error_map.ELEMENT_NOT_INTERACTABLE = "ELEMENT_NOT_INTERACTABLE"
error_map.EVAL_ERROR = "EVAL_ERROR"
error_map.DOWNLOAD_TIMEOUT = "DOWNLOAD_TIMEOUT"
error_map.DOWNLOAD_FAILED = "DOWNLOAD_FAILED"
error_map.MAX_TABS_REACHED = "MAX_TABS_REACHED"
error_map.TAB_CLOSED = "TAB_CLOSED"
error_map.TIMEOUT = "TIMEOUT"
error_map.INVALID = "INVALID"

--- Map a raw CDP error to a descriptive Wippy error string.
--- Analyzes the CDP error code and message to choose the most specific type.
--- @param cdp_code integer|nil CDP error code
--- @param cdp_message string CDP error message
--- @param context string|nil Additional context (e.g. the CDP method that failed)
--- @return string error Formatted error string "TYPE: description"
function error_map.from_cdp(cdp_code: integer?, cdp_message: string, context: string?): string
    local msg = cdp_message or "Unknown CDP error"

    -- Target / tab lifecycle errors
    if msg:find("No target with given id") or msg:find("Target closed") then
        return error_map.TAB_CLOSED .. ": Tab was closed or crashed"
    end
    if msg:find("Cannot find context") or msg:find("Execution context was destroyed") then
        return error_map.TAB_CLOSED .. ": Browser context destroyed"
    end
    if msg:find("Session with given id not found") then
        return error_map.TAB_CLOSED .. ": Session no longer exists"
    end

    -- Navigation errors
    if msg:find("net::ERR_") then
        return error_map.NAVIGATION_FAILED .. ": " .. msg
    end
    if msg:find("Cannot navigate") then
        return error_map.NAVIGATION_FAILED .. ": " .. msg
    end

    -- DOM / element errors
    if msg:find("Could not find node") or msg:find("No node with given id") then
        return error_map.ELEMENT_NOT_FOUND .. ": " .. msg
    end
    if msg:find("Node is not visible") then
        return error_map.ELEMENT_NOT_VISIBLE .. ": " .. msg
    end
    if msg:find("Node is not an element") or msg:find("not interactable") then
        return error_map.ELEMENT_NOT_INTERACTABLE .. ": " .. msg
    end

    -- JavaScript errors
    if msg:find("TypeError") or msg:find("ReferenceError") or msg:find("SyntaxError") then
        return error_map.EVAL_ERROR .. ": " .. msg
    end

    -- Generic CDP error with context
    if context then
        return error_map.CDP_ERROR .. " (" .. context .. "): " .. msg
    end
    return error_map.CDP_ERROR .. ": " .. msg
end

--- Create a connection lost error.
--- @return string error
function error_map.connection_lost(): string
    return error_map.CDP_DISCONNECTED .. ": Chrome connection lost during operation"
end

--- Create a max tabs reached error.
--- @param limit integer Max tab count
--- @param timeout string Timeout that expired
--- @return string error
function error_map.max_tabs(limit: integer, timeout: string): string
    return error_map.MAX_TABS_REACHED
        .. ": Max tabs (" .. tostring(limit) .. ") reached, no tab available within " .. timeout
end

--- Create a download timeout error.
--- @param timeout string Timeout value
--- @return string error
function error_map.download_timeout(timeout: string): string
    return error_map.DOWNLOAD_TIMEOUT .. ": No download completed within " .. timeout
end

return error_map
