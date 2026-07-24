# shellcheck shell=bash
# Shared supervision status and ownership predicates.
# Usage: . bin/fm-supervision-lib.sh
#
# True exactly when a firstmate home has in-flight work (a state/<id>.meta
# exists) but no watcher has a fresh liveness beacon (state/.last-watcher-beat,
# touched every poll cycle, within the grace window). bin/fm-guard.sh uses this
# grace-based warning predicate directly; bin/fm-turnend-guard.sh uses the status
# fields here for its banner but performs its end-of-turn block decision with the
# live watcher lock check in bin/fm-wake-lib.sh. Both guards also use this file's
# live away-daemon predicate so away-mode ownership cannot drift between them.

FM_SUPERVISION_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Portable mtime; Linux stat lacks -f, macOS stat lacks -c.
fm_sup_stat_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# fm_supervision_status <state-dir> [grace-seconds]
# Populates, for the state dir at $1:
#   FM_SUP_IN_FLIGHT      count of state/*.meta (in-flight tasks)
#   FM_SUP_WATCHER_FRESH  true/false - a watcher beacon within the grace window
#   FM_SUP_BEACON_DESC    human-readable beacon age, for banners ("never" if absent)
#   FM_SUP_QUEUE_PENDING  true/false - state/.wake-queue has unread records
# grace-seconds defaults to $FM_GUARD_GRACE, then 300, matching fm-guard.sh.
# Always returns 0; callers read the vars, or use fm_supervision_unhealthy below.
fm_supervision_status() {
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} meta beat m age
  FM_SUP_IN_FLIGHT=0
  FM_SUP_WATCHER_FRESH=false
  FM_SUP_BEACON_DESC=never
  FM_SUP_QUEUE_PENDING=false

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    FM_SUP_IN_FLIGHT=$((FM_SUP_IN_FLIGHT + 1))
  done

  beat="$state/.last-watcher-beat"
  if [ -e "$beat" ]; then
    m=$(fm_sup_stat_mtime "$beat")
    if [ -n "$m" ]; then
      age=$(( $(date +%s) - m ))
      FM_SUP_BEACON_DESC="${age}s ago"
      [ "$age" -lt "$grace" ] && FM_SUP_WATCHER_FRESH=true
    else
      # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
      FM_SUP_BEACON_DESC=unknown
    fi
  fi

  # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
  [ -s "$state/.wake-queue" ] && FM_SUP_QUEUE_PENDING=true
  return 0
}

# fm_supervision_unhealthy <state-dir> [grace-seconds]
# Exit 0 (true) exactly in the dangerous state: in-flight work exists and no
# watcher has a fresh beacon. Exit 1 (false) otherwise, including zero in-flight.
fm_supervision_unhealthy() {
  fm_supervision_status "$@"
  [ "$FM_SUP_IN_FLIGHT" -gt 0 ] && [ "$FM_SUP_WATCHER_FRESH" = false ]
}

# fm_away_daemon_owns_catchup <state-dir>
# Exit 0 only when away-mode presence and daemon process identity both prove the
# away daemon owns watcher catch-up for this home.
# Callers that need watcher-health proof must additionally check the watcher
# beacon or live watcher lock; daemon liveness alone is not enough.
fm_away_daemon_owns_catchup() {
  local state=$1 mode pid recorded_identity live_identity
  if ! command -v fm_pid_identity >/dev/null 2>&1; then
    # shellcheck source=bin/fm-wake-lib.sh
    . "$FM_SUPERVISION_LIB_DIR/fm-wake-lib.sh" || {
      echo "warning: fm_away_daemon_owns_catchup could not load fm-wake-lib.sh" >&2
      return 1
    }
  fi
  [ -e "$state/.afk" ] || return 1
  mode=$(cat "$state/.supervise-daemon.mode" 2>/dev/null || true)
  [ "$mode" = away ] || return 1
  pid=$(cat "$state/.supervise-daemon.pid" 2>/dev/null | tr -d '[:space:]' || true)
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null || return 1
  recorded_identity=$(cat "$state/.supervise-daemon.pid-identity" 2>/dev/null || true)
  [ -n "$recorded_identity" ] || return 1
  live_identity=$(fm_pid_identity "$pid") || return 1
  [ "$live_identity" = "$recorded_identity" ]
}

