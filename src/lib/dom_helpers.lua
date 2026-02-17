--- DOM Helpers
---
--- JavaScript snippets and utilities for DOM element resolution,
--- bounding box calculation, and common element queries.
--- Used by tab.lua for extraction and interaction methods.

local dom_helpers = {}

--- Get element bounding box center coordinates after scrolling into view.
--- Returns {x, y, width, height} or null if not found.
--- @param selector string CSS selector
--- @return string js
function dom_helpers.js_bounding_box(selector: string): string
    return string.format([[
        (function() {
            var el = document.querySelector(%q);
            if (!el) return null;
            el.scrollIntoView({block: 'center', inline: 'center'});
            var rect = el.getBoundingClientRect();
            return {
                x: rect.x + rect.width / 2,
                y: rect.y + rect.height / 2,
                width: rect.width,
                height: rect.height
            };
        })()
    ]], selector)
end

--- Get trimmed text content of first matching element.
--- @param selector string CSS selector
--- @return string js
function dom_helpers.js_text(selector: string): string
    return string.format(
        "(() => { var el = document.querySelector(%q); return el ? (el.textContent || '').trim() : null; })()",
        selector
    )
end

--- Get trimmed text content of all matching elements as an array.
--- @param selector string CSS selector
--- @return string js
function dom_helpers.js_text_all(selector: string): string
    return string.format(
        "Array.from(document.querySelectorAll(%q)).map(el => (el.textContent || '').trim())",
        selector
    )
end

--- Get attribute value of first matching element.
--- @param selector string CSS selector
--- @param attr string Attribute name
--- @return string js
function dom_helpers.js_attribute(selector: string, attr: string): string
    return string.format(
        "(() => { var el = document.querySelector(%q); return el ? el.getAttribute(%q) : null; })()",
        selector, attr
    )
end

--- Get attribute value from all matching elements as an array.
--- @param selector string CSS selector
--- @param attr string Attribute name
--- @return string js
function dom_helpers.js_attribute_all(selector: string, attr: string): string
    return string.format(
        "Array.from(document.querySelectorAll(%q)).map(el => el.getAttribute(%q))",
        selector, attr
    )
end

--- Get the value of an input/select/textarea element.
--- @param selector string CSS selector
--- @return string js
function dom_helpers.js_value(selector: string): string
    return string.format(
        "(() => { var el = document.querySelector(%q); return el ? el.value : null; })()",
        selector
    )
end

--- Check if element is visible (exists, displayed, has dimensions).
--- @param selector string CSS selector
--- @return string js
function dom_helpers.js_is_visible(selector: string): string
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

--- Check if element exists in the DOM.
--- @param selector string CSS selector
--- @return string js
function dom_helpers.js_exists(selector: string): string
    return string.format("document.querySelector(%q) !== null", selector)
end

--- Check if element is enabled (not disabled).
--- @param selector string CSS selector
--- @return string js
function dom_helpers.js_is_enabled(selector: string): string
    return string.format(
        "(() => { var el = document.querySelector(%q); return el ? !el.disabled : false; })()",
        selector
    )
end

--- Check if checkbox/radio is checked.
--- @param selector string CSS selector
--- @return string js
function dom_helpers.js_is_checked(selector: string): string
    return string.format(
        "(() => { var el = document.querySelector(%q); return el ? !!el.checked : false; })()",
        selector
    )
end

--- Count elements matching selector.
--- @param selector string CSS selector
--- @return string js
function dom_helpers.js_count(selector: string): string
    return string.format("document.querySelectorAll(%q).length", selector)
end

--- Focus an element.
--- @param selector string CSS selector
--- @return string js
function dom_helpers.js_focus(selector: string): string
    return string.format(
        "(() => { var el = document.querySelector(%q); if (el) { el.focus(); return true; } return false; })()",
        selector
    )
end

