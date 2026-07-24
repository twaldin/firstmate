#!/usr/bin/env bash
# Watcher liveness and worktree-tangle guard, called by supervision scripts, by
# fm-wake-drain.sh after it empties queued wakes, and by fm-session-start.sh in
# read-only advisory mode when another session holds the fleet lock.
# First, always warn if the firstmate primary checkout (FM_ROOT) is on a named
# non-default branch, because that means firstmate-on-itself work landed in the
# primary instead of an isolated worktree.
# Then, if any task is in flight (a state/<id>.meta exists) and the watcher's
# liveness beacon (state/.last-watcher-beat, touched every poll cycle) is
# missing or older than FM_GUARD_GRACE seconds, prints a loud, clearly delimited
# banner so the agent cannot skim past it in the tool output of whatever it was
# doing - the one channel every harness has. The full banner is emitted once per
# distinct staleness episode in this FM_HOME (keyed to beacon mtime or absence);
# later guarded commands in the same episode print a one-line reminder instead.
# Episode state lives only under state/.guard-watcher-stale-banner (volatile,
# bounded). Independent alarms (queued wakes, worktree tangle) are never
# suppressed by that dedup. Normal wake handling (watcher briefly down between a
# wake and the next supervision resume) stays inside the grace window and stays
# silent. Always exits 0: the guard warns, it never blocks.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GRACE=${FM_GUARD_GRACE:-300}
WATCH="$SCRIPT_DIR/fm-watch.sh"
queue_pending=false
READ_ONLY=${FM_GUARD_READ_ONLY:-0}
case "$READ_ONLY" in 1|true|TRUE|yes|YES) READ_ONLY=1 ;; *) READ_ONLY=0 ;; esac
CONTINUE_LINE=${FM_GUARD_CONTINUE_LINE:-This is a supervision warning only; the guarded operation WILL still run.}

# Volatile, home-scoped episode marker: one line = the current stale-episode key.
# Cleared when the home leaves the unhealthy state so a later episode re-arms.
STALE_BANNER_MARKER="$STATE/.guard-watcher-stale-banner"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-tangle-lib.sh
. "$SCRIPT_DIR/fm-tangle-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"

# Deterministic episode key from beacon state: same continuous stale beacon
# (or continuous absence) shares a key; a recovered-then-restale beacon gets a
# new mtime and therefore a new episode.
fm_guard_stale_episode_key() {
  local state=$1 beat m
  beat="$state/.last-watcher-beat"
  if [ -e "$beat" ]; then
    m=$(fm_sup_stat_mtime "$beat")
    printf 'beat:%s\n' "${m:-unknown}"
  else
    printf 'beat:absent\n'
  fi
}

# Claim the full banner for this episode. Exit 0 = print full banner (this call
# owns the first announcement). Exit 1 = same episode already announced (print
# reminder). The shared wake lock helper owns the race-safety mechanics; the
# re-check under the lock makes concurrent claims idempotent.
fm_guard_claim_stale_banner() {
  local state=$1 key=$2
  local marker="$state/.guard-watcher-stale-banner"
  local lock="$state/.guard-watcher-stale-banner.lock"
  local seen i

  seen=$(cat "$marker" 2>/dev/null || true)
  # Strip a single trailing newline so key comparison is line-content based.
  seen=${seen%$'\n'}
  if [ "$seen" = "$key" ]; then
    return 1
  fi

  i=0
  while [ "$i" -lt 50 ]; do
    if fm_lock_try_acquire "$lock"; then
      seen=$(cat "$marker" 2>/dev/null || true)
      seen=${seen%$'\n'}
      if [ "$seen" = "$key" ]; then
        fm_lock_release "$lock" 2>/dev/null || true
        return 1
      fi
      # Bounded write: one line, no growth across episodes (overwrite).
      printf '%s\n' "$key" > "$marker" || true
      fm_lock_release "$lock" 2>/dev/null || true
      return 0
    fi
    seen=$(cat "$marker" 2>/dev/null || true)
    seen=${seen%$'\n'}
    if [ "$seen" = "$key" ]; then
      return 1
    fi
    # Brief yield; 0.02s is fine on macOS/Linux sleep, fall back to 1s.
    sleep 0.02 2>/dev/null || sleep 1
    i=$((i + 1))
  done
  # Contended past the spin budget: stay loud rather than dropping the alarm.
  return 0
}

