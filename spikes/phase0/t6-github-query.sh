#!/usr/bin/env bash
# Phase 0 test 6: one GraphQL query by node id for every tracked PR.
#
# Usage: t6-github-query.sh <command> [args]
#   collect                       writes the two PR sets: mine (the user's 100
#                                 most recently updated PRs, any state) and
#                                 open (100 open PostHog/posthog PRs by
#                                 anyone, most recently updated first)
#   run <set> <n> <variant> [reps] [chunk]
#                                 queries the first n PRs of a set, reps times
#                                 (default 5), T6_GAP seconds apart (default
#                                 2). With a chunk size,
#                                 each rep sends one request per chunk at once
#   resolve <set> <n> [reps]      looks up the PRs of the first n head branches
#                                 that a `run <set> 100 meta 3 10` recorded,
#                                 by repo and branch, in one aliased query
#   summary                       prints one line per run
#
# Variants:
#   full     PR state, rollup state, reviews, labels, and the first 5 and last
#            20 comments with their bodies
#   meta     the same, with each comment's author and edit times but no body
#   lean     meta without reviewRequests
#   bodies   the bodies of the trunk-io and deployment-status-posthog comments
#            that a meta response lists, by comment node id
#   probe-<group>
#            the base fields plus one group: mergeable, decision, labels,
#            opinions, reviews, requests, rollup, basepr, comments, or bodies
#
# Each run folder holds the requests, the first rep's responses, and one line
# per rep with its wall time, the slowest request's time, each request's HTTP
# status, and the total cost that rateLimit reports and response size. The
# token comes from `gh auth token`, so curl's times leave out gh's own start.
# T6_ROOT holds the PR sets and one folder per run.

set -euo pipefail

T6_ROOT="${T6_ROOT:?set T6_ROOT to a scratch folder}"
runs="$T6_ROOT/runs"
endpoint="${T6_ENDPOINT:-https://api.github.com/graphql}"

# The PR fields by group. A probe run times the base group plus one other.
declare -A group=(
  [base]='id number url title state isDraft createdAt updatedAt mergedAt closedAt headRefName headRefOid baseRefName
      repository { nameWithOwner defaultBranchRef { name } } author { login }'
  [mergeable]='mergeable'
  [decision]='reviewDecision'
  [labels]='labels(first: 20) { nodes { name } }'
  [opinions]='latestOpinionatedReviews(first: 20) { nodes { author { login } state submittedAt } }'
  [reviews]='reviews(last: 20) { nodes { author { login } state submittedAt } }'
  [requests]='reviewRequests(first: 20) { nodes { requestedReviewer { ... on User { login } ... on Bot { login } ... on Team { slug } } } }'
  [rollup]='commits(last: 1) { nodes { commit { oid statusCheckRollup { state } } } }'
  [basepr]='baseRef { associatedPullRequests(first: 1, states: MERGED) { nodes { number url mergedAt } } }'
  [comments]='firstComments: comments(first: 5) { totalCount nodes { id author { login } createdAt lastEditedAt includesCreatedEdit } }
      lastComments: comments(last: 20) { nodes { id author { login } createdAt lastEditedAt includesCreatedEdit } }'
  [bodies]='firstComments: comments(first: 5) { totalCount nodes { id author { login } createdAt lastEditedAt includesCreatedEdit body } }
      lastComments: comments(last: 20) { nodes { id author { login } createdAt lastEditedAt includesCreatedEdit body } }'
)
all_groups=(base mergeable decision labels opinions reviews requests rollup basepr)
# The meta groups without reviewRequests, which the attention rules don't use.
lean_groups=(base mergeable decision labels opinions reviews rollup basepr)

pr_query() { # pr_query <group>...
  local fields='' g
  for g in "$@"; do fields+="
      ${group[$g]}"; done
  cat <<EOF
query(\$ids: [ID!]!) {
  rateLimit { cost remaining resetAt }
  nodes(ids: \$ids) {
    ... on PullRequest {$fields
    }
  }
}
EOF
}

body_query='query($ids: [ID!]!) {
  rateLimit { cost remaining resetAt }
  nodes(ids: $ids) { ... on IssueComment { id lastEditedAt body } }
}'

search_ids() { # search_ids <search query>
  gh api graphql -f q="$1" -f query='query($q: String!) {
    search(query: $q, type: ISSUE, first: 100) { nodes { ... on PullRequest { id } } }
  }' --jq '[.data.search.nodes[].id]'
}

cmd_collect() {
  mkdir -p "$T6_ROOT" "$runs"
  search_ids "is:pr author:haacked sort:updated-desc" >"$T6_ROOT/ids-mine.json"
  search_ids "is:pr is:open repo:PostHog/posthog sort:updated-desc" >"$T6_ROOT/ids-open.json"
  for set in mine open; do echo "$set: $(jq length "$T6_ROOT/ids-$set.json") PRs"; done
}

# comment_ids <meta response>: the node ids of the comments whose bodies the
# poller needs.
comment_ids() {
  jq '[.data.nodes[] | (.firstComments.nodes + .lastComments.nodes)[]
    | select(.author.login == "trunk-io" or .author.login == "deployment-status-posthog") | .id] | unique' "$1"
}

now_s() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }

