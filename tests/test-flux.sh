#!/bin/bash
# Unit tests: the pure decisions in flux-lib.sh and the launch line. No Docker, no Steam, no game.
# Run from the repository root.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# shellcheck source=scripts/flux-lib.sh
FLUX_LOG="" source scripts/flux-lib.sh

pass=0
fail=0
check() { # description, expected, actual
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n  expected: [%s]\n  actual:   [%s]\n' "$1" "$2" "$3"
  fi
}
status() { "$@" >/dev/null 2>&1; echo $?; }
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
# launch VAR=value...: the launch line with exactly these variables (warnings on stderr dropped).
launch() { env -i PATH="${PATH}" "$@" python3 scripts/flux-launch.py 2>/dev/null; }
warnings() { { env -i PATH="${PATH}" "$@" python3 scripts/flux-launch.py >/dev/null; } 2>&1; }

# --- Inputs ------------------------------------------------------------------------------------
check "27015 is a port" "27015" "$(flux_valid_port 27015)"
check "port 80 is refused" "1" "$(status flux_valid_port 80)"
check "a word is not a port" "1" "$(status flux_valid_port abc)"
check "old restarts age out" "900 950" "$(flux_restarts_in_window 1000 200 100 700 900 950)"
check "a requested quit is not counted" "1" "$(status flux_restart_counts 'requested: the server quit (exit 0)')"
check "a crash is counted" "0" "$(status flux_restart_counts 'the server ended on its own (exit 139)')"
check "keeps the newest" $'c\nd' "$(flux_files_to_prune 2 a b c d)"

# --- The launch line ---------------------------------------------------------------------------
check "defaults" "./srcds_run_64 -game tf -norestart -console -port 27015 +exec banned_user.cfg +exec banned_ip.cfg +maxplayers 24 +map ctf_2fort" "$(launch)"
check "everything set, quoted values as one word with their quotes" \
  "./srcds_run_64 -game tf -norestart -console -port 31015 +exec banned_user.cfg +exec banned_ip.cfg +maxplayers 32 +map pl_upward +hostname '\"My TF2 Server\"' +sv_password '\"pw\"' +rcon_password '\"rcon12345\"' +sv_setsteamaccount 0123456789ABCDEF0123456789ABCDEF +sv_region 3" \
  "$(launch GAME_PORT=31015 TF2_MAXPLAYERS=32 TF2_MAP=pl_upward TF2_HOSTNAME='My TF2 Server' TF2_PASSWORD=pw TF2_RCON_PASSWORD=rcon12345 TF2_GSLT=0123456789ABCDEF0123456789ABCDEF TF2_EXTRA_ARGS='+sv_region 3')"
check "a Workshop map" "0" "$(status grep -q '+map workshop/454812751' <<<"$(launch TF2_MAP=workshop/454812751)")"
check "a hostname with a quote is left out" "1" "$(status grep -q hostname <<<"$(launch TF2_HOSTNAME='bad"name')")"
check "a password with a space is left out" "1" "$(status grep -q sv_password <<<"$(launch TF2_PASSWORD='a b')")"
check "a map that is not one word falls back" "0" "$(status grep -q '+map ctf_2fort' <<<"$(launch TF2_MAP='ctf 2fort; quit')")"
check "players out of range fall back" "0" "$(status grep -q '+maxplayers 24' <<<"$(launch TF2_MAXPLAYERS=500)")"
check "a bad port falls back" "0" "$(status grep -q -- '-port 27015' <<<"$(launch GAME_PORT=80)")"
check "extra args may not set the port" "1" "$(status grep -q 'sv_lan' <<<"$(launch TF2_EXTRA_ARGS='+sv_lan 0 -port 1')")"
# shellcheck disable=SC2016  # the $(...) is the payload, on purpose not expanded
check "a shell metacharacter stays an argument" "0" "$(status grep -qF "'\$(reboot)'" <<<"$(launch TF2_EXTRA_ARGS='$(reboot)')")"
check "no RCON password is said" "0" "$(status grep -q 'RCON stays off' <<<"$(warnings)")"
check "a bad token is said and left out" "0" "$(status grep -q 'TF2_GSLT' <<<"$(warnings TF2_GSLT=nope)")"

# The line, run through a shell the way `script -c` runs it, reaches srcds as these words.
words="$(bash -c "printf '[%s]' $(launch TF2_HOSTNAME='Flux Test Server' TF2_RCON_PASSWORD=abc12345)")"
check "the shell hands srcds the quoted name as one word" "0" "$(status grep -qF '[+hostname]["Flux Test Server"]' <<<"${words}")"

