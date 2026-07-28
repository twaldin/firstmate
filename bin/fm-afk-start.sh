#!/usr/bin/env bash
# Enter away mode and run the sub-supervisor daemon in a harness-tracked
# foreground process when one is not already alive.
#
# Usage: fm-afk-start.sh
#   Sets state/.afk unless FM_AFK_STATE_PREPARED=1, checks
#   state/.supervise-daemon.lock and state/.supervise-daemon.mode, and:
#     - prints "afk: daemon already running pid=<pid>" then exits 0 when that
#       lock is held by a live away-mode daemon (a REFRESH: no stale-artifact clear);
#     - stops a live neutral watcher host because state/.afk alone never
#       upgrades neutral supervision into away mode;
#     - otherwise clears any prior away session's stale escalation artifacts
#       (fm_afk_clear_stale_artifacts) for a direct, non-prepared start, then
#       execs bin/fm-supervise-daemon.sh --away-mode in the foreground.
#       The execed daemon removes this fresh .afk flag again if startup
#       validation fails before it can publish ready mode/pid-identity state.
#       A prepared start was already cleared transactionally by bin/fm-afk-launch.sh.
#
# This file is sourceable: its BASH_SOURCE guard keeps main from running, while
# exposing the daemon-lock helpers and fm_afk_clear_stale_artifacts. Sourcing it
# enables nounset and errexit; callers that need different shell options must
# restore them explicitly.
#
# This is the COMMON daemon entry for every backend. HOW it becomes a tracked
# background process differs by harness/backend and is owned elsewhere:
#   - Harnesses with a native in-pane tracked-background tool (e.g. claude, grok)
#     run this directly via that tool, so the daemon inherits the captain pane's
#     env and auto-discovers it.
#   - Harnesses with NO native background mechanism (e.g. pi) run this THROUGH
#     bin/fm-afk-launch.sh, which creates a non-visible tracked terminal per
#     backend (herdr tab/workspace, tmux detached session) and passes the
#     captain pane in as FM_SUPERVISOR_TARGET so injection targets it, not the
#     daemon's own new pane.
# Do not wrap this in `nohup ... &`: Codex/herdr can reap fire-and-forget shell
# children after the tool call returns, while a tracked background terminal stays
# attached and has a real lifecycle.
set -eu

FM_AFK_START_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_AFK_START_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_AFK_STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FM_AFK_LOCK="$FM_AFK_STATE/.supervise-daemon.lock"
FM_AFK_DAEMON="$FM_AFK_START_DIR/fm-supervise-daemon.sh"

# shellcheck source=bin/fm-wake-lib.sh
. "$FM_AFK_START_DIR/fm-wake-lib.sh"

