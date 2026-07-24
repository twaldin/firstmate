#!/usr/bin/env bash
# Turn-end guard for any firstmate PRIMARY session: the main home OR a
# secondmate's own home. A secondmate runs its own primary firstmate session and
# is guarded exactly like the main primary; only child crew/scout worktrees are
# exempt (see the scoping block below and docs/turnend-guard.md).
#
# fm-guard.sh (bin/fm-guard.sh) is pull-based: it only warns when some other
# supervision script happens to run. A primary session that ends a turn without
# resuming its harness supervision protocol, and then never runs another
# fleet-touching command itself, can sit blind for hours.
# This script is push-based: verified harness turn-end hooks invoke it every time
# the primary is about to end a turn.
# Claude and codex can block directly by preserving exit status 2 and stderr.
# OpenCode, pi, and grok adapters use the same predicate and force one bounded
# follow-up because their turn-end events are passive.
# See docs/turnend-guard.md for the per-harness mechanics, validation evidence,
# and fail-open tradeoffs.
#
# Ships with TRACKED harness hook files at the repo root, so this file is
# checked out into every worktree of this repo: the primary checkout, every
# secondmate home (treehouse-leased or git-cloned), and any crewmate/scout task
# worktree spawned to work on firstmate itself (the recursive "firstmate
# improving itself" case). A secondmate home runs its OWN primary firstmate
# session, so it must be guarded like the main primary; only child crew/scout
# worktrees are exempt. It must therefore scope itself at runtime to a real
# primary checkout - the main home or a genuinely marked secondmate home - and
# stay a silent, fast no-op inside child task worktrees.
#
# Loop-guard: never block twice in the same turn. Claude Code and codex Stop
# payloads carry stop_hook_active=true when the CURRENT stop attempt was itself
# already forced by an earlier block this turn; on that signal we always allow
# the stop, whether or not watcher supervision actually got resumed. Passive
# harness adapters provide their own one-follow-up guard before calling this
# script.
# That bounds this to at most one forced continuation per turn - never a wedged,
# un-endable session - while still nagging again on a later turn if the problem
# persists.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GRACE=${FM_GUARD_GRACE:-300}
WATCH="$SCRIPT_DIR/fm-watch.sh"

# shellcheck source=bin/fm-lock-lib.sh
. "$SCRIPT_DIR/fm-lock-lib.sh"

session_lock_allows_queue_block() {
  local lock="$STATE/.lock" owner me
  [ -f "$lock" ] || return 0
  owner=$(cat "$lock" 2>/dev/null | tr -d '[:space:]') || return 0
  case "$owner" in
    ''|*[!0-9]*) return 0 ;;
  esac
  me=${FM_TURNEND_HARNESS_PID_OVERRIDE:-}
  if [ -z "$me" ]; then
    me=$(fm_session_harness_pid 2>/dev/null || true)
  fi
  [ -z "$me" ] && return 0
  [ "$owner" = "$me" ] && return 0
  fm_session_holder_alive "$owner" && return 1
  return 0
}

# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"

# Read the whole turn-end hook payload once; never block on unreadable/absent
# stdin.
PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

# jq is the repo's established JSON dependency (bin/fm-x-poll.sh uses the same
# "missing jq -> silent no-op" degrade). Without it we cannot safely read the
# loop-guard field, so we must never block - fail open, not noisy.
command -v jq >/dev/null 2>&1 || exit 0

STOP_HOOK_ACTIVE=$(printf '%s' "$PAYLOAD" | jq -r '.stop_hook_active // false' 2>/dev/null) || exit 0
[ "$STOP_HOOK_ACTIVE" = "true" ] && exit 0

# --- scope precisely to a PRIMARY checkout ----------------------------------
# A genuinely-marked secondmate home runs its OWN primary firstmate session, so
# force-INCLUDE it as a guarded primary whether treehouse leased it as a linked
# worktree (git-dir != git-common-dir) or it is a git-cloned plain checkout. This
# mirrors the cd-guard's intent that a secondmate's own session is a guarded
# primary. Only an UNMARKED checkout (or one with an invalid marker) falls
# through to the linked-worktree exemption: firstmate hands out crewmate/scout
# task worktrees as genuine linked `git worktree`s (bin/fm-spawn.sh aborts
# otherwise), whose git-dir lives under the parent repo's .git/worktrees/<name>
# and differs from the common (shared) git-dir, while a main, non-worktree
# checkout has the two equal. Child worktrees never carry the gitignored marker,
# so this exempts them while guarding every real secondmate home.
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# --- the actual predicate ----------------------------------------------------
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

