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
check "defaults" "./srcds_run_64 -game tf -norestart -console -strictportbind -port 27015 +exec banned_user.cfg +exec banned_ip.cfg +maxplayers 24 +map ctf_2fort" "$(launch)"
check "everything set, quoted values as one word with their quotes" \
  "./srcds_run_64 -game tf -norestart -console -strictportbind -port 31015 +exec banned_user.cfg +exec banned_ip.cfg +maxplayers 32 +map pl_upward +hostname '\"My TF2 Server\"' +sv_password '\"pw\"' +rcon_password '\"rcon12345\"' +sv_setsteamaccount 0123456789ABCDEF0123456789ABCDEF +sv_region 3" \
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

# --- flux-tf2: the files the panel edits ---------------------------------------------------------
data="${tmp}/data"
tf2() { env -i PATH="${PATH}" FLUX_DATA_DIR="${data}" FLUX_SERVER_DIR="${tmp}/srv" FLUX_RESTART_MARKER="${tmp}/marker" FLUX_GENERATION_FILE="${tmp}/gen" python3 scripts/fluxtf2.py "$@"; }
admins="${data}/addons/sourcemod/configs/admins_simple.ini"
mkdir -p "$(dirname "${admins}")"
cat >"${admins}" <<'INI'
// The owner's own notes, kept
"STEAM_0:1:5" "@Full Admins"
"STEAM_0:0:7" "50:bcd" "secretpw" // Bob
"!10.0.0.1" "99:z"
"SomePlayerName" "a"
some line nobody can read
"STEAM_0:0:9" "z" // Gone
INI
admin_json="$(tf2 files)"
check "a group admin reads as its group" "@Full Admins True" "$(python3 -c 'import json,sys;a=json.loads(sys.argv[1])["admins"][0];print(a["flags"], a["group"])' "${admin_json}")"
check "an IP admin is read-only" "False" "$(python3 -c 'import json,sys;a=[x for x in json.loads(sys.argv[1])["admins"] if x["id"]=="!10.0.0.1"][0];print(a["editable"])' "${admin_json}")"
tf2 set-admins '[{"id":"STEAM_0:1:5","flags":"@Full Admins","immunity":0,"name":""},{"id":"STEAM_0:0:7","flags":"bcde","immunity":50,"name":"Bob"},{"id":"76561197960265748","flags":"z","immunity":99,"name":"New"}]' >/dev/null
check "the group stays a group" '"STEAM_0:1:5" "@Full Admins"' "$(sed -n 2p "${admins}")"
check "an edit keeps the admin's password" '"STEAM_0:0:7" "50:bcde" "secretpw" // Bob' "$(sed -n 3p "${admins}")"
check "comments, IP and name admins and unreadable lines are kept in place" "4" "$(grep -cE '^// The owner|^"!10.0.0.1"|^"SomePlayerName"|^some line nobody' "${admins}")"
check "an admin left out is removed" "0" "$(grep -c 'STEAM_0:0:9' "${admins}")"
check "a new admin is appended" '"STEAM_0:0:10" "99:z" // New' "$(tail -1 "${admins}")"
check "a bad group is refused" "2" "$(status tf2 set-admins '[{"id":"STEAM_0:1:5","flags":"@a\"b"}]')"
check "bad flags are refused" "2" "$(status tf2 set-admins '[{"id":"STEAM_0:1:5","flags":"xyz"}]')"

# Maps: a .bsp.bz2 is unpacked; a removed map leaves the cycle; an empty cycle is the game's own.
printf 'VBSP-a-map' >"${tmp}/1700000000-ctf_test.bsp"
bzip2 -k "${tmp}/1700000000-ctf_test.bsp" && mv "${tmp}/1700000000-ctf_test.bsp.bz2" "${tmp}/1700000001-koth_zip.bsp.bz2"
check "a .bsp installs" "0" "$(status tf2 map-install "${tmp}/1700000000-ctf_test.bsp")"
check "a .bsp.bz2 is unpacked into a .bsp" "koth_zip VBSP" "$(tf2 map-install "${tmp}/1700000001-koth_zip.bsp.bz2" | python3 -c 'import json,sys;print(json.load(sys.stdin)["map"])') $(head -c 4 "${data}/custom/flux/maps/koth_zip.bsp")"
check "no .bz2 is kept" "0" "$(find "${data}/custom/flux/maps" -name '*.bz2' | wc -l)"
printf 'not bzip2' >"${tmp}/1700000002-bad.bsp.bz2"
check "a .bz2 that is not bzip2 is refused" "2" "$(status tf2 map-install "${tmp}/1700000002-bad.bsp.bz2")"
printf 'XXXX' >"${tmp}/1700000003-fake.bsp"
check "a .bsp that is not a map is refused" "2" "$(status tf2 map-install "${tmp}/1700000003-fake.bsp")"
tf2 set-mapcycle '["ctf_2fort","koth_zip","pl_upward"]' >/dev/null
tf2 map-remove koth_zip.bsp >/dev/null
check "a removed map leaves the cycle" "ctf_2fort pl_upward" "$(tr '\n' ' ' <"${data}/custom/flux/cfg/mapcycle_flux.txt" | sed 's/ $//')"
tf2 set-mapcycle '[]' >/dev/null
check "an empty cycle removes the file" "1" "$(status test -f "${data}/custom/flux/cfg/mapcycle_flux.txt")"
check "and the mapcyclefile line" "0" "$(grep -c mapcyclefile "${data}/custom/flux/cfg/server.cfg" 2>/dev/null || true)"

