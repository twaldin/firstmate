#!/usr/bin/env bash
# tests/fm-afk-start.test.sh - /afk daemon launcher safety.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

AFK_START="$ROOT/bin/fm-afk-start.sh"
TMP_ROOT=$(fm_test_tmproot fm-afk-start-tests)

wait_for_file_contains() {
  local file=$1 needle=$2 limit=${3:-80} i=0
  while [ "$i" -lt "$limit" ]; do
    if [ -f "$file" ] && grep -F -- "$needle" "$file" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

stop_pid() {
  local pid=$1 i=0
  [ -n "$pid" ] || return 0
  kill "$pid" 2>/dev/null || true
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 50 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  kill -KILL "$pid" 2>/dev/null || true
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

record_daemon_lock() {
  local state=$1 pid=$2 mode=$3 identity owner
  identity=$(pid_identity_for_state "$state" "$pid") || fail "could not identify fake daemon pid"
  owner="$state/.supervise-daemon.lock.owner.test"
  mkdir -p "$owner"
  printf '%s\n' "$pid" > "$owner/pid"
  printf '%s\n' "$identity" > "$owner/pid-identity"
  ln -s "$owner" "$state/.supervise-daemon.lock"
  printf '%s\n' "$pid" > "$state/.supervise-daemon.pid"
  printf '%s\n' "$identity" > "$state/.supervise-daemon.pid-identity"
  printf '%s\n' "$mode" > "$state/.supervise-daemon.mode"
}

test_keeps_existing_identity_matched_away_daemon() {
  local dir state pid status
  dir=$(make_supercase keep-existing-away)
  state="$dir/state"
  start_quiet_blocker
  pid=$QUIET_BLOCKER_PID
  record_daemon_lock "$state" "$pid" away
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
  local dir state fakebin err pid start_pid
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
    "$AFK_START" 2>"$err" &
  start_pid=$!
  if ! wait_for_file_contains "$state/.supervise-daemon.mode" "away" 120; then
    stop_pid "$start_pid"
    fail "launcher did not start away daemon: $(cat "$err" 2>/dev/null)"
  fi
  pid=$(cat "$state/.supervise-daemon.pid" 2>/dev/null || true)
  [ -n "$pid" ] || pid=$start_pid
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

test_replaces_existing_neutral_host_with_away_daemon() {
  local dir state fakebin sent capture out err old_pid new_pid start_pid i
  dir=$(make_supercase replace-neutral)
  state="$dir/state"
  fakebin="$dir/fakebin"
  sent="$dir/sent.log"
  capture="$dir/pane.txt"
  out="$dir/start.out"
  err="$dir/start.err"
  : > "$sent"
  : > "$capture"
  start_quiet_blocker
  old_pid=$QUIET_BLOCKER_PID
  record_daemon_lock "$state" "$old_pid" neutral-host

  PATH="$fakebin:$PATH" \
    FM_STATE_OVERRIDE="$state" \
    FM_SUPERVISOR_BACKEND=tmux \
    FM_SUPERVISOR_TARGET=fakepane \
    FM_FAKE_TMUX_PANE_ALIVE=1 \
    FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_HEARTBEAT_SCAN_SECS=999999 \
    FM_HOUSEKEEPING_TICK=999999 \
    FM_POLL=5 \
    FM_SIGNAL_GRACE=999999 \
    FM_HEARTBEAT=999999999 \
    FM_CHECK_INTERVAL=999999 \
    "$AFK_START" >"$out" 2>"$err" &
  start_pid=$!

  i=0
  while kill -0 "$old_pid" 2>/dev/null && [ "$i" -lt 80 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  if kill -0 "$old_pid" 2>/dev/null; then
    stop_pid "$start_pid"
    stop_pid "$old_pid"
    fail "launcher did not stop the prior neutral watcher host"
  fi
  if ! wait_for_file_contains "$state/.supervise-daemon.mode" "away" 120; then
    stop_pid "$start_pid"
    fail "launcher did not replace neutral host with ready away daemon: $(cat "$err" 2>/dev/null)"
  fi
  new_pid=$(cat "$state/.supervise-daemon.pid" 2>/dev/null || true)
  [ -n "$new_pid" ] || new_pid=$start_pid
  [ "$new_pid" != "$old_pid" ] || fail "launcher reused prior neutral pid as away daemon"
  [ -e "$state/.afk" ] || fail "launcher did not leave .afk active after neutral replacement"
  grep -F 'afk: replacing neutral supervise daemon' "$out" >/dev/null \
    || fail "launcher did not report neutral replacement: stdout=$(cat "$out" 2>/dev/null); stderr=$(cat "$err" 2>/dev/null)"
  stop_pid "$new_pid"
  pass "fm-afk-start: replaces an existing neutral watcher host with away mode"
}

test_keeps_existing_identity_matched_away_daemon
test_starts_away_daemon_and_verifies_readiness
test_replaces_existing_neutral_host_with_away_daemon
