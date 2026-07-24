#!/usr/bin/env bash
# tests/fm-afk-start.test.sh - /afk daemon launcher safety.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

AFK_START="$ROOT/bin/fm-afk-start.sh"
TMP_ROOT=$(fm_test_tmproot fm-afk-start-tests)

stop_pid() {
  local pid=$1
  [ -n "$pid" ] || return 0
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

QUIET_BLOCKER_PID=
start_quiet_blocker() {
  (
    trap 'exit 0' TERM INT
    while :; do
      sleep 1
    done
  ) &
  QUIET_BLOCKER_PID=$!
}

pid_identity_for_state() {
  local state=$1 pid=$2
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$pid"
}

test_keeps_existing_identity_matched_away_daemon() {
  local dir state pid identity status
  dir=$(make_supercase keep-existing-away)
  state="$dir/state"
  start_quiet_blocker
  pid=$QUIET_BLOCKER_PID
  identity=$(pid_identity_for_state "$state" "$pid") || {
    stop_pid "$pid"
    fail "could not identify fake away daemon"
  }
  printf '%s\n' "$pid" > "$state/.supervise-daemon.pid"
  printf '%s\n' "$identity" > "$state/.supervise-daemon.pid-identity"
  printf 'away\n' > "$state/.supervise-daemon.mode"
  status=0
  FM_STATE_OVERRIDE="$state" "$AFK_START" || status=$?
  stop_pid "$pid"
  [ "$status" -eq 0 ] || fail "launcher rejected an existing live away daemon"
  [ "$(cat "$state/.supervise-daemon.pid" 2>/dev/null || true)" = "$pid" ] \
    || fail "launcher replaced an existing identity-matched away daemon"
  [ -e "$state/.afk" ] || fail "launcher did not refresh .afk for an existing away daemon"
  pass "fm-afk-start: keeps an existing identity-matched away daemon"
}

test_starts_away_daemon_and_verifies_readiness() {
  local dir state fakebin err pid
  dir=$(make_supercase start-away)
  state="$dir/state"
  fakebin="$dir/fakebin"
  err="$dir/start.err"
  PATH="$fakebin:$PATH" \
    FM_STATE_OVERRIDE="$state" \
    FM_SUPERVISOR_BACKEND=tmux \
    FM_SUPERVISOR_TARGET=fakepane \
    FM_FAKE_TMUX_PANE_ALIVE=1 \
    FM_HEARTBEAT_SCAN_SECS=999999 \
    FM_HOUSEKEEPING_TICK=999999 \
    FM_POLL=5 \
    FM_SIGNAL_GRACE=999999 \
    FM_HEARTBEAT=999999999 \
    FM_CHECK_INTERVAL=999999 \
    "$AFK_START" 2>"$err" || fail "launcher did not start away daemon: $(cat "$err" 2>/dev/null)"
  pid=$(cat "$state/.supervise-daemon.pid" 2>/dev/null || true)
  [ "$(cat "$state/.supervise-daemon.mode" 2>/dev/null || true)" = away ] \
    || fail "launcher did not leave mode=away while daemon was ready"
  [ -s "$state/.supervise-daemon.pid-identity" ] \
    || fail "launcher did not wait for pid identity readiness"
  [ -e "$state/.afk" ] \
    || fail "launcher did not write .afk after daemon readiness"
  grep -F 'mode=away' "$state/.supervise-daemon.log" >/dev/null \
    || fail "launcher did not leave a ready away daemon log"
  stop_pid "$pid"
  pass "fm-afk-start: starts away daemon and verifies pid/mode/identity readiness"
}

test_unknown_prior_mode_is_not_restarted_as_neutral_on_failure() {
  local dir state err pid status
  dir=$(make_supercase unknown-prior-failure)
  state="$dir/state"
  err="$dir/start.err"
  start_quiet_blocker
  pid=$QUIET_BLOCKER_PID
  printf '%s\n' "$pid" > "$state/.supervise-daemon.pid"
  date '+%s' > "$state/.afk"
  status=0
  FM_STATE_OVERRIDE="$state" \
    FM_SUPERVISOR_BACKEND=orca \
    "$AFK_START" 2>"$err" || status=$?
  stop_pid "$pid"
  [ "$status" -ne 0 ] || fail "launcher succeeded despite unsupported away backend"
  ! kill -0 "$pid" 2>/dev/null || fail "launcher left unknown prior daemon running after replacement attempt"
  grep -F 'previous supervise daemon had an unknown mode' "$err" >/dev/null \
    || fail "launcher did not report unknown prior mode: $(cat "$err" 2>/dev/null)"
  [ "$(cat "$state/.supervise-daemon.mode" 2>/dev/null || true)" != neutral ] \
    || fail "launcher restarted unknown prior mode as neutral"
  [ ! -e "$state/.afk" ] \
    || fail "launcher left .afk behind after away startup failed"
  pass "fm-afk-start: unknown prior mode is reported, not restored as neutral"
}

test_keeps_existing_identity_matched_away_daemon
test_starts_away_daemon_and_verifies_readiness
test_unknown_prior_mode_is_not_restarted_as_neutral_on_failure
