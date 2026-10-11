# tf2-server-flux

The Team Fortress 2 dedicated server for [Flux](https://runonflux.io), as
`runonflux/tf2-server-flux`. The game's native 64-bit Linux server (Steam app 232250, srcds),
installed and updated with SteamCMD on every start, under a supervisor that:

- builds the launch line from the environment (`TF2_*`), every value validated
- runs srcds in a pseudo-terminal fed by a FIFO, so its console reaches the logs and the hub's
  console (srcds writes nothing past the map load without a terminal, and reads only from one)
- keeps the owner's part of `tf/` on the data volume: `custom/` (server.cfg, maps, sounds),
  `addons/` (Metamod:Source + SourceMod, plugins, configs), SourceMod's `cfg/sourcemod` and the two
  ban lists. The rest of `tf/` is the game's 14 GB, local to the node
- installs and updates **Metamod:Source + SourceMod** when `TF2_SOURCEMOD` is on (the stable 64-bit
  builds), never overwriting the owner's admins, databases and configs
- quits cleanly on stop and restarts the server in place when it ends on its own

## Volumes

| Path | Flux mount | What |
|---|---|---|
| `/mnt/tf2/data` | `g:` (synced) | `custom/` (`custom/flux/cfg/server.cfg`, `custom/flux/maps/`), `addons/`, `cfg-sourcemod/`, `banned_user.cfg`, `banned_ip.cfg`, `flux/` (log, console logs) |
| `/mnt/tf2/server` | `ml:server` (local) | the game, ~15 GB |

Spec: `g:/mnt/tf2/data|ml:server:/mnt/tf2/server`.

## Ports

`GAME_PORT` (27015): the game and the Steam query over UDP, RCON over TCP.

## Environment

| Variable | | |
|---|---|---|
| `TF2_HOSTNAME` | `+hostname` | 63 characters, no double quotes |
| `TF2_MAP` | `+map` | a map, or `workshop/<id>` (default `ctf_2fort`) |
| `TF2_MAXPLAYERS` | `+maxplayers` | 2-100 (default 24) |
| `TF2_PASSWORD` | `+sv_password` | |
| `TF2_RCON_PASSWORD` | `+rcon_password` | empty = RCON off |
| `TF2_GSLT` | `+sv_setsteamaccount` | a Game Server Login Token for app 440: without one the server is not in the Internet server list |
| `TF2_SOURCEMOD` | | `true` = Metamod:Source + SourceMod installed and updated every start |
| `TF2_EXTRA_ARGS` | | appended (no port) |

`FLUX_MMS_BRANCH` / `FLUX_SM_BRANCH` (1.12 / 1.12): Metamod 2.0 (dev) does not load SourceMod 1.12
on TF2 x64 ("Function CreateInterface not found", measured).

## For the hub

`flux-console <command>`: one console command, its answer printed (`status`, `say`, `kickid`,
`banid`, `changelevel`, `sm plugins list`, `sm_kick`...).

`flux-tf2` (JSON), for the files on the data volume:

| Command | |
|---|---|
| `flux-tf2 files` | custom maps, the map cycle, SourceMod (installed / on), plugins (on and off), admins, bans |
| `flux-tf2 map-install <file>` / `map-remove <name>` | a `.bsp` (checked: starts with VBSP) into `custom/flux/maps` |
| `flux-tf2 set-mapcycle '["ctf_2fort", ...]'` | `custom/flux/cfg/mapcycle_flux.txt`, and `mapcyclefile` in server.cfg |
| `flux-tf2 plugin-install <file>` / `plugin-enable <name> on\|off` / `plugin-remove <name>` | `.smx` (checked: FFPS); off = `plugins/disabled/` |
| `flux-tf2 set-admins '[{"id", "flags", "immunity", "name"}]'` | `admins_simple.ini`; SteamID64, `[U:1:n]` or STEAM_x:y:z |

Measured: `exec server.cfg` runs `custom/flux/cfg/server.cfg` (TF2 mounts custom/ folders on the
game path), `mapcyclefile mapcycle_flux.txt` is found there too, and writeid writes bans as
`banid 0 [U:1:n]`.

## Measured (build 11087207)

- 15 GB install; `ctf_2fort` up in ~20 s; ~700 MB RAM idle.
- The 64-bit server dies with "Could not load: replay_srv.so" without `libcurl-gnutls.so.4`.
- tar cannot extract SourceMod through the links to the data volume ("Invalid cross-device
  link"): unpacked aside, then copied.

## Versions

- **1.0.1** (2026-10-11): `flux-tf2`, the hub's JSON commands for maps, the map cycle, SourceMod
  plugins and admins, and the ban lists. A stock plugin switched off stays off: the SourceMod
  update no longer puts it back in plugins/.
- **1.0.0** (2026-10-11): first release, from runonflux/garrysmod-server-flux.