fm_guard_stale_banner_seen() {
  local state=$1 key=$2
  local marker="$state/.guard-watcher-stale-banner"
  local seen

  seen=$(cat "$marker" 2>/dev/null || true)
  seen=${seen%$'\n'}
  [ "$seen" = "$key" ]
}

fm_guard_clear_stale_banner() {
  rm -f "$STALE_BANNER_MARKER" 2>/dev/null || true
}

# Worktree-tangle alarm, checked FIRST and independent of in-flight tasks: the
# firstmate PRIMARY checkout (FM_ROOT) must stay on its default branch. If a
# crewmate's branch/commits landed here instead of in its own isolated worktree,
# the primary is stranded on a feature branch - surface it loudly on the very next
# fleet action, the same way the watcher-down banner does. Scoped to the primary
# only: detached HEAD (linked worktrees, secondmate homes) never trips this.
tangle_branch=$(fm_primary_tangle_branch "$FM_ROOT" || true)
if [ -n "$tangle_branch" ]; then
  tangle_default=$(fm_default_branch "$FM_ROOT" 2>/dev/null || echo main)
  trule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  {
    printf '●%s\n' "$trule"
    printf '●  WORKTREE TANGLE - PRIMARY CHECKOUT IS ON A FEATURE BRANCH\n'
    printf "●  %s is on '%s', not its default branch '%s'.\n" "$FM_ROOT" "$tangle_branch" "$tangle_default"
    printf '●  A crewmate likely branched/committed in the primary instead of its own worktree.\n'
    printf "●  The work is SAFE on the '%s' ref.\n" "$tangle_branch"
    if [ "$READ_ONLY" -eq 1 ]; then
      printf '●  This read-only session must leave restore work to the session holding the fleet lock.\n'
    else
      printf "●  Restore the primary to '%s':\n" "$tangle_default"
      printf '●      git -C %s checkout %s\n' "$FM_ROOT" "$tangle_default"
      printf "●  then re-validate '%s' in a proper isolated worktree.\n" "$tangle_branch"
    fi
    printf '●%s\n' "$trule"
  } >&2
fi

# Compute in-flight count and watcher-beacon freshness via the shared
# grace-based predicate (bin/fm-supervision-lib.sh). Only act with tasks in
# flight; count them so the banner can say how much is riding on an absent
# watcher.
fm_supervision_status "$STATE" "$GRACE"
in_flight=$FM_SUP_IN_FLIGHT
watcher_fresh=$FM_SUP_WATCHER_FRESH
beacon_desc=$FM_SUP_BEACON_DESC

[ -s "$FM_WAKE_QUEUE" ] && queue_pending=true
away_daemon_active=false
away_supervision_healthy=false
daemon_delivery_gap=false
daemon_delivery_gap_mode=
fm_away_daemon_owns_catchup "$STATE" && away_daemon_active=true
if [ "$away_daemon_active" = true ] && fm_away_supervision_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME" "$watcher_fresh"; then
  away_supervision_healthy=true
fi
if fm_daemon_hosted_watcher_without_delivery "$STATE" "$WATCH" "$GRACE" "$FM_HOME"; then
  daemon_delivery_gap=true
  daemon_delivery_gap_mode=$FM_DAEMON_HOSTED_WATCHER_MODE
fi

warn_queued_wakes() {
  if [ "$READ_ONLY" -eq 1 ]; then
    echo "WARNING: queued wakes pending - left untouched for the session holding the fleet lock." >&2
  elif [ "$away_daemon_active" = true ]; then
    echo "WARNING: queued wakes pending while away-mode watcher health is not verified - inspect state/.supervise-daemon.log and restart away mode; stop the daemon or exit /afk before falling back to bin/fm-watch-arm.sh." >&2
  else
    echo "WARNING: queued wakes pending - drain them with bin/fm-wake-drain.sh before anything else." >&2
  fi
}

if [ "$in_flight" -eq 0 ]; then
  if "$queue_pending" && { [ "$away_daemon_active" != true ] || [ "$away_supervision_healthy" != true ]; }; then
    warn_queued_wakes
  fi
  exit 0
fi

