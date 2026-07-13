#!/usr/bin/env bash
# fm-pr-ledger.sh - refresh the canonical PR lifecycle ledger.
#
# The ledger is machine-readable generated state, not hand-maintained prose.
# It derives one owner row per recorded PR URL from state/<id>.meta and refreshes
# each row from live GitHub state via gh-axi.
#
# Schema owner: docs/pr-lifecycle-ledger.md.
#
# Usage:
#   fm-pr-ledger.sh [--write [path]]
#   fm-pr-ledger.sh --json
#
# Default writes atomically to data/pr-ledger.json and prints the path.
# --json prints the generated object without writing.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
OUT="${FM_PR_LEDGER_PATH:-$DATA/pr-ledger.json}"

usage() {
  sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

MODE='write'
case "${1:-}" in
  '' ) ;;
  --json) MODE='json'; shift ;;
  --write)
    MODE='write'
    shift
    [ "${1:-}" = "" ] || { OUT=$1; shift; }
    ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
[ "$#" -eq 0 ] || { usage >&2; exit 2; }

command -v jq >/dev/null 2>&1 || { echo "fm-pr-ledger: jq not found" >&2; exit 1; }
command -v gh-axi >/dev/null 2>&1 || { echo "fm-pr-ledger: gh-axi not found" >&2; exit 1; }

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-pr-ledger.XXXXXX")
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT
NDJSON="$TMP_DIR/records.ndjson"
SEEN="$TMP_DIR/seen"
: > "$NDJSON"
: > "$SEEN"

meta_value() {  # <meta-file> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

last_nonempty_line() {  # <file>
  [ -f "$1" ] || return 1
  grep -v '^[[:space:]]*$' "$1" 2>/dev/null | tail -1
}

parse_pr_url() {  # <url> -> "<owner/repo>\t<number>"
  printf '%s\n' "$1" \
    | sed -nE 's#^https://github[.]com/([^/]+)/([^/]+)/pull/([0-9]+)/?$#\1/\2\t\3#p'
}

strip_outer_quotes() {
  local value=$1
  value=${value#\"}
  value=${value%\"}
  printf '%s\n' "$value"
}

view_field() {  # <field> <view-text>
  local field=$1
  sed -nE "s/^[[:space:]]*$field:[[:space:]]*//p" | head -1 | while IFS= read -r v; do
    strip_outer_quotes "$v"
  done
}

view_has_approval() {  # <view-text on stdin>
  grep -Eiq '^[[:space:]]*(-[[:space:]]*)?(state|review):[[:space:]]*"?APPROVED"?([[:space:]]|$)|^[[:space:]]*reviews:.*(APPROVED|approved)'
}

checks_are_build_blocked() {  # <checks-summary>
  local checks=$1
  case "$checks" in
    *pending*|*Pending*|*queued*|*Queued*) return 0 ;;
    *failed*|*Failed*)
      case "$checks" in *"0 failed"*|*"0 Failed"*) return 1 ;; esac
      return 0
      ;;
  esac
  return 1
}

derive_stage() {  # <state> <merged> <draft> <checks> <approved:0|1> <status-line>
  local state=$1 merged=$2 draft=$3 checks=$4 approved=$5 status=$6 lc
  lc=$(printf '%s\n' "$status" | tr '[:upper:]' '[:lower:]')
  case "$merged:$state" in
    yes:*|true:*|*:merged|*:MERGED) printf 'Done\n'; return 0 ;;
  esac
  case "$state" in
    closed|CLOSED) printf 'Closed\n'; return 0 ;;
  esac
  case "$lc" in
    *fallout*) printf 'fallout\n'; return 0 ;;
    *retro*) printf 'retro\n'; return 0 ;;
    *deploy*) printf 'deploy\n'; return 0 ;;
    *merge\ queue*|*graphite*|*\ mq\ *) printf 'MQ\n'; return 0 ;;
  esac
  if [ "$approved" = 1 ] && [ "$draft" != yes ] && [ "$draft" != true ]; then
    printf 'approved-awaiting-Tim\n'
    return 0
  fi
  case "$lc" in
    *needs-decision*|*waiting*human*|*waiting*tim*|*waiting*reviewer*)
      printf 'waiting-named-human\n'
      return 0
      ;;
  esac
  if [ "$draft" = yes ] || [ "$draft" = true ] || checks_are_build_blocked "$checks"; then
    printf 'build\n'
    return 0
  fi
  printf 'review\n'
}

