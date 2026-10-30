#!/usr/bin/env bash
# Phase 0 test 7: Trunk merge queue status.
#
# Usage: t7-trunk.sh <command> [args]
#   mine [projects folder]    copies the output of every `trunk merge status`
#                             call in Claude Code transcripts into a new run
#                             folder (default ~/.claude/projects)
#   candidates                prints PR numbers worth checking: the newest
#                             open PRs, PRs whose Trunk comment says they run
#                             tests, and recently merged stacks with their
#                             top PRs
#   record <pr>...            runs `trunk merge status <pr>` for each PR and
#                             reads the PR's comments right after it, into a
#                             new run folder
#   compare <run>             parses each output in a run with the parsers in
#                             SwitchboardCore. For a recorded PR, it also
#                             prints whether both parsers say that Trunk
#                             holds the PR
#
# trunk reads the repo from the checkout it runs in. T7_REPO names a
# checkout of the repo whose queue the run reads. T7_ROOT holds one folder
# per run. record needs `trunk login`.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
T7_ROOT="${T7_ROOT:?set T7_ROOT to a scratch folder}"
T7_REPO="${T7_REPO:-$HOME/dev/posthog/posthog}"
owner_repo="${T7_OWNER_REPO:-PostHog/posthog}"
trunk="${T7_TRUNK:-$(ls -d "$HOME"/.cache/trunk/cli/*/trunk | sort -V | tail -1)}"
# shellcheck source=lib/pty.sh
. "$here/lib/pty.sh"

search() { # search <query> <count>
  gh api graphql -f q="repo:$owner_repo is:pr $1" -F n="$2" \
    -f query='query($q: String!, $n: Int!) { search(query: $q, type: ISSUE, first: $n) {
      nodes { ... on PullRequest { number } } } }' --jq '.data.search.nodes[].number'
}

cmd_mine() {
  run="$T7_ROOT/mine-$(date +%H%M%S)"
  mkdir -p "$run"
  python3 -I "$here/lib/t7-mine.py" "${1:-$HOME/.claude/projects}" "$run" | tee "$run/summary.txt"
  echo "$run"
}

cmd_candidates() {
  {
    search "is:open sort:updated-desc" 20
    search '"Running tests" in:comments is:open sort:updated-desc' 10
    # A PR below the top of a stack gets this reply. Its text names the top PR.
    for pr in $(search '"queued for merge as part of" in:comments sort:updated-desc' 4); do
      echo "$pr"
      gh api "repos/$owner_repo/issues/$pr/comments" --paginate \
        --jq '.[] | select(.user.login == "trunk-io[bot]") | .body
          | capture("^This pull request is queued for merge as part of \\[(?<top>[0-9]+)\\]").top' | tail -1
    done
  } | awk '!seen[$0]++'
}

comments_query='query($owner: String!, $repo: String!, $pr: Int!, $endCursor: String) {
  repository(owner: $owner, name: $repo) { pullRequest(number: $pr) {
    state
    comments(first: 100, after: $endCursor) {
      pageInfo { hasNextPage endCursor }
      nodes { id author { __typename login } createdAt lastEditedAt body includesCreatedEdit }
    } } } }'

cmd_record() {
  [ $# -gt 0 ] || {
    echo "record needs PR numbers" >&2
    exit 1
  }
  run="$T7_ROOT/record-$(date +%H%M%S)"
  mkdir -p "$run"
  echo "trunk: $trunk ($("$trunk" --version 2>/dev/null | head -1))" | tee "$run/summary.txt"
  for pr in "$@"; do
    start=$(now_ms)
    code=0
    (cd "$T7_REPO" && "$trunk" merge status "$pr" >"$run/$pr.trunk.txt" 2>&1) || code=$?
    end=$(now_ms)
    gh api graphql --paginate -F owner="${owner_repo%/*}" -F repo="${owner_repo#*/}" -F pr="$pr" \
      -f query="$comments_query" | jq -s '{pr: .[0].data.repository.pullRequest | del(.comments),
        comments: [.[].data.repository.pullRequest.comments.nodes[]]}' >"$run/$pr.json"
    jq -n --argjson start "$start" --argjson ms "$((end - start))" --argjson exit "$code" \
      '{start: $start, ms: $ms, exit: $exit}' >"$run/$pr.meta.json"
    echo "#$pr trunk $((end - start)) ms, exit $code" | tee -a "$run/summary.txt"
  done
  echo "$run"
}

cmd_compare() {
  run="${1:?compare needs a run folder}"
  bin="$T7_ROOT/t7-compare"
  swiftc -O -parse-as-library -o "$bin" "$root"/Sources/SwitchboardCore/*.swift "$here/lib/t7-compare.swift"
  "$bin" "$run" | tee "$run/compare.tsv"
}

cmd="${1:-}"
shift || true
case "$cmd" in
  mine) cmd_mine "$@" ;;
  candidates) cmd_candidates "$@" ;;
  record) cmd_record "$@" ;;
  compare) cmd_compare "$@" ;;
  *)
    sed -n '2,22p' "$0" >&2
    exit 1
    ;;
esac