# No fresh watcher with tasks in flight is the dangerous state: emit a prominent,
# bordered banner FIRST so it reads as an alarm, not a buried stderr line.
if [ "$watcher_fresh" = false ] || [ "$daemon_delivery_gap" = true ]; then
  episode_key=$(fm_guard_stale_episode_key "$STATE")
  episode_key=${episode_key%$'\n'}
  print_full_banner=1
  if [ "$daemon_delivery_gap" != true ]; then
    print_full_banner=0
    if [ "$READ_ONLY" -eq 1 ]; then
      fm_guard_stale_banner_seen "$STATE" "$episode_key" || print_full_banner=1
    elif fm_guard_claim_stale_banner "$STATE" "$episode_key"; then
      print_full_banner=1
    fi
  fi
  if [ "$print_full_banner" -eq 1 ]; then
    if [ "$READ_ONLY" -eq 1 ]; then
      fix='Watcher repair belongs to the session holding the fleet lock; do not drain or re-arm from this read-only session.'
    elif [ "$daemon_delivery_gap" = true ]; then
      fix='Stop the watcher host, or re-enter /afk if away mode should own delivery, then run bin/fm-watch-arm.sh as the harness-tracked background task (never a shell & that gets reaped).'
    elif [ "$away_daemon_active" = true ]; then
      fix='Away-mode daemon is live but watcher liveness is stale; inspect state/.supervise-daemon.log and restart away mode. Stop the daemon or exit /afk before falling back to bin/fm-watch-arm.sh.'
    else
      afk=0
      [ -e "$STATE/.afk" ] && afk=1
      queue_arg=0
      "$queue_pending" && queue_arg=1
      x_mode=0
      [ -f "$CONFIG/x-mode.env" ] && x_mode=1
      fix=$("$SCRIPT_DIR/fm-supervision-instructions.sh" \
        --read-only "$READ_ONLY" \
        --afk "$afk" \
        --x-mode "$x_mode" \
        --queue-pending "$queue_arg" \
        --repair-line 2>/dev/null || printf '%s\n' 'Repair missing watcher supervision according to the session-start operating block.')
    fi
    rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
    {
      printf '●%s\n' "$rule"
      if [ "$daemon_delivery_gap" = true ]; then
        printf '●  WATCHER HOSTED WITHOUT HARNESS WAKE DELIVERY\n'
        printf '●  %s task(s) in flight, but the live watcher is daemon-hosted in mode=%s without verified away-mode ownership.\n' "$in_flight" "$daemon_delivery_gap_mode"
      else
        printf '●  WATCHER DOWN - SUPERVISION IS OFF\n'
        printf '●  %s task(s) in flight, but no watcher has a fresh beacon (last beat: %s, grace %ss).\n' "$in_flight" "$beacon_desc" "$GRACE"
      fi
      if [ "$READ_ONLY" -eq 1 ]; then
        printf '●  This read-only session should report the lapse, not repair it.\n'
      elif [ "$daemon_delivery_gap" = true ]; then
        printf '●  Stop the watcher host or restore verified /afk ownership before arming a harness-tracked watcher cycle.\n'
      elif [ "$away_daemon_active" = true ]; then
        printf '●  Away-mode watcher repair starts with the supervise daemon; use the plain watcher arm only after stopping the daemon or exiting /afk.\n'
      else
        printf '●  Trust the emitted supervision protocol for this harness; do not use shell & for watcher repair.\n'
      fi
      printf '●  %s\n' "$CONTINUE_LINE"
      printf '●  %s\n' "$fix"
      printf '●%s\n' "$rule"
    } >&2
  else
    printf 'WARNING: watcher still down (same stale episode; last beat: %s, grace %ss) - full banner already printed this episode.\n' \
      "$beacon_desc" "$GRACE" >&2
  fi
else
  # Healthy again while work is still in flight: end the episode so a later
  # restale re-prints the full banner.
  [ "$READ_ONLY" -eq 1 ] || fm_guard_clear_stale_banner
fi

# Queued wakes are an independent hazard; warn whenever they are pending, even if
# a watcher is alive. Kept after the banner so the no-watcher alarm reads first.
# Dedup of the watcher-down banner never suppresses this warning.
if "$queue_pending" && [ "$away_daemon_active" = true ] && [ "$away_supervision_healthy" = true ]; then
  : # The live away daemon owns catch-up; do not tell firstmate to drain its queue.
elif "$queue_pending"; then
  warn_queued_wakes
fi
exit 0
