#!/bin/bash
# Shared helpers for the Team Fortress 2 image.
#
# SOURCING THIS FILE MUST STAY SIDE-EFFECT FREE: tests/test-flux.sh sources it directly and
# calls the functions with made-up inputs. Everything that decides something takes its inputs
# as arguments, so the decision can be tested without a server, Steam or Docker.

# ---------------------------------------------------------------------------------------------
# Paths. The install (SteamCMD's, ~15 GB, disposable, local to the node) and the data (synced):
# custom/ (server.cfg, maps, sounds), addons/ (Metamod and SourceMod), the ban lists, and our
# flux/ (log, console logs). The install's tf/custom and tf/addons are links to the data.
# ---------------------------------------------------------------------------------------------
FLUX_SERVER_DIR="${FLUX_SERVER_DIR:-/mnt/tf2/server}"
FLUX_DATA_DIR="${FLUX_DATA_DIR:-/mnt/tf2/data}"
FLUX_GAME_DIR="${FLUX_GAME_DIR:-${FLUX_SERVER_DIR}/tf}"
# flux.log is on the INSTALL volume (local, never synced): it is written on every line, and on the
# synced data volume that would be constant Syncthing traffic. One rotated copy (flux.log.1).
FLUX_LOG_DIR="${FLUX_LOG_DIR:-${FLUX_SERVER_DIR}/flux-logs}"
FLUX_LOG="${FLUX_LOG-${FLUX_LOG_DIR}/flux.log}"
FLUX_LOG_MAX_BYTES="${FLUX_LOG_MAX_BYTES:-5242880}"
# The console logs: on the INSTALL volume (local), not the synced data one: they churn all day
# and Syncthing would copy every line (image 1.0.2; they were in flux/logs on the data volume).
FLUX_GAME_LOG_DIR="${FLUX_GAME_LOG_DIR:-${FLUX_SERVER_DIR}/flux-logs}"
FLUX_GAME_LOG_KEEP="${FLUX_GAME_LOG_KEEP:-5}"
# One console log is capped at this many bytes; past it the server goes on in a fresh one.
FLUX_GAME_LOG_MAX_BYTES="${FLUX_GAME_LOG_MAX_BYTES:-10000000}"
FLUX_GAME_PROCESS="${FLUX_GAME_PROCESS:-srcds_linux64}"
FLUX_STEAM_APP="${FLUX_STEAM_APP:-232250}"
# The server's console is its stdin. The supervisor holds this FIFO open and the server reads it
# through a pseudo-terminal; flux-console writes one command into it.
FLUX_CONSOLE_FIFO="${FLUX_CONSOLE_FIFO:-/tmp/flux-console}"
FLUX_RESTART_MARKER="${FLUX_RESTART_MARKER:-/tmp/flux-restart-requested}"
# srcds' exit code, written by the command `script` runs.
FLUX_EXIT_FILE="${FLUX_EXIT_FILE:-/tmp/flux-srcds-exit}"
# "<generation> <epoch it started>": the hub's way to see a restart is over.
FLUX_GENERATION_FILE="${FLUX_GENERATION_FILE:-/tmp/flux-generation}"

# One line, to the container's output and (when FLUX_LOG is set) to flux.log, rotated at
# FLUX_LOG_MAX_BYTES (the old file becomes flux.log.1).
flux_log_raw() {
  printf '%s\n' "$1"
  if [ -n "${FLUX_LOG}" ] && mkdir -p "$(dirname "${FLUX_LOG}")" 2>/dev/null; then
    printf '%s\n' "$1" >>"${FLUX_LOG}" 2>/dev/null || return 0
    flux_rotate_log "${FLUX_LOG}" "${FLUX_LOG_MAX_BYTES}"
  fi
  return 0
}

flux_log() {
  flux_log_raw "$(date -u '+%Y-%m-%dT%H:%M:%SZ') [flux] $*"
}

# Moves $1 to $1.1 (replacing the previous one) once it is larger than $2 bytes.
flux_rotate_log() {
  local size
  size="$(stat -c %s "$1" 2>/dev/null || echo 0)"
  if [ "${size}" -gt "$2" ] 2>/dev/null; then
    mv -f "$1" "$1.1" 2>/dev/null
  fi
  return 0
}

# The start-up banner, through the normal log path (docker logs, the panel's log). ASCII only.
# $1 = the game's name.
flux_banner() {
  local rule='====================================================================='
  flux_log_raw "${rule}"
  flux_log_raw " $1 server image by FluxCloud - https://runonflux.com"
  flux_log_raw " Host this and 30+ other games in one click: https://runonflux.com/games"
  flux_log_raw "${rule}"
}

# Once per start: a flux.log an older image left on the synced data volume ($@) is appended to
# the new one and deleted there, so Syncthing stops carrying it.
flux_log_migrate() {
  local old
  [ -n "${FLUX_LOG}" ] || return 0
  for old in "$@"; do
    [ -f "${old}" ] && [ "${old}" != "${FLUX_LOG}" ] || continue
    mkdir -p "$(dirname "${FLUX_LOG}")" 2>/dev/null
    if [ -s "${old}" ]; then
      cat "${old}" >>"${FLUX_LOG}" 2>/dev/null || continue
    fi
    rm -f "${old}" "${old}.tmp"
  done
  return 0
}