# fm_away_daemon_watcher_healthy <state-dir> <watch-path> [grace-seconds] [home]
# Exit 0 only when the live watcher lock is held by the watcher child most
# recently spawned by the live away daemon.
FM_DAEMON_HOSTED_WATCHER_MODE=
FM_DAEMON_HOSTED_WATCHER_PID=
fm_daemon_hosted_watcher_mode() {
  local state=$1 watch_path=$2 grace=${3:-${FM_GUARD_GRACE:-300}} home=${4:-${FM_HOME:-}} child_pid daemon_pid recorded_identity live_identity mode
  FM_DAEMON_HOSTED_WATCHER_MODE=
  FM_DAEMON_HOSTED_WATCHER_PID=
  if ! command -v fm_watcher_healthy >/dev/null 2>&1; then
    # shellcheck source=bin/fm-wake-lib.sh
    . "$FM_SUPERVISION_LIB_DIR/fm-wake-lib.sh" || {
      echo "warning: fm_daemon_hosted_watcher_mode could not load fm-wake-lib.sh" >&2
      return 1
    }
  fi
  fm_watcher_healthy "$state" "$watch_path" "$grace" "$home" || return 1
  child_pid=$(cat "$state/.supervise-daemon.watcher.pid" 2>/dev/null | tr -d '[:space:]' || true)
  [ -n "$child_pid" ] && [ "$FM_WATCHER_HEALTHY_PID" = "$child_pid" ] || return 1
  daemon_pid=$(cat "$state/.supervise-daemon.pid" 2>/dev/null | tr -d '[:space:]' || true)
  case "$daemon_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$daemon_pid" 2>/dev/null || return 1
  recorded_identity=$(cat "$state/.supervise-daemon.pid-identity" 2>/dev/null || true)
  [ -n "$recorded_identity" ] || return 1
  live_identity=$(fm_pid_identity "$daemon_pid") || return 1
  [ "$live_identity" = "$recorded_identity" ] || return 1
  mode=$(cat "$state/.supervise-daemon.mode" 2>/dev/null || true)
  [ -n "$mode" ] || return 1
  # shellcheck disable=SC2034 # Read by callers after fm_daemon_hosted_watcher_mode returns.
  FM_DAEMON_HOSTED_WATCHER_MODE=$mode
  # shellcheck disable=SC2034 # Read by callers after fm_daemon_hosted_watcher_mode returns.
  FM_DAEMON_HOSTED_WATCHER_PID=$child_pid
  return 0
}

fm_away_daemon_watcher_healthy() {
  local state=$1 watch_path=$2 grace=${3:-${FM_GUARD_GRACE:-300}} home=${4:-${FM_HOME:-}}
  fm_daemon_hosted_watcher_mode "$state" "$watch_path" "$grace" "$home" || return 1
  [ "$FM_DAEMON_HOSTED_WATCHER_MODE" = away ]
}

# fm_daemon_hosted_watcher_without_delivery <state-dir> <watch-path> [grace-seconds] [home]
# Exit 0 when a live daemon-hosted watcher exists but no verified away-mode
# ownership can deliver wakes into the harness. Neutral hosts and away daemons
# whose state/.afk presence gate is absent both fall into this gap.
fm_daemon_hosted_watcher_without_delivery() {
  local state=$1 watch_path=$2 grace=${3:-${FM_GUARD_GRACE:-300}} home=${4:-${FM_HOME:-}}
  fm_daemon_hosted_watcher_mode "$state" "$watch_path" "$grace" "$home" || return 1
  fm_away_daemon_owns_catchup "$state" && return 1
  return 0
}

# fm_away_supervision_healthy <state-dir> <watch-path> <grace-seconds> <home> <watcher-fresh>
# Exit 0 when away-mode watcher ownership is healthy enough for guards to defer
# queue handling to the daemon: either the daemon's recorded child owns the live
# watcher lock, or the beacon is still fresh and no live lock holder exists
# during the daemon's normal one-shot respawn gap.
fm_away_supervision_healthy() {
  local state=$1 watch_path=$2 grace=$3 home=$4 watcher_fresh=$5 lock_pid
  if fm_away_daemon_watcher_healthy "$state" "$watch_path" "$grace" "$home"; then
    return 0
  fi
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  [ "$watcher_fresh" = true ] && ! fm_pid_alive "$lock_pid"
}
