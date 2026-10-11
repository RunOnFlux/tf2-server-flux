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

printf '%s passed, %s failed\n' "${pass}" "${fail}"
[ "${fail}" = "0" ]
