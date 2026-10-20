#!/bin/bash
# PID 1, and the supervisor of the Team Fortress 2 server.
#
# The game runs as a CHILD, never exec, so a stop reaches us first, and a server that ends on its
# own is followed by the next one in place:
#
#   - every start: SteamCMD update, tf/custom, tf/addons and the ban lists linked to the data
#     volume, Metamod + SourceMod installed or updated when TF2_SOURCEMOD is on, the launch line
#     from the environment (flux-launch.py), then
#     srcds in a PSEUDO-TERMINAL fed by a FIFO. srcds only writes its console to a terminal: run
#     plainly in a container it goes silent once the map is up (the previous image did, measured),
#     so the platform's log showed nothing past the start. Here every console line reaches the
#     container's output and a rotated log on the game volume
#   - a backup of the owner's files (custom/, addons/, the ban lists) on start, unless one is
#     younger than an hour, and every FLUX_BACKUP_HOURS; a restore the hub asked for
#     (flux-tf2 restore) is applied between two servers, after a safety backup
#   - SIGTERM/SIGINT from Docker: `quit` on the console (the ban lists are on disk already)
#   - the server ending on its own: a new generation in the same container, updated first
#   - FLUX_RESTART_MAX_ATTEMPTS unplanned restarts inside FLUX_RESTART_WINDOW seconds: the
#     container ends with 42, a server that cannot stay up is the platform's to rebuild or move
#
# Same shape as runonflux/unturned-server-flux and runonflux/7dtd-server-flux.

set -uo pipefail
# shellcheck source=scripts/flux-lib.sh
source /opt/flux/flux-lib.sh

FLUX_RESTART_MAX_ATTEMPTS="${FLUX_RESTART_MAX_ATTEMPTS:-5}"
FLUX_RESTART_WINDOW="${FLUX_RESTART_WINDOW:-3600}"
FLUX_RESTART_BACKOFF="${FLUX_RESTART_BACKOFF:-10}"
FLUX_STOP_GRACE="${FLUX_STOP_GRACE:-30}"
FLUX_BACKUP_HOURS="${FLUX_BACKUP_HOURS:-6}"
# SourceMod writes a log per day and never deletes one: older ones go.
FLUX_SM_LOG_DAYS="${FLUX_SM_LOG_DAYS:-14}"
tf2() { python3 /opt/flux/fluxtf2.py "$@"; }

s="${FLUX_SERVER_DIR}"
g="${FLUX_GAME_DIR}"

