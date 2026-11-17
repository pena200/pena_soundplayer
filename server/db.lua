PSP = PSP or {}

local RES = GetCurrentResourceName()
local MySQL = {}
local dbKind

local function promiseCall(fn)
    local p = promise.new()
    fn(function(r) p:resolve(r) end)
    return Citizen.Await(p)
end

local function waitStarted(res, fn)
    CreateThread(function()
        while GetResourceState(res) ~= 'started' do Wait(100) end
        pcall(function() exports[res]:awaitConnection() end)
        fn()
    end)
end

local function buildAdapter()
    local want = Config.database or 'auto'
    local order = want == 'auto' and { 'oxmysql', 'ghmattimysql', 'mysql-async' } or { want }

    for _, res in ipairs(order) do
        if res == 'oxmysql' and GetResourceState(res) == 'started' then
            local ex = exports.oxmysql
            return res, {
                query  = { await = function(sql, params) return promiseCall(function(cb) ex:query(sql, params or {}, cb) end) end },
                single = { await = function(sql, params) return promiseCall(function(cb) ex:single(sql, params or {}, cb) end) end },
                scalar = { await = function(sql, params) return promiseCall(function(cb) ex:scalar(sql, params or {}, cb) end) end },
                insert = { await = function(sql, params) return promiseCall(function(cb) ex:insert(sql, params or {}, cb) end) end },
                update = { await = function(sql, params) return promiseCall(function(cb) ex:update(sql, params or {}, cb) end) end },
                ready = function(fn) waitStarted(res, fn) end,
            }
        elseif res == 'ghmattimysql' and GetResourceState(res) == 'started' then
            local function exec(sql, params)
                return promiseCall(function(cb) exports.ghmattimysql:execute(sql, params or {}, cb) end)
            end
            return res, {
                query  = { await = exec },
                single = { await = function(sql, params) local r = exec(sql, params) return type(r) == 'table' and r[1] or nil end },
                scalar = { await = function(sql, params)
                    return promiseCall(function(cb) exports.ghmattimysql:scalar(sql, params or {}, cb) end)
                end },
                insert = { await = function(sql, params)
                    local r = exec(sql, params)
                    return type(r) == 'table' and (r.insertId or r.affectedRows) or r
                end },
                update = { await = function(sql, params)
                    local r = exec(sql, params)
                    return type(r) == 'table' and (r.affectedRows or 0) or (tonumber(r) or 0)
                end },
                ready = function(fn) CreateThread(fn) end,
            }
        elseif res == 'mysql-async' and GetResourceState(res) == 'started' then
            local function call(name, sql, params)
                local i, map = 0, {}
                sql = sql:gsub('%?', function()
                    i = i + 1
                    map['@p' .. i] = params and params[i]
                    return '@p' .. i
                end)
                local ex = exports['mysql-async']
                return promiseCall(function(cb) ex[name](ex, sql, map, cb) end)
            end
            return res, {
                query  = { await = function(sql, params) return call('mysql_fetch_all', sql, params) end },
                single = { await = function(sql, params) local r = call('mysql_fetch_all', sql, params) return type(r) == 'table' and r[1] or nil end },
                scalar = { await = function(sql, params) return call('mysql_fetch_scalar', sql, params) end },
                insert = { await = function(sql, params) return call('mysql_insert', sql, params) end },
                update = { await = function(sql, params) return call('mysql_execute', sql, params) end },
                ready = function(fn) CreateThread(fn) end,
            }
        end
    end
end

local adapter
dbKind, adapter = buildAdapter()
if adapter then
    MySQL = adapter
    print(('^2[%s]^7 database: %s'):format(RES, dbKind))
else
    print(('^1[%s] no database resource found (oxmysql, ghmattimysql or mysql-async). Playlists and the blocklist are off.^7'):format(RES))
    local none = { await = function() return nil end }
    MySQL = { query = none, single = none, scalar = none, insert = none, update = none, ready = function() end }
end

local dbReady = false

local Cd = {}
function PSP.onCooldown(src, key, ms)
    local k, t = src .. ':' .. key, GetGameTimer()
    if Cd[k] and t - Cd[k] < ms then return true end
    Cd[k] = t
    return false
end

