Config = {}

-- Database used for playlists, EQ presets and the song blocklist.
-- 'auto' picks the first one that is running: oxmysql, ghmattimysql or mysql-async.
-- Tables are created automatically on start, no SQL import needed.
Config.database = 'auto'

-- Language file from locales/ (en, fi). Missing keys fall back to English.
Config.locale = 'en'

-- Stop players from controlling the radio while they are dead.
Config.blockWhenDead = true

-- UI theme: 'apple', 'spotify' or 'ytmusic'.
Config.theme = 'apple'

-- Show the three theme buttons in the UI so players can switch themselves
-- (their choice is remembered on their PC).
Config.themeSwitcher = true

-- Override the accent color of the UI, for example '#00e5ff'. nil keeps the theme color.
Config.accent = nil

-- Command that toggles streamer mode for a player (mutes the sound player and its UI sounds).
Config.streamerCommand = 'streamermode'

-- Turn off the default GTA radio in vehicles so it does not play over this resource.
Config.disableDefaultRadio = true

-- Menu click sounds. { sound name, sound set }. Set enabled = false to silence them.
Config.sounds = {
    enabled = true,
    open    = { 'SELECT',         'HUD_FRONTEND_DEFAULT_SOUNDSET' },
    close   = { 'BACK',           'HUD_FRONTEND_DEFAULT_SOUNDSET' },
    select  = { 'SELECT',         'HUD_FRONTEND_DEFAULT_SOUNDSET' },
    queue   = { 'YES',            'HUD_FRONTEND_DEFAULT_SOUNDSET' },
    hover   = { 'NAV_UP_DOWN',    'HUD_FRONTEND_DEFAULT_SOUNDSET' },
    tick    = { 'NAV_LEFT_RIGHT', 'HUD_FRONTEND_DEFAULT_SOUNDSET' },
    toggle  = { 'TOGGLE_ON',      'HUD_FRONTEND_DEFAULT_SOUNDSET' },
    next    = { 'NAV_LEFT_RIGHT', 'HUD_FRONTEND_DEFAULT_SOUNDSET' },
    stop    = { 'CANCEL',         'HUD_FRONTEND_DEFAULT_SOUNDSET' },
    error   = { 'ERROR',          'HUD_FRONTEND_DEFAULT_SOUNDSET' },
}

-- Most songs a single radio or boombox can have in its queue.
Config.maxQueue           = 15
-- Minimum time between two searches from the same player (ms).
Config.searchCooldown     = 700
-- Searches the server will run at the same time before it answers "busy".
Config.maxPendingSearches = 6
-- Minimum time between two play requests from the same player (ms).
Config.playCooldown       = 1500
-- Starting volume of a new radio or boombox (0.0 to 1.0).
Config.defaultVolume      = 0.6
-- How long the server waits for the player to finish loading a song before it starts anyway (ms).
Config.loadTimeout        = 8000

-- How the audio reaches the player.
-- 'chunks': sent through the game connection in small pieces. Works everywhere, no setup.
-- 'direct': the player's browser downloads the file over HTTP. Needs "standalonePort" set in
--           backend.json and Config.baseUrl below pointing to it.
Config.audioMode = 'chunks'

-- Only for audioMode = 'direct'. Public address of the audio server, for example
-- 'http://123.123.123.123:30125/audio/' (the port is "standalonePort" in backend.json).
Config.baseUrl = nil