append_record() {  # <task-id> <meta> <pr-url>
  local task=$1 meta=$2 pr_url=$3 parsed repo number view view_ok=0
  local title state merged draft checks approved=0 status_path status_line stage
  parsed=$(parse_pr_url "$pr_url")
  [ -n "$parsed" ] || return 0
  IFS="$(printf '\t')" read -r repo number <<EOF_PARSED
$parsed
EOF_PARSED
  if view=$(gh-axi pr view "$number" -R "$repo" --reviews 2>/dev/null); then
    view_ok=1
  else
    view=
  fi
  title=$(printf '%s\n' "$view" | view_field title)
  state=$(printf '%s\n' "$view" | view_field state)
  merged=$(printf '%s\n' "$view" | view_field merged)
  draft=$(printf '%s\n' "$view" | view_field draft)
  checks=$(printf '%s\n' "$view" | view_field checks)
  if printf '%s\n' "$view" | view_has_approval; then
    approved=1
  fi
  status_path="$STATE/$task.status"
  status_line=$(last_nonempty_line "$status_path" || true)
  stage=$(derive_stage "$state" "$merged" "$draft" "$checks" "$approved" "$status_line")
  jq -n \
    --arg pr_url "$pr_url" \
    --arg repo "$repo" \
    --arg number "$number" \
    --arg task "$task" \
    --arg meta_path "$meta" \
    --arg status_path "$status_path" \
    --arg status_line "$status_line" \
    --arg stage "$stage" \
    --arg title "$title" \
    --arg state "$state" \
    --arg merged "$merged" \
    --arg draft "$draft" \
    --arg checks "$checks" \
    --argjson approved "$approved" \
    --argjson view_available "$view_ok" \
    '{
      pr_url:$pr_url,
      repo:$repo,
      number:($number|tonumber),
      owner:{task_id:$task,meta_path:$meta_path,status_path:$status_path},
      stage:$stage,
      title:$title,
      status_line:$status_line,
      live:{
        available:$view_available,
        state:$state,
        merged:$merged,
        draft:$draft,
        checks:$checks,
        approved_review:$approved
      }
    }' >> "$NDJSON"
}

while IFS= read -r meta; do
  [ -n "$meta" ] || continue
  task=$(basename "$meta")
  task=${task%.meta}
  pr_url=$(meta_value "$meta" pr)
  [ -n "$pr_url" ] || continue
  if grep -Fx -- "$pr_url" "$SEEN" >/dev/null 2>&1; then
    continue
  fi
  printf '%s\n' "$pr_url" >> "$SEEN"
  append_record "$task" "$meta" "$pr_url"
done < <(find "$STATE" -maxdepth 1 -type f -name '*.meta' 2>/dev/null | sort)

GENERATED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
LEDGER=$(
  jq -s \
    --arg generated_at "$GENERATED_AT" \
    --arg fm_home "$FM_HOME" \
    --arg state "$STATE" \
    '{
      schema:"fm-pr-ledger.v1",
      generated_at:$generated_at,
      fm_home:$fm_home,
      state_path:$state,
      stages:["build","review","waiting-named-human","approved-awaiting-Tim","MQ","deploy","fallout","retro","Done","Closed"],
      records:.
    }' "$NDJSON"
)

if [ "$MODE" = json ]; then
  printf '%s\n' "$LEDGER"
  exit 0
fi

mkdir -p "$(dirname "$OUT")"
TMP_OUT=$(mktemp "$OUT.tmp.XXXXXX") || { echo "fm-pr-ledger: could not create temp output" >&2; exit 1; }
printf '%s\n' "$LEDGER" > "$TMP_OUT"
mv -f "$TMP_OUT" "$OUT"
printf 'ledger: wrote %s\n' "$OUT"
