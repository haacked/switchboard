#!/usr/bin/env bash
# Phase 0 test 8: deploys.
#
# Usage: t8-deploys.sh <command> [args]
#   comments <since>          tallies the deploy comment rows on every
#                             PostHog/posthog PR merged since <since>
#                             (YYYY-MM-DD), and lists the PRs without one
#   service <service> <pr>    reads state/<service>.yaml on PostHog/charts
#                             main, compares each stage's commit with the
#                             PR's merge commit, and prints the sync jobs of
#                             the charts run that deployed each stage
#   apps <stage> <service>... lists the ArgoCD apps that charts syncs for
#                             each service in dev, prod-us, or prod-eu
#   argocd <app>...           prints each ArgoCD app's synced revision,
#                             sync status, health, and last operation
#
# The commands only read. They call GitHub through gh. `argocd` needs an
# ArgoCD login, and the stock `argocd login --sso` fails against PostHog's
# Cognito client (see Phase 0 test 8). `apps` runs charts' scripts/argo/sync_apps.py on an
# archive of origin/main from CHARTS_DIR, which defaults to
# ~/dev/posthog/charts. T8_ROOT holds one folder per run.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/pty.sh
. "$here/lib/pty.sh"

T8_ROOT="${T8_ROOT:?set T8_ROOT to a scratch folder}"
CHARTS_DIR="${CHARTS_DIR:-$HOME/dev/posthog/charts}"

new_run() {
  dir="$T8_ROOT/runs/$1-$(date +%H%M%S)"
  mkdir -p "$dir"
  echo "run folder: $dir"
}

cmd_comments() {
  local since=$1 after="" page=1
  new_run comments
  while :; do
    gh api graphql -f q="repo:PostHog/posthog is:pr is:merged merged:>=$since" ${after:+-f after="$after"} -f query='
      query($q: String!, $after: String) {
        rateLimit { cost remaining }
        search(query: $q, type: ISSUE, first: 100, after: $after) {
          pageInfo { hasNextPage endCursor }
          nodes { ... on PullRequest { number mergedAt baseRefName mergeCommit { oid }
            comments(last: 30) { nodes { author { login } body } } } }
        }
      }' >"$dir/page$page.json"
    after=$(jq -r '.data.search.pageInfo | if .hasNextPage then .endCursor else "" end' "$dir/page$page.json")
    [ -n "$after" ] || break
    page=$((page + 1))
  done
  # GraphQL names the bot deployment-status-posthog, and REST adds [bot]. The marker is the same in both.
  jq -s '[.[].data.search.nodes[]] | map({number, mergedAt, base: .baseRefName,
      comment: ([.comments.nodes[].body | select(startswith("<!-- deploy-notify-bot -->"))] | first)})' \
    "$dir"/page*.json >"$dir/prs.json"
  echo "merged PRs: $(jq length "$dir/prs.json"), with a deploy comment: $(jq '[.[] | select(.comment)] | length' "$dir/prs.json")"
  echo "rows (environment, status, time, run link):"
  jq -r '.[].comment // empty | split("\n")[] | select(startswith("| **")) | split("|") | map(gsub("^ +| +$"; ""))
      | "\(.[1]) \(.[2]) \(if .[3] == "" then "-" else "time" end) \(if .[4] == "" then "-" else "link" end)"' \
    "$dir/prs.json" | sort | uniq -c
  echo "without a deploy comment:"
  jq -r '.[] | select(.comment == null) | "  #\(.number) merged \(.mergedAt) into \(.base)"' "$dir/prs.json"
}

# Prints compare/<deployed>...<merge>: the status, the time, and the size.
compare() {
  local repo=$1 deployed=$2 merge=$3 start out
  start=$(now_ms)
  out=$(gh api "repos/$repo/compare/$deployed...$merge?per_page=1")
  echo "  compare ${deployed:0:8}...${merge:0:8}: $(jq -r .status <<<"$out")," \
    "$(($(now_ms) - start)) ms, $(printf '%s' "$out" | wc -c | tr -d ' ') bytes"
}