cmd_run() {
  local set=$1 n=$2 variant=$3 reps=${4:-5} query ids k
  local chunk=${5:-$n}
  local dir="$runs/$set-$n-$variant-c$chunk-$(date +%H%M%S)"
  mkdir -p "$dir"
  ids=$(jq -c ".[:$n]" "$T6_ROOT/ids-$set.json")
  case $variant in
  full) query=$(pr_query "${all_groups[@]}" bodies) ;;
  meta) query=$(pr_query "${all_groups[@]}" comments) ;;
  lean) query=$(pr_query "${lean_groups[@]}" comments) ;;
  probe-*)
    [ -n "${group[${variant#probe-}]:-}" ] || { echo "unknown group ${variant#probe-}" >&2; exit 1; }
    query=$(pr_query base "${variant#probe-}")
    ;;
  bodies)
    local meta
    meta=$(ls -d "$runs/$set-$n-meta-c$n-"* 2>/dev/null | tail -1 || true)
    [ -n "$meta" ] || { echo "run $set $n meta first, in one chunk" >&2; exit 1; }
    query=$body_query ids=$(comment_ids "$meta/response-1.json")
    chunk=$(jq length <<<"$ids")
    ;;
  *) echo "unknown variant $variant" >&2; exit 1 ;;
  esac
  local count chunks
  count=$(jq length <<<"$ids")
  chunks=$(((count + chunk - 1) / chunk))
  for ((k = 1; k <= chunks; k++)); do
    jq -n --arg q "$query" --argjson ids "$(jq -c ".[$(((k - 1) * chunk)):$((k * chunk))]" <<<"$ids")" \
      '{query: $q, variables: {ids: $ids}}' >"$dir/request-$k.json"
  done
  run_requests "$dir" "$chunks" "$reps" "$count"
}

# run_requests <dir> <chunks> <reps> <count>: sends request-<k>.json for each
# chunk at once, reps times, and records each rep in summary.txt.
run_requests() {
  local dir=$1 chunks=$2 reps=$3 count=$4
  local token i k
  token=$(gh auth token)
  echo "ids=$count chunks=$chunks" >"$dir/summary.txt"
  for ((i = 1; i <= reps; i++)); do
    local start end
    start=$(now_s)
    for ((k = 1; k <= chunks; k++)); do
      curl -sS -o "$dir/out-$k.json" -w '%{http_code} %{time_total} %{size_download}\n' \
        -H "Authorization: bearer $token" -X POST "$endpoint" --data @"$dir/request-$k.json" >"$dir/line-$k" &
    done
    wait
    end=$(now_s)
    local codes='' cost=0 bytes=0 slowest=0 code t size c
    for ((k = 1; k <= chunks; k++)); do
      read -r code t size <"$dir/line-$k"
      codes+="${codes:+,}$code"
      c=$(jq -r '.data.rateLimit.cost // 0' "$dir/out-$k.json" 2>/dev/null) || c=0
      cost=$((cost + c)) bytes=$((bytes + size))
      slowest=$(awk -v a="$slowest" -v b="$t" 'BEGIN { print (b > a ? b : a) }')
      if [ "$i" -eq 1 ]; then mv "$dir/out-$k.json" "$dir/response-$k.json"; else rm -f "$dir/out-$k.json"; fi
      rm -f "$dir/line-$k"
    done
    echo "rep=$i wall=$(awk -v a="$start" -v b="$end" 'BEGIN { printf "%.2f", b - a }') slowest=$slowest codes=$codes cost=$cost bytes=$bytes" |
      tee -a "$dir/summary.txt"
    [ "$i" -eq "$reps" ] || sleep "${T6_GAP:-2}"
  done
}

# Writes a request that looks up each branch's PRs by repo and head branch,
# then runs it as a one-chunk run.
cmd_resolve() {
  local set=$1 n=$2 reps=${3:-3} meta dir
  meta=$(ls -d "$runs/$set-100-meta-c10-"* 2>/dev/null | tail -1 || true)
  [ -n "$meta" ] || { echo "run $set 100 meta 3 10 first" >&2; exit 1; }
  dir="$runs/$set-$n-resolve-c$n-$(date +%H%M%S)"
  mkdir -p "$dir"
  jq -s --argjson n "$n" '[.[].data.nodes[] | select(. != null)] | .[:$n] | to_entries
    | map("  r\(.key): repository(owner: \(.value.repository.nameWithOwner | split("/")[0] | tojson), name: \(.value.repository.nameWithOwner | split("/")[1] | tojson)) {
    pullRequests(headRefName: \(.value.headRefName | tojson), first: 5, orderBy: {field: CREATED_AT, direction: DESC}) {
      nodes { id number state headRepositoryOwner { login } }
    }
  }") | {query: ("query {\n  rateLimit { cost remaining resetAt }\n" + join("\n") + "\n}")}' \
    "$meta"/response-*.json >"$dir/request-1.json"
  run_requests "$dir" 1 "$reps" "$n"
}

# Prints each run's id and chunk counts, its cost and size per rep, the range
# of its wall times, and the reps with a failed chunk.
cmd_summary() {
  for d in "$runs"/*/; do
    [ -f "$d/summary.txt" ] || continue
    awk -v run="$(basename "$d")" '
      /^ids=/ { for (i = 1; i <= NF; i++) { split($i, a, "="); h[a[1]] = a[2] } }
      /^rep=/ {
        for (i = 1; i <= NF; i++) { split($i, a, "="); r[a[1]] = a[2] }
        n++
        if (r["codes"] ~ /^(200,)*200$/) { ok++; cost = r["cost"]; bytes = r["bytes"]
          if (ok == 1 || r["wall"] < lo) lo = r["wall"]; if (r["wall"] > hi) hi = r["wall"] }
        else failed++
      }
      END { printf "%-32s ids=%-3s chunks=%-2s cost=%-2s bytes=%-8s wall %s s, %d of %d reps failed\n",
        run, h["ids"], h["chunks"], cost, bytes, (ok ? sprintf("%.2f-%.2f", lo, hi) : "-"), failed, n }' "$d/summary.txt"
  done
}

cmd=${1:-}
shift || true
case $cmd in
collect | run | resolve | summary) "cmd_$cmd" "$@" ;;
*)
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
  ;;
esac
