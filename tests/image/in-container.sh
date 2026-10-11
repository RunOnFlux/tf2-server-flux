#!/bin/bash
# Runs INSIDE the image (tests/test-image.sh). The repository's tests/ folder is mounted at /t.
set -uo pipefail
export LC_ALL=C

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
wait_for() {
  local _
  for _ in $(seq 1 $(($2 * 5))); do
    eval "$1" && return 0
    sleep 0.2
  done
  return 1
}

# --- What the scripts need is in the image -----------------------------------------------------
for tool in steamcmd python3 pgrep pkill script mkfifo timeout tail sed; do
  check "${tool} is installed" "0" "$(status command -v "${tool}")"
done
check "flux-console is on the PATH" "0" "$(status command -v flux-console)"
check "flux-launch.py runs" "0" "$(status python3 /opt/flux/flux-launch.py)"
for script in flux-entrypoint.sh flux-console.sh flux-lib.sh; do
  check "${script} parses" "0" "$(status bash -n "/opt/flux/${script}")"
done
check "libcurl-gnutls (replay_srv.so needs it)" "0" "$(status bash -c 'ldconfig -p | grep -q libcurl-gnutls.so.4')"

# --- The supervisor, around a stand-in Steam and a stand-in srcds ------------------------------
# The stand-in behaves like srcds where it matters: it only reads its console from a TERMINAL
# (the reason the image runs it under `script`) and only prints to one, answers `say`, and ends
# with 0 on `quit`; `crash` ends it with 139.
cat >/usr/local/bin/steamcmd <<'STUB'
#!/bin/bash
dir=""
while [ $# -gt 0 ]; do
  [ "$1" = "+force_install_dir" ] && dir="$2"
  shift
done
[ -n "${dir}" ] || exit 0
mkdir -p "${dir}/tf/cfg"
printf 'PatchVersion=11087207\n' >"${dir}/tf/steam.inf"
cat >"${dir}/srcds_run_64" <<'GAME'
#!/bin/bash
exec -a srcds_linux64 bash -c '
[ -t 0 ] && [ -t 1 ] || { sleep 1000; exit 1; }
echo "args: $*"
echo "VAC secure mode is activated."
while IFS= read -r line; do
  case "${line}" in
    say\ *) echo "Console: ${line#say }" ;;
    quit) echo "quitting"; exit 0 ;;
    crash) exit 139 ;;
    *) echo "Unknown command \"${line}\"" ;;
  esac
done' srcds_linux64 "$@"
GAME
chmod +x "${dir}/srcds_run_64"
STUB
chmod +x /usr/local/bin/steamcmd

export FLUX_SERVER_DIR=/tmp/srv FLUX_DATA_DIR=/tmp/data FLUX_RESTART_BACKOFF=1
logs=/tmp/data/flux/logs
TF2_HOSTNAME='Test Server' TF2_RCON_PASSWORD=abc12345 GAME_PORT=31000 FLUX_GAME_LOG_MAX_BYTES=400 FLUX_GAME_LOG_KEEP=3 \
  /opt/flux/flux-entrypoint.sh >/tmp/sup.log 2>&1 &
sup=$!
check "srcds comes up under a terminal and its console reaches the log" "0" "$(status wait_for "grep -qh 'VAC secure' ${logs}/*-console.log 2>/dev/null" 20)"
check "the launch line arrives as words, the quoted name as one" "0" "$(status grep -qh 'args: -game tf -norestart -console -port 31000 +exec banned_user.cfg +exec banned_ip.cfg' ${logs}/*-console.log)"
check "the quoted name" "0" "$(status grep -qh '+hostname "Test Server"' ${logs}/*-console.log)"
check "the console reaches the container output too" "0" "$(status grep -q 'VAC secure' /tmp/sup.log)"
check "the build is logged" "0" "$(status grep -q "Team Fortress 2 build 11087207" /tmp/sup.log)"
check "tf/custom is the data volume" "/tmp/data/custom" "$(readlink /tmp/srv/tf/custom)"
check "tf/addons is the data volume" "/tmp/data/addons" "$(readlink /tmp/srv/tf/addons)"
check "the ban list is the data volume" "/tmp/data/banned_user.cfg" "$(readlink /tmp/srv/tf/cfg/banned_user.cfg)"
check "a server.cfg to edit" "0" "$(status test -s /tmp/data/custom/flux/cfg/server.cfg)"
check "flux-console reaches the console and prints the answer" "0" "$(status grep -q 'Console: hi there' <<<"$(flux-console say hi there)")"

for n in 1 2 3 4 5 6 7 8; do flux-console say "filler line number ${n} to roll the log over" >/dev/null; done
check "the console log is rotated and pruned" "1" "$(status test "$(find "${logs}" -name '*-console.log' | wc -l)" -gt 3)"

# A crash: restarted in place.
flux-console crash >/dev/null
check "a crash is restarted in place" "0" "$(status wait_for "grep -q 'restarting the server in place' /tmp/sup.log" 10)"
check "and the new server comes up" "0" "$(status wait_for "grep -q 'generation 2' /tmp/sup.log" 10)"
check "the crash is reported with its code" "0" "$(status grep -q 'exit 139' /tmp/sup.log)"
sleep 2

kill -TERM "${sup}"
wait "${sup}"
check "a stop exits 0" "0" "$?"
check "a stop is a console quit" "0" "$(status grep -q 'stopped on request (server exited 0)' /tmp/sup.log)"
check "nothing is left running" "1" "$(status pgrep -f 'srcds_linux64|script -qfec')"

printf '%s passed, %s failed\n' "${pass}" "${fail}"
[ "${fail}" = "0" ]
