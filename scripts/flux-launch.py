#!/usr/bin/env python3
"""Prints the srcds command line for the environment, shell-quoted, one line.

    flux-launch.py

The settings come from the TF2_* variables (the same names the Flux games hub writes) and
GAME_PORT. Every value is validated here; one that cannot be passed safely is left out and
reported on stderr, so the server still starts on the rest:

    TF2_HOSTNAME             +hostname "…"        no double quotes, 63 characters
    TF2_MAP                  +map                 a map name, or workshop/<id> (default ctf_2fort)
    TF2_MAXPLAYERS           +maxplayers          2 to 100 (default 24)
    TF2_PASSWORD             +sv_password "…"     no spaces or quotes
    TF2_RCON_PASSWORD        +rcon_password "…"   no spaces or quotes
    TF2_GSLT                 +sv_setsteamaccount  32 hex characters (without one the server is
                                                  hidden from the Internet server list)
    TF2_EXTRA_ARGS           appended as written (shell words), no +port / -port
    GAME_PORT                -port                the port srcds binds (default 27015)

Always written: `-norestart` (the supervisor restarts, not srcds_run), `-console`, and
`+exec banned_user.cfg` (srcds does not read its ban list on start; a ban written with writeid
would be gone after a restart, and the next writeid would write the empty list over the file).

A value that needs quoting inside srcds (the server name, the passwords) is passed WITH its double
quotes, as one word: srcds joins its arguments into one command line and parses the quotes itself
(`+hostname "Flux Test Server"` came out as "Flux Test Server", measured).
"""
import os
import re
import shlex
import sys


def warn(message):
    print(f'WARN {message}', file=sys.stderr)


def env(name):
    return ' '.join(str(os.environ.get(name, '')).replace('\r', ' ').replace('\n', ' ').split())


def word(name, default, pattern=r'[A-Za-z0-9_./-]+'):
    value = env(name) or default
    if not re.fullmatch(pattern, value):
        warn(f'{name}={value!r} is not one word; using {default}')
        return default
    return value


def quoted(name, *, max_len=64, allow_spaces=False):
    value = env(name)
    if not value:
        return None
    if '"' in value or ';' in value or (not allow_spaces and ' ' in value) or len(value) > max_len:
        warn(f'{name} cannot be passed (quotes, semicolons{"" if allow_spaces else ", spaces"} or too long); left out')
        return None
    return f'"{value}"'


def build():
    args = ['./srcds_run_64', '-game', 'tf', '-norestart', '-console']

    port = env('GAME_PORT') or '27015'
    if not (port.isdigit() and 1024 <= int(port) <= 65535):
        warn(f'GAME_PORT={port!r} is not a port; using 27015')
        port = '27015'
    args += ['-port', port]

    maxplayers = env('TF2_MAXPLAYERS') or '24'
    if not (maxplayers.isdigit() and 2 <= int(maxplayers) <= 100):
        warn(f'TF2_MAXPLAYERS={maxplayers!r} is not 2 to 100; using 24')
        maxplayers = '24'
    args += ['+exec', 'banned_user.cfg', '+exec', 'banned_ip.cfg', '+maxplayers', maxplayers]
    # A Workshop map is workshop/<id>: the server downloads it before loading it.
    args += ['+map', word('TF2_MAP', 'ctf_2fort', r'(workshop/\d{1,20}|[A-Za-z0-9_.-]+)')]

    hostname = quoted('TF2_HOSTNAME', max_len=63, allow_spaces=True)
    if hostname:
        args += ['+hostname', hostname]
    password = quoted('TF2_PASSWORD')
    if password:
        args += ['+sv_password', password]
    rcon = quoted('TF2_RCON_PASSWORD')
    if rcon:
        args += ['+rcon_password', rcon]
    else:
        warn('no TF2_RCON_PASSWORD: RCON stays off')

    gslt = env('TF2_GSLT')
    if gslt:
        if re.fullmatch(r'[0-9A-Fa-f]{32}', gslt):
            args += ['+sv_setsteamaccount', gslt]
        else:
            warn('TF2_GSLT is not a 32-character token; left out')

    extra = env('TF2_EXTRA_ARGS')
    if extra:
        try:
            words = shlex.split(extra)
        except ValueError:
            warn('TF2_EXTRA_ARGS has unbalanced quotes; left out')
            words = []
        if any(w.lower() in ('-port', '+port', '+hostport') for w in words):
            warn('TF2_EXTRA_ARGS sets the port, which GAME_PORT owns; left out')
            words = []
        args += words
    return args


def main():
    print(' '.join(shlex.quote(a) for a in build()))
    return 0


if __name__ == '__main__':
    sys.exit(main())