fm_supervision_status "$STATE" "$GRACE"
QUEUE_REASON='queued wakes pending - drain with bin/fm-wake-drain.sh before ending the turn when this session holds the fleet lock; read-only sessions must leave queued wakes for the lock holder'
WATCH_REASON='tasks in flight, no live watcher - run bin/fm-watch-arm.sh as a background task before ending the turn'
AWAY_REASON='away-mode daemon is live but watcher liveness is stale - inspect state/.supervise-daemon.log and restart away mode; stop the daemon or exit /afk before falling back to bin/fm-watch-arm.sh'
QUEUE_BLOCK=false
WATCH_BLOCK=false
AWAY_DAEMON_ACTIVE=false
AWAY_SUPERVISION_HEALTHY=false
DAEMON_DELIVERY_GAP=false
DAEMON_DELIVERY_GAP_MODE=
fm_away_daemon_owns_catchup "$STATE" && AWAY_DAEMON_ACTIVE=true
if [ "$AWAY_DAEMON_ACTIVE" = true ] && fm_away_supervision_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME" "$FM_SUP_WATCHER_FRESH"; then
  AWAY_SUPERVISION_HEALTHY=true
fi
if fm_daemon_hosted_watcher_without_delivery "$STATE" "$WATCH" "$GRACE" "$FM_HOME"; then
  DAEMON_DELIVERY_GAP=true
  DAEMON_DELIVERY_GAP_MODE=$FM_DAEMON_HOSTED_WATCHER_MODE
fi

if [ "$AWAY_DAEMON_ACTIVE" = true ] && [ "$AWAY_SUPERVISION_HEALTHY" != true ] \
   && { [ "$FM_SUP_QUEUE_PENDING" = true ] || [ "$FM_SUP_IN_FLIGHT" -gt 0 ]; }; then
  WATCH_BLOCK=away
fi
if [ "$FM_SUP_QUEUE_PENDING" = true ] && [ "$AWAY_SUPERVISION_HEALTHY" != true ] && session_lock_allows_queue_block; then
  QUEUE_BLOCK=true
fi
if [ "$FM_SUP_IN_FLIGHT" -gt 0 ] && [ "$DAEMON_DELIVERY_GAP" = true ]; then
  WATCH_BLOCK=daemon
elif [ "$FM_SUP_IN_FLIGHT" -gt 0 ] && [ "$AWAY_DAEMON_ACTIVE" != true ] && ! fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME"; then
  WATCH_BLOCK=true
fi

if [ "$QUEUE_BLOCK" = true ] || [ "$WATCH_BLOCK" != false ]; then
  rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  title='TURN WOULD END WITH SUPERVISION ACTION REQUIRED'
  if [ "$QUEUE_BLOCK" = true ] && [ "$WATCH_BLOCK" = false ]; then
    title='TURN WOULD END WITH QUEUED WAKES UNDRAINED'
  elif [ "$QUEUE_BLOCK" != true ] && [ "$WATCH_BLOCK" = true ]; then
    title='TURN WOULD END BLIND - SUPERVISION IS OFF'
  elif [ "$QUEUE_BLOCK" != true ] && [ "$WATCH_BLOCK" = away ]; then
    title='TURN WOULD END WITH AWAY-MODE WATCHER STALE'
  elif [ "$QUEUE_BLOCK" != true ] && [ "$WATCH_BLOCK" = daemon ]; then
    title='TURN WOULD END WITHOUT HARNESS WAKE DELIVERY'
  fi
  {
    printf '●%s\n' "$rule"
    printf '●  %s\n' "$title"
    if [ "$QUEUE_BLOCK" = true ]; then
      printf '●  state/.wake-queue has pending records for this home.\n'
      printf '●  %s\n' "$QUEUE_REASON"
    fi
    if [ "$WATCH_BLOCK" = true ]; then
      printf '●  %s task(s) in flight, but no live watcher holds this home lock (last beat: %s).\n' "$FM_SUP_IN_FLIGHT" "$FM_SUP_BEACON_DESC"
      printf '●  %s\n' "$WATCH_REASON"
    elif [ "$WATCH_BLOCK" = away ]; then
      printf '●  %s\n' "$AWAY_REASON"
    elif [ "$WATCH_BLOCK" = daemon ]; then
      printf '●  %s task(s) in flight, but the watcher is daemon-hosted in mode=%s without verified away-mode ownership.\n' "$FM_SUP_IN_FLIGHT" "$DAEMON_DELIVERY_GAP_MODE"
      printf '●  Stop the watcher host, or re-enter /afk if away mode should own delivery, then run bin/fm-watch-arm.sh as the harness-tracked background task before ending the turn.\n'
    fi
    printf '●%s\n' "$rule"
  } >&2
  exit 2
fi
exit 0