fm_afk_start_usage() {
  sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# fm_afk_clear_stale_artifacts: on a FRESH away-session entry (the daemon is not
# already running), drop the previous away session's leftover escalation-delivery
# artifacts so they cannot surface as stale escalations under the new session.
# These are session-scoped by timing: a fresh entry owns a new supervision
# session and the new daemon has not produced anything yet, so anything present
# here belongs to a PRIOR session. This never drops a genuinely-pending
# escalation - the delivery buffer is a transient cache, and any condition still
# true (a crew still blocked, a check still firing) is re-derived and re-escalated
# fresh by the daemon's heartbeat catch-all scan and the durable
# state/.wake-queue replay (see docs/herdr-backend.md "Away-mode stale-artifact
# lifecycle" and bin/fm-supervise-daemon.sh's escalate_add/inject_wedge_alarm).
# NOT called on a refresh (daemon already alive), so the current session's own
# buffered escalations are preserved.
fm_afk_clear_stale_artifacts() {  # <state-dir>
  local state=$1
  rm -f "$state/.subsuper-escalations" \
        "$state/.subsuper-escalations.since" \
        "$state/.subsuper-inject-wedged" 2>/dev/null
}

daemon_lock_owner() {
  local owner
  if [ -L "$FM_AFK_LOCK" ]; then
    owner=$(readlink "$FM_AFK_LOCK" 2>/dev/null) || return 1
    [ -n "$owner" ] || return 1
    case "$owner" in
      /*) printf '%s\n' "$owner" ;;
      *) printf '%s/%s\n' "$(dirname "$FM_AFK_LOCK")" "$owner" ;;
    esac
    return 0
  fi
  [ -d "$FM_AFK_LOCK" ] || return 1
  printf '%s\n' "$FM_AFK_LOCK"
}

daemon_pid_matches() {
  local pid=$1 owner=$2 identity current
  identity=$(cat "$owner/pid-identity" 2>/dev/null || true)
  [ -n "$identity" ] || return 1
  current=$(fm_pid_identity "$pid") || return 1
  [ "$current" = "$identity" ]
}

daemon_pid_command_matches() {
  local pid=$1 mode=${2:-} command escaped_script
  command=$(ps -p "$pid" -o command= 2>/dev/null || true)
  escaped_script=$(printf '%s\n' "$FM_AFK_DAEMON" | sed 's/[][(){}.^$*+?|\\/]/\\&/g')
  case "$mode" in
    away)
      printf '%s\n' "$command" | grep -Eq "(^|[[:space:]])($escaped_script|[^[:space:]]+/fm-supervise-daemon\\.sh)[[:space:]].*--away-mode([[:space:]]|$)"
      return
      ;;
    neutral-host|neutral)
      printf '%s\n' "$command" | grep -Eq "(^|[[:space:]])($escaped_script|[^[:space:]]+/fm-supervise-daemon\\.sh)[[:space:]].*--neutral-host([[:space:]]|$)"
      return
      ;;
    *)
      printf '%s\n' "$command" | grep -Eq "(^|[[:space:]])($escaped_script|[^[:space:]]+/fm-supervise-daemon\\.sh)([[:space:]]|$)"
      return
      ;;
  esac
}

daemon_lock_pid() {
  local owner
  owner=$(daemon_lock_owner) || return 1
  cat "$owner/pid" 2>/dev/null || true
}

daemon_lock_held_by_live_daemon() {
  local owner pid identity mode
  owner=$(daemon_lock_owner) || return 1
  pid=$(cat "$owner/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" || return 1
  mode=$(cat "$FM_AFK_STATE/.supervise-daemon.mode" 2>/dev/null || true)
  identity=$(cat "$owner/pid-identity" 2>/dev/null || true)
  if [ -n "$identity" ]; then
    daemon_pid_matches "$pid" "$owner" || return 1
  else
    daemon_pid_command_matches "$pid" "$mode" || return 1
  fi
  [ "$mode" = away ]
}

daemon_lock_held_by_live_any_daemon() {
  local owner pid
  owner=$(daemon_lock_owner) || return 1
  pid=$(cat "$owner/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" || return 1
  daemon_pid_matches "$pid" "$owner"
}

daemon_lock_has_reused_pid() {
  local owner pid identity
  owner=$(daemon_lock_owner) || return 1
  pid=$(cat "$owner/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" || return 1
  identity=$(cat "$owner/pid-identity" 2>/dev/null || true)
  [ -n "$identity" ] || return 1
  daemon_pid_matches "$pid" "$owner" && return 1
  return 0
}

daemon_lock_held_by_live_ambiguous_daemon() {
  local owner pid identity mode
  owner=$(daemon_lock_owner) || return 1
  pid=$(cat "$owner/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" || return 1
  identity=$(cat "$owner/pid-identity" 2>/dev/null || true)
  [ -z "$identity" ] || return 1
  mode=$(cat "$FM_AFK_STATE/.supervise-daemon.mode" 2>/dev/null || true)
  daemon_pid_command_matches "$pid" "$mode"
}

daemon_lock_has_identityless_reused_pid() {
  local owner pid identity mode
  owner=$(daemon_lock_owner) || return 1
  pid=$(cat "$owner/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" || return 1
  identity=$(cat "$owner/pid-identity" 2>/dev/null || true)
  [ -z "$identity" ] || return 1
  mode=$(cat "$FM_AFK_STATE/.supervise-daemon.mode" 2>/dev/null || true)
  daemon_pid_command_matches "$pid" "$mode" && return 1
  return 0
}

daemon_wait_for_stop() {
  local pid=$1 i=0
  while fm_pid_alive "$pid" && [ "$i" -lt 50 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  ! fm_pid_alive "$pid"
}

fm_afk_start_clear_fresh_flag() {
  [ "${FM_AFK_STATE_PREPARED:-0}" = 1 ] && return 0
  rm -f "$FM_AFK_STATE/.afk" 2>/dev/null || true
}

fm_afk_start_main() {
  case "${1:-}" in
    '' ) ;;
    -h|--help) fm_afk_start_usage; return 0 ;;
    * ) echo "usage: $(basename "${BASH_SOURCE[1]:-fm-afk-start.sh}")" >&2; return 2 ;;
  esac

  mkdir -p "$FM_AFK_STATE"
  if [ "${FM_AFK_STATE_PREPARED:-0}" = 1 ]; then
    [ -f "$FM_AFK_STATE/.afk" ] || { echo "afk: launcher-prepared state is missing" >&2; return 1; }
  else
    date '+%s' > "$FM_AFK_STATE/.afk"
  fi

  local pid
  pid=$(daemon_lock_pid 2>/dev/null || true)
  if daemon_lock_held_by_live_daemon; then
    echo "afk: daemon already running pid=$pid"
    return 0
  fi

  if daemon_lock_held_by_live_any_daemon; then
    echo "afk: replacing neutral supervise daemon pid=$pid with away-mode daemon"
    kill "$pid" 2>/dev/null || true
    if ! daemon_wait_for_stop "$pid"; then
      echo "afk: live supervise daemon pid=$pid did not stop" >&2
      fm_afk_start_clear_fresh_flag
      return 1
    fi
  elif daemon_lock_held_by_live_ambiguous_daemon; then
    echo "afk: live supervise daemon pid=$pid has no lock identity; stop it before entering away mode" >&2
    fm_afk_start_clear_fresh_flag
    return 1
  elif daemon_lock_has_reused_pid || daemon_lock_has_identityless_reused_pid; then
    fm_lock_remove_path "$FM_AFK_LOCK" 2>/dev/null || true
  fi

  # Fresh start: clear the previous away session's stale delivery artifacts
  # before the new daemon can surface them (fix for the leaked-artifact defect).
  if [ "${FM_AFK_STATE_PREPARED:-0}" != 1 ]; then
    fm_afk_clear_stale_artifacts "$FM_AFK_STATE"
  fi

  echo "afk: starting supervise daemon in foreground; keep this command as a tracked background session"
  if [ "${FM_AFK_STATE_PREPARED:-0}" = 1 ]; then
    exec env FM_SUPERVISE_AWAY_MODE=1 "$FM_AFK_DAEMON" --away-mode
  fi
  exec env FM_SUPERVISE_AWAY_MODE=1 FM_AFK_START_OWNS_FLAG=1 "$FM_AFK_DAEMON" --away-mode
}

# Run only when executed, not when sourced (tests source fm_afk_clear_stale_artifacts
# and the lock helpers directly).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fm_afk_start_main "$@"
fi
