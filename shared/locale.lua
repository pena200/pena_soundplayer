local RES = GetCurrentResourceName()

local function flatten(prefix, node, out)
    for k, v in pairs(node) do
        local key = prefix and (prefix .. '.' .. k) or k
        if type(v) == 'table' then flatten(key, v, out) else out[key] = tostring(v) end
    end
    return out
end

local function read(lang)
    local raw = LoadResourceFile(RES, ('locales/%s.json'):format(lang))
    if not raw then return nil end
    local ok, data = pcall(json.decode, raw)
    if not ok or type(data) ~= 'table' then
        print(('^1[%s] locales/%s.json is not valid JSON^7'):format(RES, lang))
        return nil
    end
    return flatten(nil, data, {})
end

local lang = tostring(Config.locale or 'en')
if not lang:match('^[%w_%-]+$') then lang = 'en' end

local fallback = read('en') or {}
local active = lang == 'en' and fallback or read(lang) or fallback

function locale(key, ...)
    local text = active[key] or fallback[key]
    if not text then return key end
    if select('#', ...) > 0 then
        local ok, formatted = pcall(string.format, text, ...)
        return ok and formatted or text
    end
    return text
end
