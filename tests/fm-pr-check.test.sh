#!/usr/bin/env bash
# Tests for bin/fm-pr-check.sh's generated watcher check.
#
# Matrix:
#   - approved/open current-head PR reasserts after the threshold
#   - a newer head commit invalidates an older approval
#   - merged PRs keep the existing one-line "merged" behavior
#   - repeated approved reminders are rate-limited per approval/head
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-check-tests)

old_iso() {
  perl -MPOSIX=strftime -e 'print strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time - 7200))'
}

make_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin" "$dir/root/bin"
  cat > "$dir/root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/root/bin/fm-guard.sh"
  fm_write_meta "$dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$dir/missing-worktree" \
    "project=$dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view")
    printf '%s\n' "${FM_TEST_GH_VIEW:-}"
    exit 0
    ;;
esac
exit 1
SH
  chmod +x "$fakebin/gh"
  printf '%s\n' "$dir"
}

arm_check() {  # <case-dir>
  local dir=$1
  FM_ROOT_OVERRIDE="$dir/root" FM_STATE_OVERRIDE="$dir/state" PATH="$dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/9 >/dev/null
}

run_generated_check() {  # <case-dir> <view-tsv> [repeat-secs]
  local dir=$1 view=$2 repeat=${3:-3600}
  FM_TEST_GH_VIEW="$view" PATH="$dir/fakebin:$PATH" \
    FM_PR_READY_THRESHOLD_SECS=60 FM_PR_READY_REPEAT_SECS="$repeat" \
    bash "$dir/state/task-x1.check.sh"
}

assert_one_line() {  # <output> <message>
  local count
  count=$(printf '%s\n' "$1" | sed '/^$/d' | wc -l | tr -d ' ')
  [ "$count" = 1 ] || fail "$2: expected exactly one non-empty line, got $count: $1"
}

test_approved_open_pr_reasserts_after_threshold() {
  local dir iso view out
  dir=$(make_case approved-open)
  arm_check "$dir"
  iso=$(old_iso)
  view=$(printf 'OPEN\tabc123\tfalse\tAPPROVED\t%s\tabc123' "$iso")

  out=$(run_generated_check "$dir" "$view")

  assert_one_line "$out" "approved-open"
  assert_contains "$out" "approved-awaiting-Tim: https://github.com/example/repo/pull/9" \
    "approved-open PR did not reassert after threshold"
  pass "fm-pr-check: approved/open current-head PR reasserts after the threshold"
}

test_newer_commit_invalidates_stale_approval() {
  local dir iso view out
  dir=$(make_case stale-approval)
  arm_check "$dir"
  iso=$(old_iso)
  view=$(printf 'OPEN\tnewhead\tfalse\tAPPROVED\t%s\toldhead' "$iso")

  out=$(run_generated_check "$dir" "$view")

  [ -z "$out" ] || fail "stale approval woke firstmate despite a newer head: $out"
  pass "fm-pr-check: a newer head commit invalidates the older approval"
}

test_merged_pr_keeps_existing_behavior() {
  local dir view out
  dir=$(make_case merged)
  arm_check "$dir"
  view=$(printf 'MERGED\tabc123\tfalse\t\t\t')

  out=$(run_generated_check "$dir" "$view")

  [ "$out" = merged ] || fail "merged PR check changed behavior: $out"
  pass "fm-pr-check: merged PRs still emit the existing one-line merged wake"
}

test_approved_reminders_are_rate_limited() {
  local dir iso view out marker key now
  dir=$(make_case rate-limited)
  arm_check "$dir"
  iso=$(old_iso)
  view=$(printf 'OPEN\tabc123\tfalse\tAPPROVED\t%s\tabc123' "$iso")

  out=$(run_generated_check "$dir" "$view" 3600)
  assert_one_line "$out" "rate-limited first reminder"

  out=$(run_generated_check "$dir" "$view" 3600)
  [ -z "$out" ] || fail "rate limit allowed an immediate duplicate reminder: $out"

  marker="$dir/state/task-x1.pr-ready-reminded"
  key=$(cut -f2- "$marker")
  now=$(date '+%s')
  printf '%s\t%s\n' "$((now - 7200))" "$key" > "$marker"

  out=$(run_generated_check "$dir" "$view" 3600)
  assert_one_line "$out" "rate-limited repeat after window"
  pass "fm-pr-check: approved reminders are bounded by the repeat window"
}

test_approved_open_pr_reasserts_after_threshold
test_newer_commit_invalidates_stale_approval
test_merged_pr_keeps_existing_behavior
test_approved_reminders_are_rate_limited

echo "# all fm-pr-check tests passed"
