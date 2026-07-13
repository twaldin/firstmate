#!/usr/bin/env bash
# Tests for bin/fm-pr-ledger.sh.
#
# The regression target is the canonical reducer invariant: one owner row per PR
# URL, with stage handoff refreshed atomically and idempotently from live gh-axi
# state rather than from hand-maintained dashboard prose.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LEDGER="$ROOT/bin/fm-pr-ledger.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-ledger-tests)

make_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$dir/data" "$fakebin"
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr view")
    cat "$FM_TEST_GH_AXI_VIEW"
    exit 0
    ;;
esac
exit 1
SH
  chmod +x "$fakebin/gh-axi"
  printf '%s\n' "$dir"
}

write_view_review() {  # <path>
  cat > "$1" <<'EOF'
pull_request:
  number: 9
  title: "Ready stack"
  state: open
  author: example
  draft: no
  merged: no
  checks: "4 passed, 0 failed, 4 total"
  reviews: []
EOF
}

write_view_approved() {  # <path>
  cat > "$1" <<'EOF'
pull_request:
  number: 9
  title: "Ready stack"
  state: open
  author: example
  draft: no
  merged: no
  checks: "4 passed, 0 failed, 4 total"
  reviews:
    - state: APPROVED
      author: Tim
EOF
}

run_ledger_write() {  # <case-dir> <out-path>
  local dir=$1 out=$2
  FM_HOME="$dir/home" \
  FM_STATE_OVERRIDE="$dir/state" \
  FM_DATA_OVERRIDE="$dir/data" \
  FM_TEST_GH_AXI_LOG="$dir/gh-axi.log" \
  FM_TEST_GH_AXI_VIEW="$dir/view.txt" \
  PATH="$dir/fakebin:$PATH" \
    "$LEDGER" --write "$out" >/dev/null
}

test_owner_and_stage_handoff_are_atomic_and_idempotent() {
  local dir out stage owner count gh_calls
  dir=$(make_case handoff)
  out="$dir/data/pr-ledger.json"
  : > "$dir/gh-axi.log"
  fm_write_meta "$dir/state/a-task.meta" \
    "window=fm-a-task" \
    "kind=ship" \
    "pr=https://github.com/example/repo/pull/9"
  fm_write_meta "$dir/state/b-task.meta" \
    "window=fm-b-task" \
    "kind=ship" \
    "pr=https://github.com/example/repo/pull/9"
  printf 'working: review in progress\n' > "$dir/state/a-task.status"
  write_view_review "$dir/view.txt"

  run_ledger_write "$dir" "$out"
  count=$(jq '.records | length' "$out")
  [ "$count" = 1 ] || fail "ledger wrote $count rows for one PR URL"
  owner=$(jq -r '.records[0].owner.task_id' "$out")
  [ "$owner" = a-task ] || fail "ledger did not pick the deterministic single owner: $owner"
  stage=$(jq -r '.records[0].stage' "$out")
  [ "$stage" = review ] || fail "initial stage was not review: $stage"

  write_view_approved "$dir/view.txt"
  run_ledger_write "$dir" "$out"
  count=$(jq '.records | length' "$out")
  [ "$count" = 1 ] || fail "ledger duplicated the row during stage handoff"
  owner=$(jq -r '.records[0].owner.task_id' "$out")
  [ "$owner" = a-task ] || fail "ledger owner changed during stage handoff: $owner"
  stage=$(jq -r '.records[0].stage' "$out")
  [ "$stage" = approved-awaiting-Tim ] || fail "approved live state did not hand off stage: $stage"

  run_ledger_write "$dir" "$out"
  count=$(jq '.records | length' "$out")
  [ "$count" = 1 ] || fail "idempotent refresh duplicated the row"
  stage=$(jq -r '.records[0].stage' "$out")
  [ "$stage" = approved-awaiting-Tim ] || fail "idempotent refresh changed stage unexpectedly: $stage"
  gh_calls=$(grep -c '^pr view 9 -R example/repo --reviews$' "$dir/gh-axi.log" || true)
  [ "$gh_calls" = 3 ] || fail "ledger did not refresh from gh-axi on each run: $gh_calls calls"
  pass "fm-pr-ledger: owner and stage handoff are atomic, deterministic, and idempotent"
}

test_owner_and_stage_handoff_are_atomic_and_idempotent

echo "# all fm-pr-ledger tests passed"