rm -f "${FLUX_RESTART_MARKER}"
d="${FLUX_DATA_DIR}"
mkdir -p "${s}" "${g}" "${d}" "${d}/flux" "$(dirname "${FLUX_LOG}")" "${FLUX_GAME_LOG_DIR}"
# An older image kept flux.log on the synced data volume: move it here, once.
flux_log_migrate "${FLUX_DATA_DIR}/flux/flux.log"
flux_banner "Team Fortress 2"
# Image 1.0.1 kept the console logs on the synced data volume (flux/logs): gone, they are local now.
rm -f "${d}"/flux/logs/*-console.log 2>/dev/null && rmdir "${d}/flux/logs" 2>/dev/null

if ! port="$(flux_valid_port "${GAME_PORT:-27015}")"; then
  flux_log "ERROR GAME_PORT='${GAME_PORT:-}' is not a port from 1024 to 65535; refusing to start"
  exit 42
fi
export GAME_PORT="${port}"
flux_log "flux-entrypoint starting (image ${FLUX_IMAGE_VERSION:-dev}, port ${port})"

game_pid=""
backup_pid=""
game_rc=0
terminating=0
generation=0
restart_history=()

rm -f "${FLUX_CONSOLE_FIFO}"
mkfifo -m 600 "${FLUX_CONSOLE_FIFO}"
exec 3<>"${FLUX_CONSOLE_FIFO}"

stop_server() {
  [ -n "${game_pid}" ] || return 0
  if ! printf 'quit\n' >&3; then
    flux_log "WARN the console did not take the command; stopping the server with a signal"
    kill -TERM "${game_pid}" 2>/dev/null
  fi
}

# shellcheck disable=SC2329  # invoked by the trap below
term_handler() {
  terminating=1
  flux_log "stop requested ($1): quitting the server, no restart will follow"
  stop_server
}
trap 'term_handler TERM' TERM
trap 'term_handler INT' INT

update_server() {
  local attempt validate
  if flux_truthy "${SKIP_UPDATE:-}" && [ -x "${s}/srcds_run_64" ]; then
    flux_log "SKIP_UPDATE is set: not updating the server files"
    return 0
  fi
  flux_log "updating the server from Steam (app ${FLUX_STEAM_APP})"
  # No `validate` on the first attempt: it re-hashes the whole ~15 GB install, and would put back
  # stock files the owner changed in the game folder. A broken install fails the first attempt,
  # and every retry validates.
  validate=""
  for attempt in 1 2 3 4 5; do
    # In the background and waited for: a `docker stop` during a download reaches the trap at
    # once instead of after SteamCMD (a foreground child holds bash's traps until it ends).
    # shellcheck disable=SC2086  # validate is "" or "validate"
    steamcmd +force_install_dir "${s}" +login anonymous +app_update "${FLUX_STEAM_APP}" ${validate} +quit >/tmp/steamcmd.log 2>&1 &
    local steam_pid=$!
    wait "${steam_pid}"
    local steam_rc=$?
    if [ "${terminating}" = "1" ]; then
      kill "${steam_pid}" 2>/dev/null
      return 1
    fi
    [ "${steam_rc}" = "0" ] && return 0
    validate="validate"
    flux_log "WARN steamcmd failed (attempt ${attempt}/5): $(grep -E 'ERROR|Error|error' /tmp/steamcmd.log | tail -1)"
    sleep 5
  done
  if [ -x "${s}/srcds_run_64" ]; then
    flux_log "WARN could not update from Steam; starting the build already installed"
    return 0
  fi
  flux_log "ERROR could not install the server from Steam"
  return 1
}

# The owner's part of tf/ lives on the data volume: custom/ (TF2 mounts every folder in it, so
# custom/flux/cfg/server.cfg, custom/flux/maps/*.bsp and sounds there are found as if in tf/),
# addons/ (Metamod and SourceMod with their plugins and configs) and the two ban lists. The rest
# of tf/ is the game's own files (most of the ~15 GB install), local to the node.
link_data() {
  local name target
  mkdir -p "${d}/custom/flux/cfg" "${d}/custom/flux/maps" "${d}/addons"
  [ -f "${d}/custom/flux/cfg/server.cfg" ] || cp /opt/flux/server.cfg "${d}/custom/flux/cfg/server.cfg"
  # Image 1.0.2: maps up to 64 MB download from the server itself (TF2's default is 16 MB, and
  # a bigger custom map kicked every player who did not have it). Added once to a server.cfg that
  # does not say, never over an owner's own value.
  grep -qE '^[[:space:]]*net_maxfilesize' "${d}/custom/flux/cfg/server.cfg" \
    || printf '\n// Maps up to 64 MB download from the server itself; bigger ones need FastDL (sv_downloadurl).\nnet_maxfilesize 64\n' >>"${d}/custom/flux/cfg/server.cfg"
  for name in custom addons; do
    target="${g}/${name}"
    if [ -L "${target}" ]; then
      [ "$(readlink "${target}")" = "${d}/${name}" ] && continue
      rm -f "${target}"
    elif [ -d "${target}" ]; then
      cp -an "${target}/." "${d}/${name}/" 2>/dev/null
      rm -rf "${target}"
    fi
    ln -s "${d}/${name}" "${target}"
  done
  # SourceMod's own configs (made on its first run, then the owner's) are in tf/cfg/sourcemod.
  mkdir -p "${d}/cfg-sourcemod"
  if [ ! -L "${g}/cfg/sourcemod" ]; then
    [ -d "${g}/cfg/sourcemod" ] && cp -an "${g}/cfg/sourcemod/." "${d}/cfg-sourcemod/" && rm -rf "${g}/cfg/sourcemod"
    ln -s "${d}/cfg-sourcemod" "${g}/cfg/sourcemod"
  fi
  for name in banned_user.cfg banned_ip.cfg; do
    touch "${d}/${name}"
    target="${g}/cfg/${name}"
    if [ ! -L "${target}" ]; then
      [ -s "${target}" ] && [ ! -s "${d}/${name}" ] && cp "${target}" "${d}/${name}"
      rm -f "${target}"
      ln -s "${d}/${name}" "${target}"
    fi
  done
}

# TF2_SOURCEMOD on: Metamod:Source and SourceMod (their 64-bit builds; Metamod 2.0 (dev) does NOT
# load SourceMod 1.12 on TF2 x64, "Function CreateInterface not found", measured), the
# latest of their stable branches, into addons/ on the data volume. Updated on every start
# (SourceMod breaks on game updates until it is updated too); plugins, configs and data are kept.
# Off: metamod_x64.vdf (what loads Metamod) is moved aside, everything else stays.
FLUX_SM_PROGRAM_FILES='^addons/(metamod/bin/|sourcemod/(bin/|extensions/|gamedata/|translations/|scripting/include/))'

install_sourcemod() {
  local vdf="${d}/addons/metamod_x64.vdf" tmp url
  if ! flux_truthy "${TF2_SOURCEMOD:-false}"; then
    [ -f "${vdf}" ] && mv -f "${vdf}" "${vdf}.off" && flux_log "SourceMod: off (addons kept; metamod.vdf moved aside)"
    return 0
  fi
  tmp="$(mktemp -d)"
  for url in "https://mms.alliedmods.net/mmsdrop/${FLUX_MMS_BRANCH:-1.12}/mmsource-latest-linux" "https://sm.alliedmods.net/smdrop/${FLUX_SM_BRANCH:-1.12}/sourcemod-latest-linux"; do
    local name
    name="$(curl -fsSL --max-time 30 "${url}" 2>/dev/null | tr -d '\r\n')"
    if [ -z "${name}" ] || ! curl -fsSL --max-time 300 -o "${tmp}/${name}" "${url%/*}/${name}"; then
      flux_log "WARN could not download ${url##*/} (${name:-no answer}); starting with the addons already there"
      continue
    fi
    # Unpacked aside, then copied over what is there in two passes: the owner's files
    # (admins_simple.ini, databases.cfg, core.cfg, plugins they moved to disabled/) are never
    # overwritten; the program files (bin, extensions, gamedata, translations, the stock plugins)
    # always are, so an update lands. Not extracted in place: tar cannot write through the links
    # to the data volume ("Invalid cross-device link", measured).
    rm -rf "${tmp}/x" && mkdir -p "${tmp}/x"
    if tar -C "${tmp}/x" -xzf "${tmp}/${name}" 2>/dev/null; then
      # The plugins are placed on their own (place_plugins), so they are taken out of the copy.
      if [ -d "${tmp}/x/addons/sourcemod/plugins" ]; then
        mv "${tmp}/x/addons/sourcemod/plugins" "${tmp}/plugins"
      fi
      [ -d "${tmp}/x/addons" ] && cp -an "${tmp}/x/addons/." "${d}/addons/"
      [ -d "${tmp}/x/cfg/sourcemod" ] && cp -an "${tmp}/x/cfg/sourcemod/." "${d}/cfg-sourcemod/"
      (cd "${tmp}/x" && find addons -type f | grep -E "${FLUX_SM_PROGRAM_FILES}" | while IFS= read -r f; do
        mkdir -p "${d}/$(dirname "${f}")" && cp -f "${f}" "${d}/${f}"
      done)
      [ -d "${tmp}/plugins" ] && place_plugins "${tmp}/plugins" "${d}/addons/sourcemod/plugins"
      rm -rf "${tmp}/plugins"
      flux_log "SourceMod: ${name}"
    else
      flux_log "WARN ${name} could not be unpacked"
    fi
  done
  rm -rf "${tmp}"
  [ -f "${vdf}.off" ] && [ ! -f "${vdf}" ] && mv -f "${vdf}.off" "${vdf}"
  # metamod_x64.vdf (Metamod's own, for 64-bit servers) is the one loader. The archive's
  # metamod.vdf points a 64-bit server at the same library again: with both, Metamod is loaded
  # twice and SourceMod fails to attach ("Function CreateInterface not found", measured).
  rm -f "${d}/addons/metamod.vdf" "${d}/addons/metamod.vdf.off"
}

