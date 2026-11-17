fx_version 'cerulean'
game 'gta5'
lua54 'yes'
node_version '22'

name 'pena_soundplayer'
author 'Pena'
description 'Search and play YouTube / Spotify tracks in game (boombox + car radio).'
version '1.0.0'

dependencies {
    '/onesync',
    'oxmysql',
}

shared_scripts {
    'config.lua',
    'shared/locale.lua',
    'shared/callback.lua',
}

client_scripts {
    'client/main.lua',
    'client/disable_radio.lua',
}

server_scripts {
    'server/node/main.js',
    'server/db.lua',
    'server/main.lua',
}

ui_page 'ui/index.html'

files {
    'locales/*.json',
    'ui/index.html',
    'ui/style.css',
    'ui/app.js',
    'ui/fonts/**/*',
}
