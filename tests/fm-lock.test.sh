#!/usr/bin/env bash
# Behavior tests for shared firstmate session-lock process predicates.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-lock-tests)

make_fake_ps() {
  local fakebin=$1
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
fmt=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) fmt=${2:-}; shift 2 ;;
    -p) shift 2 ;;
    *) shift ;;
  esac
done
case "$fmt" in
  comm=) printf '%s\n' "${FM_FAKE_PS_COMM:-}" ;;
  args=) printf '%s\n' "${FM_FAKE_PS_ARGS:-}" ;;
  ppid=) printf '%s\n' "${FM_FAKE_PS_PPID:-1}" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
}

run_harness_pid_case() {
  local comm=$1 args=$2 fakebin
  fakebin=$(fm_fakebin "$TMP_ROOT/ps-$(printf '%s' "$comm$args" | tr -c '[:alnum:]' '_')")
  make_fake_ps "$fakebin"
  PATH="$fakebin:$PATH" FM_FAKE_PS_COMM="$comm" FM_FAKE_PS_ARGS="$args" bash -c '
    . "$1"
    fm_session_harness_pid >/dev/null
  ' _ "$ROOT/bin/fm-lock-lib.sh"
}

run_holder_alive_case() {
  local comm=$1 args=$2 fakebin pid status
  fakebin=$(fm_fakebin "$TMP_ROOT/holder-$(printf '%s' "$comm$args" | tr -c '[:alnum:]' '_')")
  make_fake_ps "$fakebin"
  sleep 60 &
  pid=$!
  status=0
  PATH="$fakebin:$PATH" FM_FAKE_PS_COMM="$comm" FM_FAKE_PS_ARGS="$args" bash -c '
    . "$1"
    fm_session_holder_alive "$2"
  ' _ "$ROOT/bin/fm-lock-lib.sh" "$pid" || status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  return "$status"
}

test_harness_pid_matches_bare_harness_comm() {
  run_harness_pid_case /usr/local/bin/claude 'claude' \
    || fail "bare claude comm was not recognized as a harness"
  pass "fm_session_harness_pid recognizes a bare harness comm"
}

test_harness_pid_preserves_node_args_fallback() {
  run_harness_pid_case /usr/bin/node 'node /opt/npm/@anthropic-ai/claude-code/cli.js' \
    || fail "node claude-code script path was not recognized as a harness"
  run_harness_pid_case /usr/bin/node 'node --enable-source-maps /opt/codex/cli.js' \
    || fail "node codex script path after a flag was not recognized as a harness"
  run_harness_pid_case /usr/bin/node 'node /opt/pi/bin/pi --model default' \
    || fail "node pi script path was not recognized as a harness"
  pass "fm_session_harness_pid preserves node/python args-wide harness detection"
}

test_holder_alive_matches_exec_argv0_harness() {
  run_holder_alive_case /bin/sleep 'claude 60' \
    || fail "exec -a claude style args were not recognized as a live holder"
  pass "fm_session_holder_alive recognizes exec-argv0 harness holders"
}

test_holder_alive_matches_pi_basename() {
  run_holder_alive_case /usr/local/bin/pi 'pi --model default' \
    || fail "bare pi basename was not recognized as a live holder"
  run_holder_alive_case /usr/bin/node 'node /opt/pi/bin/pi --model default' \
    || fail "node-launched pi args were not recognized as a live holder"
  pass "fm_session_holder_alive recognizes pi basename and node-launched pi holders"
}

test_holder_alive_rejects_non_harness_process() {
  if run_holder_alive_case /bin/sleep 'sleep 60'; then
    fail "plain sleep was recognized as a harness holder"
  fi
  pass "fm_session_holder_alive rejects live non-harness processes"
}

test_dash_leading_comm_is_quiet() {
  local fakebin out status
  fakebin=$(fm_fakebin "$TMP_ROOT/dash-leading")
  make_fake_ps "$fakebin"
  status=0
  out=$(PATH="$fakebin:$PATH" FM_FAKE_PS_COMM='-not-a-harness' FM_FAKE_PS_ARGS='-not-a-harness' bash -c '
    . "$1"
    fm_session_harness_pid >/dev/null
  ' _ "$ROOT/bin/fm-lock-lib.sh" 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "dash-leading non-harness comm unexpectedly matched"
  [ -z "$out" ] || fail "dash-leading comm emitted stderr: $out"
  pass "fm_session_harness_pid handles dash-leading comm names quietly"
}

test_harness_pid_matches_bare_harness_comm
test_harness_pid_preserves_node_args_fallback
test_holder_alive_matches_exec_argv0_harness
test_holder_alive_matches_pi_basename
test_holder_alive_rejects_non_harness_process
test_dash_leading_comm_is_quiet