# shellcheck disable=SC2329  # run in the background below
backupper() {
  [ "${FLUX_BACKUP_HOURS}" -gt 0 ] 2>/dev/null || exit 0
  while true; do
    sleep $((FLUX_BACKUP_HOURS * 3600))
    flux_log "backup (every ${FLUX_BACKUP_HOURS}h): $(tf2 backup "every ${FLUX_BACKUP_HOURS}h" force 2>&1 | tail -c 300)"
  done
}

# The console, line by line: carriage returns and terminal escapes dropped, onto the container's
# output and into the current log file, which is rotated at FLUX_GAME_LOG_MAX_BYTES.
# shellcheck disable=SC2329  # used in a process substitution below
console_writer() {
  local line file bytes=0
  file="${FLUX_GAME_LOG_DIR}/$(date +%Y%m%d-%H%M%S)-console.log"
  : >"${file}"
  while IFS= read -r line; do
    line="${line//$'\r'/}"
    # shellcheck disable=SC2001  # a regex, not a fixed string
    line="$(sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' <<<"${line}")"
    printf '%s\n' "${line}"
    printf '%s\n' "${line}" >>"${file}"
    bytes=$((bytes + ${#line} + 1))
    if [ "${bytes}" -ge "${FLUX_GAME_LOG_MAX_BYTES}" ]; then
      file="${FLUX_GAME_LOG_DIR}/$(date +%Y%m%d-%H%M%S)-console.log"
      : >"${file}"
      bytes=0
      flux_prune "${FLUX_GAME_LOG_DIR}" '*-console.log' "${FLUX_GAME_LOG_KEEP}"
    fi
  done
}

start_generation() {
  local launch line build
  generation=$((generation + 1))
  rm -f "${FLUX_RESTART_MARKER}" "${FLUX_EXIT_FILE}"

  update_server || return 1
  [ "${terminating}" = "1" ] && return 2

  # The build, for the panel's Overview: steam.inf's PatchVersion.
  build="$(sed -n 's/^PatchVersion=//p' "${g}/steam.inf" 2>/dev/null | tr -dc '0-9')"
  [ -n "${build}" ] && flux_log "Team Fortress 2 build ${build}"
  # A restore the hub asked for (flux-tf2 restore): applied before anything reads the files.
  [ -f "${d}/flux/restore-request" ] && flux_log "restore: $(tf2 apply-restore 2>&1 | tail -c 400)"
  link_data
  flux_log "backup (start): $(tf2 backup start 2>&1 | tail -c 300)"
  find "${d}/addons/sourcemod/logs" -name '*.log' -mtime "+${FLUX_SM_LOG_DAYS}" -delete 2>/dev/null
  install_sourcemod

  # The launcher's warnings go to a file and are logged after: a process substitution here would
  # write its log lines into the command substitution, i.e. into the launch line.
  launch="$(python3 /opt/flux/flux-launch.py 2>/tmp/flux-launch.err)"
  while IFS= read -r line; do flux_log "launch: ${line}"; done </tmp/flux-launch.err
  if [ -z "${launch}" ]; then
    flux_log "ERROR could not build the launch line"
    return 1
  fi
  flux_prune "${FLUX_GAME_LOG_DIR}" '*-console.log' "${FLUX_GAME_LOG_KEEP}"
  [ "${terminating}" = "1" ] && return 2

  flux_banner "Team Fortress 2"
  flux_log "starting the server (generation ${generation})"
  (
    cd "${s}" || exit 1
    export TERM=xterm
    # srcds' own exit code goes to a file: `script` itself does not end when srcds does (it goes
    # on reading the FIFO, which never closes), so the supervisor watches srcds and ends `script`.
    exec script -qfec "${launch}; echo \$? >${FLUX_EXIT_FILE}" /dev/null <"${FLUX_CONSOLE_FIFO}"
  ) > >(console_writer) 2>&1 &
  game_pid=$!
  # The hub waits for this to change to know a restart is over (never the clocks).
  printf '%s %s\n' "${generation}" "$(date -u +%s)" >"${FLUX_GENERATION_FILE}"
  backupper &
  backup_pid=$!
  return 0
}

sweep_generation() {
  [ -n "${backup_pid}" ] && kill "${backup_pid}" 2>/dev/null
  backup_pid=""
  pkill -KILL -f "${FLUX_GAME_PROCESS}" 2>/dev/null
  game_pid=""
}

# Waits for srcds to end. `script` outlives it (see start_generation), so srcds is what is
# watched: once it has run and is gone, `script` is ended too. A requested stop or restart that is
# not honoured within FLUX_STOP_GRACE ends the server by force; the grace runs from when the
# request was first seen. Sets game_rc to srcds' exit code (143 when it had to be killed).
wait_for_generation() {
  local asked_at=0 now seen=0 killed=0
  while kill -0 "${game_pid}" 2>/dev/null; do
    sleep 1 &
    wait $!
    if pgrep -f "${FLUX_GAME_PROCESS}" >/dev/null 2>&1; then
      seen=1
    elif [ "${seen}" = "1" ] || [ -f "${FLUX_EXIT_FILE}" ]; then
      # KILL, not TERM: with srcds gone `script` has nothing left to pass on, and it ignores a
      # TERM while it spins on the FIFO (measured: 97% CPU, still running ten minutes later).
      kill -KILL "${game_pid}" 2>/dev/null
      break
    fi
    if [ "${terminating}" = "1" ] || [ -f "${FLUX_RESTART_MARKER}" ]; then
      now="$(date -u +%s)"
      [ "${asked_at}" = "0" ] && asked_at="${now}"
      if [ $((now - asked_at)) -ge "${FLUX_STOP_GRACE}" ]; then
        flux_log "WARN the server was asked to stop ${FLUX_STOP_GRACE}s ago and has not; ending it"
        pkill -KILL -f "${FLUX_GAME_PROCESS}" 2>/dev/null
        kill -KILL "${game_pid}" 2>/dev/null
        killed=1
        break
      fi
    else
      asked_at=0
    fi
  done
  wait "${game_pid}" 2>/dev/null
  if [ "${killed}" = "1" ]; then
    game_rc=143
  else
    game_rc="$(tr -dc '0-9' <"${FLUX_EXIT_FILE}" 2>/dev/null)"
    [ -n "${game_rc}" ] || game_rc=1
  fi
}

while true; do
  if [ "${terminating}" = "1" ]; then
    flux_log "stopped on request before the server started"
    exit 0
  fi
  start_generation
  started=$?
  if [ "${started}" = "2" ]; then
    flux_log "stopped on request before the server started"
    exit 0
  elif [ "${started}" != "0" ]; then
    flux_log "ERROR the server could not be prepared; ending the container (42)"
    exit 42
  fi
  wait_for_generation
  rc="${game_rc}"

  reason=""
  [ -f "${FLUX_RESTART_MARKER}" ] && reason="$(cat "${FLUX_RESTART_MARKER}" 2>/dev/null)"
  sweep_generation
  rm -f "${FLUX_RESTART_MARKER}"

  if [ "${terminating}" = "1" ]; then
    flux_log "stopped on request (server exited ${rc})"
    exit 0
  fi

  # srcds ends with 0 when it was told to quit (the console's quit, an admin's RCON quit): that is
  # a restart someone asked for.
  if [ -z "${reason}" ] && [ "${rc}" = "0" ]; then
    reason="requested: the server quit (exit 0)"
  fi
  [ -z "${reason}" ] && reason="the server ended on its own (exit ${rc})"

  if flux_restart_counts "${reason}"; then
    now="$(date -u +%s)"
    read -r -a restart_history <<<"$(flux_restarts_in_window "${now}" "${FLUX_RESTART_WINDOW}" "${restart_history[@]}")"
    restart_history+=("${now}")
    if [ "${#restart_history[@]}" -gt "${FLUX_RESTART_MAX_ATTEMPTS}" ]; then
      flux_log "${reason}: ${#restart_history[@]} restarts within ${FLUX_RESTART_WINDOW}s, so restarting it here is not working. Ending the container so the platform can rebuild or move it (42)."
      exit 42
    fi
  fi

  flux_log "${reason}: restarting the server in place in ${FLUX_RESTART_BACKOFF}s"
  sleep "${FLUX_RESTART_BACKOFF}" &
  wait $!
done