flux_truthy() {
  case "${1,,}" in
    1 | true | yes | on) return 0 ;;
    *) return 1 ;;
  esac
}

# $1 = GAME_PORT. Prints it, or returns 1 for a value that is not a usable port.
flux_valid_port() {
  local value="$1"
  [[ "${value}" =~ ^[0-9]{1,5}$ ]] || return 1
  value=$((10#${value}))
  [ "${value}" -ge 1024 ] && [ "${value}" -le 65535 ] || return 1
  printf '%s' "${value}"
}

# ---------------------------------------------------------------------------------------------
# The supervisor's restart budget: a server that keeps dying is not fixed by restarting it in
# the same container forever.
# ---------------------------------------------------------------------------------------------

# $1 = now (epoch seconds), $2 = window in seconds, $3.. = the times of earlier restarts.
# Prints the restarts that are still inside the window, space separated.
flux_restarts_in_window() {
  local now="$1" window="$2" t kept=()
  shift 2
  for t in "$@"; do
    [ "${t}" -gt $((now - window)) ] && kept+=("${t}")
  done
  printf '%s' "${kept[*]}"
}

# $1 = why the last generation ended. One that was asked for (the console's `quit`, `_restart`)
# is the plan working, not a crash.
flux_restart_counts() {
  case "$1" in
    planned* | requested*) return 1 ;;
    *) return 0 ;;
  esac
}

# ---------------------------------------------------------------------------------------------
# Rotation of the console logs.
# ---------------------------------------------------------------------------------------------

# $1 = number to keep, then the files NEWEST FIRST. Prints the ones to delete.
flux_files_to_prune() {
  local keep="$1" i=0 f
  shift
  for f in "$@"; do
    i=$((i + 1))
    [ "${i}" -gt "${keep}" ] && printf '%s\n' "${f}"
  done
  return 0
}

# $1 = directory, $2 = glob, $3 = number to keep.
flux_prune() {
  local f files=()
  # shellcheck disable=SC2012,SC2086  # $2 is a glob on purpose; names are ours, no spaces
  mapfile -t files < <(ls -t "$1"/$2 2>/dev/null)
  while IFS= read -r f; do
    [ -n "${f}" ] && rm -f "${f}"
  done < <(flux_files_to_prune "$3" "${files[@]}")
}

# ---------------------------------------------------------------------------------------------
# The running server.
# ---------------------------------------------------------------------------------------------

# The newest console log the supervisor writes.
flux_game_log() {
  # shellcheck disable=SC2012  # our own file names, no spaces
  ls -t "${FLUX_GAME_LOG_DIR}"/*-console.log 2>/dev/null | head -1
}

flux_game_pid() {
  pgrep -f "${FLUX_GAME_PROCESS}" 2>/dev/null | head -1
}

# $1 = one console command. Written into the server's stdin; returns 1 when nothing is reading
# it (no server running), without blocking.
flux_console() {
  local cmd="$1"
  [ -p "${FLUX_CONSOLE_FIFO}" ] || return 1
  [ -n "$(flux_game_pid)" ] || return 1
  # One line, no control characters: it is typed into the server's console.
  cmd="${cmd//[$'\r\n']/ }"
  # shellcheck disable=SC2016  # expanded by the inner bash, from its own arguments
  timeout 2 bash -c 'printf "%s\n" "$1" >"$2"' _ "${cmd}" "${FLUX_CONSOLE_FIFO}"
}

# ---------------------------------------------------------------------------------------------
# SourceMod
# ---------------------------------------------------------------------------------------------

# $1 = the plugins folder of a SourceMod archive, $2 = the server's. Each stock plugin is updated
# where the OWNER keeps it: in plugins/ if it is on, in plugins/disabled/ if it is off, whatever
# the archive's own folder for it (it ships mapchooser, rockthevote... in disabled/). Only a plugin
# the server has neither way goes where the archive puts it. Turning one on or off is a move
# between the two folders, so this is what keeps that choice across updates.
#
# A stock plugin installed before and now in neither folder was REMOVED by the owner (the
# SourceMod tab, or the Files tab): it stays removed. `.flux-stock-plugins` beside plugins/ lists
# every stock plugin ever placed.
place_plugins() {
  local src="$1" dst="$2" f base known="$2/../.flux-stock-plugins" stock_seen=()
  while IFS= read -r f; do
    base="${f##*/}"
    stock_seen+=("${base}")
    if [ -f "${dst}/${base}" ]; then
      cp -f "${src}/${f}" "${dst}/${base}"
    elif [ -f "${dst}/disabled/${base}" ]; then
      cp -f "${src}/${f}" "${dst}/disabled/${base}"
    elif grep -qxF "${base}" "${known}" 2>/dev/null; then
      flux_log "SourceMod: ${base} was removed by the owner; not put back"
    else
      mkdir -p "$(dirname "${dst}/${f}")" && cp -f "${src}/${f}" "${dst}/${f}"
    fi
  done < <(cd "${src}" && find . -type f -name '*.smx' | sed 's|^\./||')
  { cat "${known}" 2>/dev/null; printf '%s\n' "${stock_seen[@]}"; } | sort -u >"${known}.tmp" && mv "${known}.tmp" "${known}"
}