--- Clear an input element's value and dispatch input event.
--- @param selector string CSS selector
--- @return string js
function dom_helpers.js_clear(selector: string): string
    return string.format([[
        (function() {
            var el = document.querySelector(%q);
            if (!el) return false;
            el.value = '';
            el.dispatchEvent(new Event('input', {bubbles: true}));
            el.dispatchEvent(new Event('change', {bubbles: true}));
            return true;
        })()
    ]], selector)
end

--- Select a dropdown option by value string.
--- @param selector string CSS selector
--- @param value string Option value
--- @return string js
function dom_helpers.js_select_by_value(selector: string, value: string): string
    return string.format([[
        (function() {
            var s = document.querySelector(%q);
            if (!s) return false;
            s.value = %q;
            s.dispatchEvent(new Event('change', {bubbles: true}));
            return true;
        })()
    ]], selector, value)
end

--- Select a dropdown option by index.
--- @param selector string CSS selector
--- @param index integer 0-based index
--- @return string js
function dom_helpers.js_select_by_index(selector: string, index: integer): string
    return string.format([[
        (function() {
            var s = document.querySelector(%q);
            if (!s) return false;
            s.selectedIndex = %d;
            s.dispatchEvent(new Event('change', {bubbles: true}));
            return true;
        })()
    ]], selector, index)
end

--- Select a dropdown option by visible text.
--- @param selector string CSS selector
--- @param text string Option text
--- @return string js
function dom_helpers.js_select_by_text(selector: string, text: string): string
    return string.format([[
        (function() {
            var s = document.querySelector(%q);
            if (!s) return false;
            var opt = Array.from(s.options).find(function(o) { return o.text === %q; });
            if (!opt) return false;
            s.value = opt.value;
            s.dispatchEvent(new Event('change', {bubbles: true}));
            return true;
        })()
    ]], selector, text)
end

--- Check a checkbox (only if not already checked).
--- @param selector string CSS selector
--- @return string js
function dom_helpers.js_check(selector: string): string
    return string.format([[
        (function() {
            var el = document.querySelector(%q);
            if (!el) return false;
            if (!el.checked) { el.click(); }
            return true;
        })()
    ]], selector)
end

--- Uncheck a checkbox (only if currently checked).
--- @param selector string CSS selector
--- @return string js
function dom_helpers.js_uncheck(selector: string): string
    return string.format([[
        (function() {
            var el = document.querySelector(%q);
            if (!el) return false;
            if (el.checked) { el.click(); }
            return true;
        })()
    ]], selector)
end

--- Key definitions for special keys.
--- Maps key name → { key, code, keyCode } for CDP Input.dispatchKeyEvent.
dom_helpers.KEY_MAP = {
    Enter     = { key = "Enter",     code = "Enter",     keyCode = 13 },
    Tab       = { key = "Tab",       code = "Tab",       keyCode = 9 },
    Escape    = { key = "Escape",    code = "Escape",    keyCode = 27 },
    Backspace = { key = "Backspace", code = "Backspace", keyCode = 8 },
    Delete    = { key = "Delete",    code = "Delete",    keyCode = 46 },
    ArrowUp   = { key = "ArrowUp",   code = "ArrowUp",   keyCode = 38 },
    ArrowDown = { key = "ArrowDown", code = "ArrowDown", keyCode = 40 },
    ArrowLeft = { key = "ArrowLeft", code = "ArrowLeft", keyCode = 37 },
    ArrowRight= { key = "ArrowRight",code = "ArrowRight",keyCode = 39 },
    Home      = { key = "Home",      code = "Home",      keyCode = 36 },
    End       = { key = "End",       code = "End",       keyCode = 35 },
    PageUp    = { key = "PageUp",    code = "PageUp",    keyCode = 33 },
    PageDown  = { key = "PageDown",  code = "PageDown",  keyCode = 34 },
    Space     = { key = " ",         code = "Space",     keyCode = 32 },
}

return dom_helpers