# Backups: start backups are skipped when one is recent; pruning keeps a day-old and a week-old one.
printf 'banid 0 [U:1:5]\n' >"${data}/banned_user.cfg"
mkdir -p "${data}/addons/sourcemod/logs" && echo log >"${data}/addons/sourcemod/logs/L1.log"
first="$(tf2 backup start | python3 -c 'import json,sys;print(json.load(sys.stdin).get("backup",""))')"
check "a first backup is made" "0" "$(status test -f "${data}/flux/backups/${first}")"
check "SourceMod's logs are not in it" "0" "$(tar -tzf "${data}/flux/backups/${first}" | grep -c 'sourcemod/logs' || true)"
check "the ban list is" "1" "$(tar -tzf "${data}/flux/backups/${first}" | grep -c '^banned_user.cfg$')"
check "a second start backup within the hour is skipped" "1" "$(tf2 backup start | grep -c skipped)"
check "prune: keeps the newest 2, the newest day-old and the newest week-old one" "c e g" "$(PYTHONPATH=scripts python3 -c '
import fluxtf2 as t
now=10*86400
rows=[{"name":n,"created":now-a} for n,a in [("a",10),("b",20),("c",3600),("d",90000),("e",100000),("f",8*86400),("g",9*86400)]]
print(" ".join(t.backups_to_prune(rows,2,now)))')"
check "a restore needs a backup name" "2" "$(status tf2 restore ../../etc/passwd)"
check "an unknown backup is refused" "2" "$(status tf2 restore 20990101-000000-tf2.tar.gz)"
check "a restore is requested (the server is not running here)" "${first}" "$(tf2 restore "${first}" >/dev/null; cat "${data}/flux/restore-request")"
check "with a restart marker" "requested: restore ${first}" "$(cat "${tmp}/marker")"
printf 'banid 0 [U:1:999]\n' >"${data}/banned_user.cfg"
rm -rf "${data}/addons/sourcemod/configs"
out="$(tf2 apply-restore)"
check "the restore puts the backup back" "banid 0 [U:1:5]" "$(cat "${data}/banned_user.cfg")"
check "admins too" "0" "$(status test -f "${admins}")"
check "after a safety backup of what was there" "1" "$(python3 -c 'import json,sys;print(int(bool(json.loads(sys.argv[1])["safetyBackup"])))' "${out}")"
check "the request is done" "1" "$(status test -f "${data}/flux/restore-request")"

# Stock plugins: one the owner removed is not put back by an update.
sm="${tmp}/sm" && mkdir -p "${sm}/src/disabled" "${sm}/dst/disabled"
touch "${sm}/src/basebans.smx" "${sm}/src/nextmap.smx" "${sm}/src/disabled/rockthevote.smx"
FLUX_LOG="" place_plugins "${sm}/src" "${sm}/dst" >/dev/null
check "a first install places every stock plugin" "3" "$(find "${sm}/dst" -name '*.smx' | wc -l)"
rm "${sm}/dst/nextmap.smx"
FLUX_LOG="" place_plugins "${sm}/src" "${sm}/dst" >/dev/null
check "a removed stock plugin stays removed" "1" "$(status test -f "${sm}/dst/nextmap.smx")"
mv "${sm}/dst/basebans.smx" "${sm}/dst/disabled/"
FLUX_LOG="" place_plugins "${sm}/src" "${sm}/dst" >/dev/null
check "a switched-off one stays off" "0 1" "$(status test -f "${sm}/dst/disabled/basebans.smx") $(status test -f "${sm}/dst/basebans.smx")"

# --- The entrypoint: launcher warnings never reach the launch line --------------------------------
# The real launch-building lines of start_generation, run with a launcher that warns on stderr. A
# process substitution inside $(...) would write the logged warning into the launch line.
# shellcheck disable=SC2016
block="$(sed -n '/^  launch="\$(python3/,/^  fi$/p' scripts/flux-entrypoint.sh)"
# shellcheck disable=SC2329
(
  python3() { echo "./srcds_run_64 -game tf"; echo "launch warning: bad value" >&2; }
  flux_log() { echo "LOG $*" >>"${tmp}/entry.log"; echo "$*"; }
  launch=""
  eval "${block//return 1/true}"
  printf '%s' "${launch}" >"${tmp}/launch.out"
) >/dev/null
captured="$(cat "${tmp}/launch.out")"
check "the warning is still logged" "LOG launch: launch warning: bad value" "$(cat "${tmp}/entry.log")"
check "launcher warnings stay out of the launch line" "./srcds_run_64 -game tf" "${captured}"

printf '%s passed, %s failed\n' "${pass}" "${fail}"
[ "${fail}" = "0" ]
