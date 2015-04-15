package = 'lp'
version = 'scm-1'
source  = {
    url    = 'git://github.com/dr-co/lp.git',
    branch = 'master',
}
description = {
    summary  = "Long Polling for Tarantool",
    homepage = 'https://github.com/dr-co/lp',
    license  = 'BSD',
}
dependencies = {
    'lua >= 5.1'
}
build = {
    type = 'builtin',

    modules = {
        ['lp.init']   = 'lua/init.lua',
        ['lp.on_lsn'] = 'lua/on_lsn.lua'
    }
}

-- vim: syntax=lua