-- 3D sound settings. Only change these if you know what you are doing.
Config.spatial = {
    -- How often the sound is recalculated while a player is near it (ms). Lower is smoother but costs more.
    tick = 100,

    -- How the volume drops with distance: 'exponential', 'linear' or 'sqrt'.
    falloff  = { car = 'exponential', boombox = 'exponential' },
    -- Steepness of the 'exponential' curve. Higher drops faster.
    exponent = 2.0,

    -- Far away sound gets muffled. minLowpass is the lowest frequency (Hz) at the edge of the range.
    airAbsorption = { minLowpass = 3500, curve = 1.2 },

    -- Left/right panning and how muffled sound is when the source is behind you.
    pan = { strength = 0.85, fullAtDistance = 4.0, rearLowpass = 9000, rearGainLoss = 0.10 },

    -- When the player and the sound are in different interiors or rooms.
    interior = {
        enabled = true,
        gain = 0.55, lowpass = 2600,          -- different interior
        roomGain = 0.70, roomLowpass = 4200,  -- same interior, different room
    },

    -- Walls and objects between the sound and the player make it quieter and more muffled.
    occlusion = {
        enabled = true,
        gain = 0.40, lowpass = 1100,  -- strength when fully blocked
        interval = 150,               -- how often to check (ms)
        minDistance = 2.0,            -- closer than this nothing blocks the sound
        spread = 0.8,                 -- width of the 3 check lines (meters)
        targetHeight = 0.6,           -- height of the check lines above the source (meters)
        smoothing = 0.35,             -- how fast the change fades in (0 to 1)
        flags = 1,                    -- raycast flags (1 = map only)
    },

    -- How much music leaks out of a car, and how muffled it is for a player inside one.
    vehicle = {
        openGain = 1.0, openLowpass = 18000,
        doorWeight = 0.28,      -- each open door adds this much "open"
        windowWeight = 0.20,    -- each broken or rolled down window adds this much
        roofDownWeight = 0.70,  -- convertible with the roof down
        -- Vehicle classes that are always open (8 = motorcycles, 13 = cycles, 14 = boats, 15 = helis, 16 = planes).
        openClasses = { [8] = 1.0, [13] = 1.0, [14] = 0.8, [15] = 0.4, [16] = 0.3 },
        listenerGain = 0.60, listenerLowpass = 3500,  -- what a player inside a closed car hears from outside
    },
}

-- Car radio, opened with a key while sitting in a vehicle.
Config.carRadio = {
    enabled            = true,
    key                = 'Q',      -- default key, players can rebind it in the GTA key settings
    allowedSeats       = 'front',  -- 'driver', 'front' (driver + front passenger) or 'any'
    distance           = 18.0,     -- how far the music can be heard (meters)
    baseVolume         = 0.7,      -- master volume of car radios (0.0 to 1.0)
    outsideMultiplier  = 0.35,     -- volume factor for people outside a closed car
    outsideLowpass     = 1000,     -- muffling (Hz) for people outside a closed car
    stopWhenEmptyAfter = 25,       -- stop the music after the car has been empty this many seconds (0 = never)

    -- If this list has any model in it, ONLY these vehicles get a radio. Example: { 'adder', 'zentorno' }
    allowedModels = {},
    -- Vehicle models that never get a radio.
    blockedModels = {
        'bmx', 'cruiser', 'fixter', 'scorcher', 'tribike', 'tribike2', 'tribike3',
    },
    -- Vehicle types that never get a radio.
    blockedTypes = { 'bicycle', 'trailer', 'train' },
}

-- Placeable boombox.
Config.boombox = {
    enabled         = true,
    command         = 'boombox',      -- command that places one ('' = no command, use the export instead)
    commandGroup    = 'group.admin',  -- ace group allowed to use the command ('' = everyone)
    model           = 'prop_boombox_01',
    distance        = 28.0,           -- how far the music can be heard (meters)
    baseVolume      = 0.8,            -- master volume of boomboxes (0.0 to 1.0)
    controlDistance = 2.5,            -- how close you must stand to use or pick it up (meters)
    maxPerPlayer    = 1,              -- boomboxes one player can have placed at once
}
-- From another script (inventory item, shop) you can place a boombox with:
--   exports.pena_soundplayer:placeBoombox(source)

-- Limits for saved playlists and EQ presets.
Config.playlists = {
    maxPerPlayer    = 20,   -- playlists per player
    maxTracks       = 100,  -- songs per playlist
    maxEqPresets    = 15,   -- EQ presets per player
    shareCodeLength = 6,    -- length of the code used to share a playlist or preset
}

-- Songs you do not want played. Admins can also manage this in game with
-- /songblock, /songunblock and /songblocklist (saved in the database).
Config.blocklist = {
    ids        = {},             -- YouTube video ids, for example { 'dQw4w9WgXcQ' }
    words      = {},             -- blocked if the title or channel contains any of these words
    adminGroup = 'group.admin',  -- ace group allowed to use the block commands
}