# Prints the sync jobs of the charts run on the commit "deploy <service> from <repo>@<commit>".
# $dir/state-commits.json holds the last 50 commits of state/<service>.yaml.
sync_jobs() {
  local service=$1 repo=$2 commit=$3 charts_sha run
  charts_sha=$(jq -r --arg title "deploy $service from $repo@$commit" \
    '[.[] | select(.commit.message | startswith($title))][0].sha // empty' "$dir/state-commits.json")
  if [ -z "$charts_sha" ]; then
    echo "  no deploy commit for ${commit:0:8} in the last 50 commits of state/$service.yaml"
    return
  fi
  run=$(gh api "repos/PostHog/charts/actions/workflows/state-deploy.yml/runs?head_sha=$charts_sha&per_page=1" \
    --jq '.workflow_runs[0].id // empty')
  echo "  charts commit ${charts_sha:0:11}, run https://github.com/PostHog/charts/actions/runs/$run"
  [ -n "$run" ] || return 0
  gh api "repos/PostHog/charts/actions/runs/$run/jobs?per_page=100" >"$dir/jobs-$run.json"
  jq -r '.jobs[] | select(.name | test("ArgoCD Sync|Check Posthog Deployment"))
      | "    \(.status)/\(.conclusion // "-") \(.started_at // "-") \(.completed_at // "-") \(.name)"' "$dir/jobs-$run.json"
}

cmd_service() {
  local service=$1 pr=$2 merge repo
  new_run "service-$service"
  merge=$(gh pr view "$pr" -R PostHog/posthog --json mergeCommit --jq .mergeCommit.oid)
  gh api "repos/PostHog/charts/contents/state/$service.yaml" --jq .content | base64 -d >"$dir/state.yaml"
  gh api "repos/PostHog/charts/commits?path=state/$service.yaml&per_page=50" >"$dir/state-commits.json"
  repo=$(yq ".state.\"$service\".deploy_info.repository" "$dir/state.yaml")
  echo "PR #$pr merge commit $merge; $service builds from $repo"
  local stage image info commit dev_commit=""
  for stage in dev prod; do
    image=$(yq ".state.\"$service\".image.$stage" "$dir/state.yaml")
    info=$(yq ".state.\"$service\".deploy_info.$stage.sha" "$dir/state.yaml")
    echo "$stage: image $image, deploy_info $info"
    commit=$(sed -nE 's/^(sha-)?([0-9a-f]{40})(@.*)?$/\2/p' <<<"$image")
    commit=${commit:-$info}
    if [ "$commit" = null ] || [ -z "$commit" ]; then
      echo "  no commit"
      continue
    fi
    if [ "$commit" = "$dev_commit" ]; then
      echo "  the same commit as dev"
      continue
    fi
    dev_commit=$commit
    compare "$repo" "$commit" "$merge"
    sync_jobs "$service" "$repo" "$commit"
  done
}

cmd_apps() {
  local stage=$1
  shift
  new_run "apps-$stage"
  git -C "$CHARTS_DIR" fetch -q origin main
  mkdir "$dir/charts"
  git -C "$CHARTS_DIR" archive origin/main scripts/argo argocd state | tar -x -C "$dir/charts"
  (cd "$dir/charts" && python3 scripts/argo/sync_apps.py state-apps-batch --repo-root . --stage "$stage" --deploy-targets "$@") |
    tee "$dir/apps.tsv"
  rm -rf "$dir/charts"
}

cmd_argocd() {
  new_run argocd
  local app start
  for app in "$@"; do
    start=$(now_ms)
    argocd app get "$app" -o json >"$dir/$app.json"
    echo "$app ($(($(now_ms) - start)) ms):"
    jq -r '"  revision \(.status.sync.revision), sync \(.status.sync.status), health \(.status.health.status)",
      "  last operation \(.status.operationState.phase // "-") at \(.status.operationState.finishedAt // "-") for \(.status.operationState.syncResult.revision // "-")",
      "  manifest-generate-paths \(.metadata.annotations["argocd.argoproj.io/manifest-generate-paths"] // "-")"' "$dir/$app.json"
  done
}

command=${1:-}
shift || true
case "$command" in
  comments | service | apps | argocd) "cmd_$command" "$@" ;;
  *)
    awk 'NR > 2 && !/^#/ { exit } NR > 2' "$0"
    exit 1
    ;;
esac