# --- flux-tf2: the panel's file commands ---------------------------------------------------------
data="${tmp}/data"
tf2() { env -i PATH="${PATH}" FLUX_DATA_DIR="${data}" FLUX_SERVER_DIR="${tmp}/server" python3 scripts/fluxtf2.py "$@"; }
mkdir -p "${tmp}/server/tf/maps" && touch "${tmp}/server/tf/maps/ctf_2fort.bsp" "${tmp}/server/tf/maps/pl_upward.bsp" "${tmp}/server/tf/maps/readme.txt"
jq1() { python3 -c 'import json,sys; d=json.load(sys.stdin); exec(sys.argv[1])' "$1"; }
mkdir -p "${data}/custom/flux/cfg" "${data}/addons/sourcemod/plugins" "${data}/addons/sourcemod/bin"
printf 'mp_timelimit 30\n' >"${data}/custom/flux/cfg/server.cfg"
check "the game's own maps" "['ctf_2fort', 'pl_upward']" "$(tf2 files | jq1 'print(d["stock"])')"
check "files on an empty server" "[] [] False" "$(tf2 files | jq1 'print(d["maps"], d["plugins"], d["sourcemod"]["on"])')"
printf 'VBSP0000' >"${tmp}/1700000000-koth_test.bsp"
check "a map installs, the upload prefix dropped" "koth_test" "$(tf2 map-install "${tmp}/1700000000-koth_test.bsp" | jq1 'print(d["map"])')"
check "and is listed" "koth_test.bsp" "$(tf2 files | jq1 'print(d["maps"][0]["file"])')"
printf 'nope' >"${tmp}/bad.bsp"
check "a file that is not a map is refused" "2" "$(status tf2 map-install "${tmp}/bad.bsp")"
check "a path is not a map name" "2" "$(status tf2 map-remove '../server.cfg')"
check "a map is removed" "0" "$(status tf2 map-remove koth_test.bsp)"
check "the map cycle" "0" "$(status tf2 set-mapcycle '["ctf_2fort", "workshop/454812751", "pl_upward"]')"
check "is written" "ctf_2fort workshop/454812751 pl_upward" "$(tr '\n' ' ' <"${data}/custom/flux/cfg/mapcycle_flux.txt" | sed 's/ $//')"
check "and server.cfg points at it, once" "1" "$(grep -c '^mapcyclefile "mapcycle_flux.txt"' "${data}/custom/flux/cfg/server.cfg")"
tf2 set-mapcycle '["cp_badlands"]' >/dev/null
check "a second save does not add another line" "1" "$(grep -c '^mapcyclefile' "${data}/custom/flux/cfg/server.cfg")"
check "the rest of server.cfg is kept" "1" "$(grep -c '^mp_timelimit 30' "${data}/custom/flux/cfg/server.cfg")"
check "a map cycle with a command in it is refused" "2" "$(status tf2 set-mapcycle '["ctf_2fort; quit"]')"
printf 'FFPS0000' >"${tmp}/1700000000-nextmap.smx"
check "a plugin installs" "nextmap.smx" "$(tf2 plugin-install "${tmp}/1700000000-nextmap.smx" | jq1 'print(d["plugin"])')"
check "off moves it to disabled/" "0" "$(status bash -c "tf2() { env -i PATH=\"\${PATH}\" FLUX_DATA_DIR='${data}' python3 scripts/fluxtf2.py \"\$@\"; }; tf2 plugin-enable nextmap.smx off >/dev/null && test -f '${data}/addons/sourcemod/plugins/disabled/nextmap.smx'")"
check "listed as off" "False" "$(tf2 files | jq1 'print(d["plugins"][0]["enabled"])')"
check "on brings it back" "True" "$(tf2 plugin-enable nextmap.smx on | jq1 'print(d["enabled"])')"
printf 'MZ' >"${tmp}/evil.smx"
check "a file that is not a plugin is refused" "2" "$(status tf2 plugin-install "${tmp}/evil.smx")"
check "a plugin is removed" "0" "$(status tf2 plugin-remove nextmap.smx)"
check "admins from three kinds of SteamID" "STEAM_0:1:20011 STEAM_0:0:5 STEAM_0:1:7" \
  "$(tf2 set-admins '[{"id": "76561197960305751", "flags": "z", "immunity": 99, "name": "Owner"}, {"id": "[U:1:10]", "flags": "bcdefg"}, {"id": "STEAM_1:1:7"}]' | jq1 'print(" ".join(a["id"] for a in d["admins"]))')"
check "written as SourceMod reads them" '"STEAM_0:1:20011" "99:z" // Owner' "$(grep -m1 '^"' "${data}/addons/sourcemod/configs/admins_simple.ini")"
check "the SteamID64 is read back" "76561197960305751" "$(tf2 files | jq1 'print(d["admins"][0]["steam64"])')"
check "bad flags are refused" "2" "$(status tf2 set-admins '[{"id": "[U:1:10]", "flags": "z; quit"}]')"
check "a bad SteamID is refused" "2" "$(status tf2 set-admins '[{"id": "bob"}]')"
printf 'banid 0 STEAM_0:1:123\nbanid 60.000000 STEAM_0:0:9\nbanid 0 [U:1:247]\n' >"${data}/banned_user.cfg"
printf 'addip 0 1.2.3.4\n' >"${data}/banned_ip.cfg"
check "the ban lists are read" "id STEAM_0:1:123 0.0|id STEAM_0:0:9 60.0|id [U:1:247] 0.0|ip 1.2.3.4 0.0" "$(tf2 files | jq1 'print("|".join(" ".join(str(b[k]) for k in ("kind", "id", "minutes")) for b in d["bans"]))')"
check "a [U:1:n] ban has its SteamID64 (what writeid writes)" "76561197960265975" "$(tf2 files | jq1 'print(d["bans"][2]["steam64"])')"
check "usage" "64" "$(status tf2 nonsense)"

printf '%s passed, %s failed\n' "${pass}" "${fail}"
[ "${fail}" = "0" ]