AddEventHandler('playerDropped', function()
    local prefix = source .. ':'
    for k in pairs(Cd) do if k:sub(1, #prefix) == prefix then Cd[k] = nil end end
end)

function PSP.notify(src, text, kind)
    TriggerClientEvent('pena_soundplayer:notify', src, text, kind or 'inform')
end
local notify = PSP.notify

function PSP.loggedIn(src)
    src = tonumber(src)
    return src ~= nil and src > 0 and GetPlayerName(src) ~= nil
end

function PSP.dead(src)
    local ped = GetPlayerPed(src)
    return ped ~= nil and ped ~= 0 and GetEntityHealth(ped) < 100
end

function PSP.hasAce(src, group)
    if src == 0 then return true end
    if type(group) ~= 'string' or group == '' then return false end
    return IsPlayerAceAllowed(src, group)
end

function PSP.owner(src)
    return GetPlayerIdentifierByType(src, 'license') or GetPlayerIdentifierByType(src, 'license2')
end

local function cleanStr(s, max)
    s = tostring(s or ''):gsub('%c', ' ')
    s = s:gsub('^%s+', ''):gsub('%s+$', '')
    return s:sub(1, max)
end

local function cleanTrack(t)
    if type(t) ~= 'table' then return nil end
    local id = t.id
    if type(id) ~= 'string' or #id ~= 11 or not id:match('^[%w_%-]+$') then return nil end
    return {
        id = id, title = cleanStr(t.title, 150), channel = cleanStr(t.channel, 80),
        duration = math.max(0, math.floor(tonumber(t.duration) or 0)),
        thumb = ('https://i.ytimg.com/vi/%s/mqdefault.jpg'):format(id),
    }
end
PSP.cleanTrack = cleanTrack

local function cleanBands(b)
    if type(b) ~= 'table' then return nil end
    local out = {}
    for i = 1, 5 do
        local v = tonumber(b[i])
        if not v then return nil end
        out[i] = math.floor(math.max(-12.0, math.min(12.0, v)) * 2 + 0.5) / 2
    end
    return out
end
PSP.cleanBands = cleanBands

local ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
local function randomCode(len)
    local t = {}
    for i = 1, len do
        local n = math.random(1, #ALPHABET)
        t[i] = ALPHABET:sub(n, n)
    end
    return table.concat(t)
end

PSP.blockedIds = {}
for _, id in ipairs(Config.blocklist.ids or {}) do PSP.blockedIds[id] = true end

local words = {}
for _, w in ipairs(Config.blocklist.words or {}) do
    if type(w) == 'string' and #w > 0 then words[#words + 1] = w:lower() end
end

function PSP.isBlocked(track)
    if type(track) ~= 'table' then return false end
    if track.id and PSP.blockedIds[track.id] then return true end
    if #words > 0 then
        local hay = ((track.title or '') .. ' ' .. (track.channel or '')):lower()
        for _, w in ipairs(words) do
            if hay:find(w, 1, true) then return true end
        end
    end
    return false
end

function PSP.idFromRef(ref)
    if type(ref) ~= 'string' then return nil end
    ref = ref:gsub('%s', '')
    if #ref == 11 and ref:match('^[%w_%-]+$') then return ref end
    local id = ref:match('[%?&]v=([%w_%-]+)') or ref:match('youtu%.be/([%w_%-]+)')
        or ref:match('/shorts/([%w_%-]+)') or ref:match('/embed/([%w_%-]+)')
    if id and #id >= 11 then return id:sub(1, 11) end
    return nil
end

function PSP.filterResults(results)
    local out = {}
    for _, r in ipairs(results or {}) do
        if not PSP.isBlocked(r) then out[#out + 1] = r end
    end
    return out
end

CreateThread(function()
    MySQL.ready(function()
        MySQL.query.await([[CREATE TABLE IF NOT EXISTS `pena_sp_playlists` (
            `id` INT NOT NULL AUTO_INCREMENT, `owner` VARCHAR(80) NOT NULL, `name` VARCHAR(60) NOT NULL,
            `tracks` LONGTEXT NOT NULL, `share_code` VARCHAR(12) NULL,
            `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`), UNIQUE KEY `share_code` (`share_code`), KEY `owner` (`owner`))]])
        MySQL.query.await([[CREATE TABLE IF NOT EXISTS `pena_sp_eq_presets` (
            `id` INT NOT NULL AUTO_INCREMENT, `owner` VARCHAR(80) NOT NULL, `name` VARCHAR(40) NOT NULL,
            `bands` VARCHAR(255) NOT NULL, `share_code` VARCHAR(12) NULL,
            `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`), UNIQUE KEY `share_code` (`share_code`), KEY `owner` (`owner`))]])
        MySQL.query.await([[CREATE TABLE IF NOT EXISTS `pena_sp_blocklist` (
            `video_id` VARCHAR(16) NOT NULL, `title` VARCHAR(150) NULL, `added_by` VARCHAR(80) NULL,
            `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY (`video_id`))]])
        for _, row in ipairs(MySQL.query.await('SELECT video_id FROM pena_sp_blocklist') or {}) do
            PSP.blockedIds[row.video_id] = true
        end
        dbReady = true
    end)
end)

local function waitDb()
    local t = 0
    while not dbReady and t < 100 do Wait(100) t = t + 1 end
    return dbReady
end

local function decodeTracks(raw)
    local ok, t = pcall(json.decode, raw or '[]')
    return (ok and type(t) == 'table') and t or {}
end

local function snapshot(src)
    local owner = PSP.owner(src)
    local out = { playlists = {}, presets = {} }
    if not owner then return out end
    for _, r in ipairs(MySQL.query.await('SELECT id, name, tracks, share_code FROM pena_sp_playlists WHERE owner = ? ORDER BY id', { owner }) or {}) do
        out.playlists[#out.playlists + 1] = { id = r.id, name = r.name, tracks = decodeTracks(r.tracks), code = r.share_code }
    end
    for _, r in ipairs(MySQL.query.await('SELECT id, name, bands, share_code FROM pena_sp_eq_presets WHERE owner = ? ORDER BY id', { owner }) or {}) do
        local ok, bands = pcall(json.decode, r.bands)
        out.presets[#out.presets + 1] = { id = r.id, name = r.name, bands = (ok and cleanBands(bands)) or { 0, 0, 0, 0, 0 }, code = r.share_code }
    end
    return out
end

local function reply(src, extra)
    local r = extra or {}
    r.ok = true
    r.data = snapshot(src)
    return r
end

local function fail(msg) return { ok = false, error = msg } end

local function guard(src, key)
    if not PSP.loggedIn(src) or not PSP.owner(src) then return locale('err.noChar') end
    if not waitDb() then return locale('err.dbNotReady') end
    if PSP.onCooldown(src, 'db:' .. key, 250) then return locale('err.slowDown') end
    return nil
end

local function getOwned(owner, table_, id)
    id = math.tointeger(id)
    if not id then return nil end
    return MySQL.single.await(('SELECT * FROM %s WHERE id = ? AND owner = ?'):format(table_), { id, owner })
end

local function ensureCode(table_, row)
    if row.share_code and row.share_code ~= '' then return row.share_code end
    for _ = 1, 20 do
        local code = randomCode(Config.playlists.shareCodeLength or 6)
        local taken = MySQL.scalar.await(('SELECT 1 FROM %s WHERE share_code = ?'):format(table_), { code })
        if not taken then
            MySQL.update.await(('UPDATE %s SET share_code = ? WHERE id = ?'):format(table_), { code, row.id })
            return code
        end
    end
    return nil
end

Callback.register('pena_soundplayer:data', function(src)
    if not PSP.loggedIn(src) then return fail(locale('err.noChar')) end
    if not waitDb() then return fail(locale('err.dbNotReady')) end
    return reply(src)
end)

Callback.register('pena_soundplayer:pl:create', function(src, name)
    local g = guard(src, 'plc') if g then return fail(g) end
    name = cleanStr(name, 40)
    if #name < 1 then return fail(locale('pl.needName')) end
    local owner = PSP.owner(src)
    local count = MySQL.scalar.await('SELECT COUNT(*) FROM pena_sp_playlists WHERE owner = ?', { owner }) or 0
    if count >= Config.playlists.maxPerPlayer then return fail(locale('pl.limit')) end
    local id = MySQL.insert.await('INSERT INTO pena_sp_playlists (owner, name, tracks) VALUES (?, ?, ?)', { owner, name, '[]' })
    return reply(src, { id = id })
end)

Callback.register('pena_soundplayer:pl:delete', function(src, id)
    local g = guard(src, 'pld') if g then return fail(g) end
    MySQL.update.await('DELETE FROM pena_sp_playlists WHERE id = ? AND owner = ?', { math.tointeger(id) or 0, PSP.owner(src) })
    return reply(src)
end)

Callback.register('pena_soundplayer:pl:rename', function(src, id, name)
    local g = guard(src, 'plr') if g then return fail(g) end
    name = cleanStr(name, 40)
    if #name < 1 then return fail(locale('pl.needName')) end
    MySQL.update.await('UPDATE pena_sp_playlists SET name = ? WHERE id = ? AND owner = ?', { name, math.tointeger(id) or 0, PSP.owner(src) })
    return reply(src)
end)

Callback.register('pena_soundplayer:pl:add', function(src, id, track)
    local g = guard(src, 'pla') if g then return fail(g) end
    local t = cleanTrack(track)
    if not t then return fail(locale('pl.cannotSave')) end
    if PSP.isBlocked(t) then return fail(locale('song.blocked')) end
    local row = getOwned(PSP.owner(src), 'pena_sp_playlists', id)
    if not row then return fail(locale('pl.notFound')) end
    local tracks = decodeTracks(row.tracks)
    for _, x in ipairs(tracks) do if x.id == t.id then return fail(locale('pl.already')) end end
    if #tracks >= Config.playlists.maxTracks then return fail(locale('pl.full')) end
    tracks[#tracks + 1] = t
    MySQL.update.await('UPDATE pena_sp_playlists SET tracks = ? WHERE id = ?', { json.encode(tracks), row.id })
    return reply(src)
end)

Callback.register('pena_soundplayer:pl:remove', function(src, id, index)
    local g = guard(src, 'plx') if g then return fail(g) end
    local row = getOwned(PSP.owner(src), 'pena_sp_playlists', id)
    if not row then return fail(locale('pl.notFound')) end
    local tracks = decodeTracks(row.tracks)
    index = math.tointeger(index)
    if index and tracks[index] then table.remove(tracks, index) end
    MySQL.update.await('UPDATE pena_sp_playlists SET tracks = ? WHERE id = ?', { json.encode(tracks), row.id })
    return reply(src)
end)

Callback.register('pena_soundplayer:pl:share', function(src, id)
    local g = guard(src, 'pls') if g then return fail(g) end
    local row = getOwned(PSP.owner(src), 'pena_sp_playlists', id)
    if not row then return fail(locale('pl.notFound')) end
    local code = ensureCode('pena_sp_playlists', row)
    if not code then return fail(locale('share.failed')) end
    return reply(src, { code = code })
end)

Callback.register('pena_soundplayer:pl:import', function(src, code)
    local g = guard(src, 'pli') if g then return fail(g) end
    code = cleanStr(code, 12):upper()
    if #code < 4 then return fail(locale('share.enter')) end
    local owner = PSP.owner(src)
    local row = MySQL.single.await('SELECT name, tracks FROM pena_sp_playlists WHERE share_code = ?', { code })
    if not row then return fail(locale('pl.noCode')) end
    local count = MySQL.scalar.await('SELECT COUNT(*) FROM pena_sp_playlists WHERE owner = ?', { owner }) or 0
    if count >= Config.playlists.maxPerPlayer then return fail(locale('pl.limit')) end
    local tracks = {}
    for _, t in ipairs(decodeTracks(row.tracks)) do
        local c = cleanTrack(t)
        if c and not PSP.isBlocked(c) then tracks[#tracks + 1] = c end
    end
    MySQL.insert.await('INSERT INTO pena_sp_playlists (owner, name, tracks) VALUES (?, ?, ?)', { owner, row.name, json.encode(tracks) })
    return reply(src, { name = row.name })
end)

function PSP.getPlaylist(src, id)
    if not waitDb() then return nil end
    local row = getOwned(PSP.owner(src), 'pena_sp_playlists', id)
    if not row then return nil end
    return { id = row.id, name = row.name, tracks = decodeTracks(row.tracks) }
end

Callback.register('pena_soundplayer:eq:save', function(src, name, bands)
    local g = guard(src, 'eqs') if g then return fail(g) end
    name = cleanStr(name, 30)
    local b = cleanBands(bands)
    if #name < 1 then return fail(locale('eq.needName')) end
    if not b then return fail(locale('eq.invalid')) end
    local owner = PSP.owner(src)
    local count = MySQL.scalar.await('SELECT COUNT(*) FROM pena_sp_eq_presets WHERE owner = ?', { owner }) or 0
    if count >= Config.playlists.maxEqPresets then return fail(locale('eq.limit')) end
    MySQL.insert.await('INSERT INTO pena_sp_eq_presets (owner, name, bands) VALUES (?, ?, ?)', { owner, name, json.encode(b) })
    return reply(src)
end)

Callback.register('pena_soundplayer:eq:delete', function(src, id)
    local g = guard(src, 'eqd') if g then return fail(g) end
    MySQL.update.await('DELETE FROM pena_sp_eq_presets WHERE id = ? AND owner = ?', { math.tointeger(id) or 0, PSP.owner(src) })
    return reply(src)
end)

Callback.register('pena_soundplayer:eq:share', function(src, id)
    local g = guard(src, 'eqh') if g then return fail(g) end
    local row = getOwned(PSP.owner(src), 'pena_sp_eq_presets', id)
    if not row then return fail(locale('eq.notFound')) end
    local code = ensureCode('pena_sp_eq_presets', row)
    if not code then return fail(locale('share.failed')) end
    return reply(src, { code = code })
end)

Callback.register('pena_soundplayer:eq:import', function(src, code)
    local g = guard(src, 'eqi') if g then return fail(g) end
    code = cleanStr(code, 12):upper()
    if #code < 4 then return fail(locale('share.enter')) end
    local owner = PSP.owner(src)
    local row = MySQL.single.await('SELECT name, bands FROM pena_sp_eq_presets WHERE share_code = ?', { code })
    if not row then return fail(locale('eq.noCode')) end
    local count = MySQL.scalar.await('SELECT COUNT(*) FROM pena_sp_eq_presets WHERE owner = ?', { owner }) or 0
    if count >= Config.playlists.maxEqPresets then return fail(locale('eq.limit')) end
    MySQL.insert.await('INSERT INTO pena_sp_eq_presets (owner, name, bands) VALUES (?, ?, ?)', { owner, row.name, row.bands })
    return reply(src, { name = row.name })
end)

local function say(src, text)
    if src and src > 0 then notify(src, text, 'inform') else print(('[%s] %s'):format(RES, text)) end
end

local function blockCmd(name, fn)
    RegisterCommand(name, function(src, args)
        if not PSP.hasAce(src, Config.blocklist.adminGroup or 'group.admin') then
            return notify(src, locale('err.noPermission'), 'error')
        end
        fn(src, args[1])
    end, false)
end

blockCmd('songblock', function(src, ref)
    local id = PSP.idFromRef(ref)
    if not id then return say(src, locale('cmd.badRef')) end
    waitDb()
    PSP.blockedIds[id] = true
    MySQL.query.await('INSERT IGNORE INTO pena_sp_blocklist (video_id, added_by) VALUES (?, ?)',
        { id, src and src > 0 and (PSP.owner(src) or tostring(src)) or 'console' })
    if PSP.purgeTrack then PSP.purgeTrack(id) end
    say(src, locale('cmd.blocked', id))
end)

blockCmd('songunblock', function(src, ref)
    local id = PSP.idFromRef(ref)
    if not id then return say(src, locale('cmd.badRef')) end
    waitDb()
    PSP.blockedIds[id] = nil
    MySQL.query.await('DELETE FROM pena_sp_blocklist WHERE video_id = ?', { id })
    say(src, locale('cmd.unblocked', id))
end)

blockCmd('songblocklist', function(src)
    local ids = {}
    for id in pairs(PSP.blockedIds) do ids[#ids + 1] = id end
    table.sort(ids)
    say(src, #ids == 0 and locale('cmd.none') or locale('cmd.list', table.concat(ids, ', ')))
end)

function PSP.suggestAdminCommands(src)
    if not PSP.hasAce(src, Config.blocklist.adminGroup or 'group.admin') then return end
    local ref = { { name = 'ref', help = locale('cmd.refHelp') } }
    TriggerClientEvent('chat:addSuggestion', src, '/songblock', locale('cmd.block'), ref)
    TriggerClientEvent('chat:addSuggestion', src, '/songunblock', locale('cmd.unblock'), ref)
    TriggerClientEvent('chat:addSuggestion', src, '/songblocklist', locale('cmd.blocklist'))
end
