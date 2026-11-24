# shellcheck shell=bash disable=SC2154 # bin/screenshots sets home.
# The made-up state that bin/screenshots draws. bin/screenshots sources it with `home` set to a fresh folder
# and `sb` defined. `seed` writes the folder before sbd starts, and `seed_live` adds what only a running sbd
# takes, such as held permission prompts, Inbox cards, waits, and the group chat.
# Every name, repo, person, and account here is invented. Keep it that way, because the images are public.

# Each account is a folder with a .claude.json, as claude keeps one, and a .credentials.json whose token the
# fake usage server below knows.
accounts=(work personal oss)

seed() {
  mkdir -p "$home/worktrees" "$home/transcripts"
  local a
  for a in "${accounts[@]}"; do
    mkdir -p "$home/.claude-$a"
    jq -n --arg e "$a@example.com" '{oauthAccount: {emailAddress: $e, displayName: "Dev", planDisplayName: "Max"}}' \
      >"$home/.claude-$a/.claude.json"
    jq -n --arg t "token-$a" '{claudeAiOauth: {accessToken: $t, refreshToken: "r", expiresAt: 4102444800000}}' \
      >"$home/.claude-$a/.credentials.json"
  done
  export CLAUDE_CONFIG_DIR=$home/.claude-work

  # A pane launch passes --settings and stays up. sbd's own calls get a quick, empty answer, so the tick
  # never waits on them and `claude agents` never ends a turn.
  cat >"$home/bin/claude" <<'STUB'
#!/bin/sh
case " $* " in
*" --settings "*) exec sleep 86400 ;;
*" agents "*) echo '[]' ;;
esac
exit 0
STUB
  chmod +x "$home/bin/claude"

  start_usage_server

  jq -n --arg home "$home" --arg account "$CLAUDE_CONFIG_DIR" --argjson port "$(cat "$home/usage.port")" '{
    claude: "\($home)/bin/claude", shell: "/bin/sh", env: {CLAUDE_CONFIG_DIR: $account},
    claudeConfigDirs: ($ARGS.positional | map("\($home)/.claude-\(.)")), codexHomes: [],
    worktreeRoot: "\($home)/worktrees", repoRoots: ["\($home)/dev"],
    followupsFile: "\($home)/followups.md", idleStopSeconds: 86400, snapshotEvery: 0,
    github: {pollSeconds: 0, gh: "/usr/bin/false", url: "http://127.0.0.1:9"},
    depot: {enabled: false}, docket: {pollSeconds: 0, path: "/usr/bin/false"}, trunk: {path: "/usr/bin/false"},
    usage: {url: "http://127.0.0.1:\($port)/api/oauth/usage", pollSeconds: 0, keychain: false},
    triage: {enabled: false}
  }' --args "${accounts[@]}" >"$home/config.json"

  local r
  for r in payments-api search-service platform-tools web-app; do
    git init -q "$home/dev/$r"
    git -C "$home/dev/$r" remote add origin "https://github.com/acme/$r.git"
  done

  seed_db
}

# Answers the usage request that sbd makes for each account, by the account's token, with limits that reset
# relative to now.
start_usage_server() {
  local soon later
  soon=$(date -u -v+3H +%Y-%m-%dT%H:%M:%SZ)
  later=$(date -u -v+4d +%Y-%m-%dT%H:%M:%SZ)
  jq -n --arg soon "$soon" --arg later "$later" '
    def limits($s; $w): {limits: [
      {kind: "session", percent: $s, severity: "normal", resets_at: $soon},
      {kind: "weekly_all", percent: $w, resets_at: $later}]};
    {work: limits(42; 61), personal: limits(8; 23), oss: limits(0; 4)} | with_entries(.key |= "token-\(.)")' >"$home/usage.json"
  cat >"$home/usage.py" <<'PY'
import http.server, json, sys
usage = json.load(open(sys.argv[1]))
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        token = self.headers.get("Authorization", "").removeprefix("Bearer ")
        body = json.dumps(usage.get(token, {})).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        pass
server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[2], "w") as f:
    f.write(str(server.server_port))
server.serve_forever()
PY
  python3 -I "$home/usage.py" "$home/usage.json" "$home/usage.port" &
  for _ in $(seq 50); do [ -s "$home/usage.port" ] && return; sleep 0.1; done
  echo "the fake usage server did not start" >&2
  return 1
}

now=$(($(date +%s) * 1000))
ago() { echo $((now - $1 * 60000)); } # minutes ago, in ms
iso() { date -u -r $(((now / 1000) - $1 * 60)) +%Y-%m-%dT%H:%M:%SZ; }
q() { printf "'%s'" "${1//\'/\'\'}"; }

group() { # id name minutes-ago
  echo "INSERT INTO groups VALUES ($(q "$1"), $(q "$(jq -cn --arg id "$1" --arg n "$2" --argjson c "$(ago "$3")" \
    '{id: $id, name: $n, notes: [], created: $c}')"));" >>"$sql"
}
session() { # id name repo branch group-or-empty minutes-ago account
  local json
  json=$(jq -cn --arg id "$1" --arg n "$2" --arg repo "$home/dev/$3" --arg b "$4" --arg g "$5" \
    --arg acct "$home/.claude-${7:-work}" --argjson c "$(ago "$6")" --arg uuid "$(uuidgen | tr '[:upper:]' '[:lower:]')" \
    '{id: $id, name: $n, cwd: $repo, repo: $repo, branch: $b, claudeSessionId: $uuid, created: $c, started: true,
      done: false, waits: [], notes: [], claudeConfigDir: $acct, autoMode: true, shellClosed: true}
     + (if $g == "" then {} else {group: $g, placedByHand: true} end)')
  echo "INSERT INTO sessions VALUES ($(q "$1"), $(q "$json"));" >>"$sql"
  seeded=$((seeded + 1))
  event "$1" "$6" created '{}'
  event "$1" "$6" started '{}'
}
event() { # session minutes-ago kind data-json
  echo "INSERT INTO events (session, t, kind, data) VALUES ($(q "$1"), $(ago "$2"), $(q "$3"), $(q "$4"));" >>"$sql"
}
prompt() { event "$1" "$2" UserPromptSubmit "$(jq -cn --arg p "$3" '{prompt: $p}')"; }
tool() { # session minutes-ago tool input-json
  event "$1" "$2" PreToolUse "$(jq -cn --arg t "$3" --argjson i "$4" '{tool_name: $t, tool_input: $i, tool_use_id: "toolu_seed"}')"
}
reply() { event "$1" "$2" Stop "$(jq -cn --arg m "$3" '{last_assistant_message: $m}')"; }
pr() { # session minutes-ago repo number title branch extra-json
  event "$1" "$2" pr "$(jq -cn --arg repo "acme/$3" --argjson n "$4" --arg t "$5" --arg b "$6" --arg created "$(iso "$2")" \
    --argjson x "$7" '{pr: ({id: "PR_seed_\($n)", number: $n, url: "https://github.com/\($repo)/pull/\($n)", repo: $repo,
      title: $t, state: "OPEN", draft: false, head: $b, headSha: "0123456789abcdef0123456789abcdef01234567",
      base: "main", defaultBranch: "main", mergeable: "MERGEABLE", verdicts: [], reviews: [], labels: [],
      checks: "SUCCESS", reviewDecisionRead: true, reviewRequests: [], author: "dev", createdAt: $created} + $x)}')"
}
approved() { # minutes-ago
  jq -cn --arg at "$(iso "$1")" '{author: "dana", state: "APPROVED", submittedAt: $at} as $review
    | {reviewDecision: "APPROVED", verdicts: [$review], reviews: [$review]}'
}

seed_db() {
  sql=$home/seed.sql seeded=0
  cat >"$sql" <<'SQL'
CREATE TABLE sessions (id TEXT PRIMARY KEY, json TEXT NOT NULL);
CREATE TABLE events (id INTEGER PRIMARY KEY AUTOINCREMENT, session TEXT NOT NULL, t INTEGER NOT NULL, kind TEXT NOT NULL, data TEXT NOT NULL);
CREATE INDEX events_session ON events (session, id);
CREATE TABLE groups (id TEXT PRIMARY KEY, json TEXT NOT NULL);
BEGIN;
SQL
  group gpaymt Payments 600
  group gsrchx Search 500

  session spaya2 "Retry declined card charges" payments-api retry-declined-charges gpaymt 90
  prompt spaya2 88 "Retry declined card charges with exponential backoff"
  tool spaya2 3 Bash '{"command": "swift test --filter ChargeRetryTests"}'
  session sperm1 "Move invoices to the new ledger" payments-api invoice-ledger gpaymt 70
  prompt sperm1 68 "Move the invoice tables to the new ledger schema"
  session spayb3 "Verify refund webhook signatures" payments-api refund-webhook-signatures gpaymt 240 personal
  prompt spayb3 238 "Verify the signature on refund webhooks before we act on them"
  reply spayb3 150 "Opened PR #418 and asked dana for a review."
  pr spayb3 150 payments-api 418 "Verify refund webhook signatures" refund-webhook-signatures \
    '{"reviewDecision": "REVIEW_REQUIRED", "reviewRequests": ["dana"]}'
  session spayc4 "Round currency at the edge" payments-api currency-rounding gpaymt 400
  prompt spayc4 398 "Round currency amounts only when we display them"
  reply spayc4 300 "Opened PR #415. CI is green."
  pr spayc4 45 payments-api 415 "Round currency only at display time" currency-rounding "$(approved 45)"

  session swait1 "Typo-tolerant product search" search-service typo-tolerant-search gsrchx 120
  prompt swait1 118 "Make product search tolerate typos"
  reply swait1 12 "Pushed the trigram index to PR #4812. CI is running, and I'll pick it up when the checks finish."
  pr swait1 12 search-service 4812 "Tolerate typos in product search" typo-tolerant-search \
    '{"checks": "PENDING", "reviewDecision": "REVIEW_REQUIRED", "reviewRequests": ["dana"]}'
  session ssrch3 "Rebuild index without downtime" search-service zero-downtime-reindex gsrchx 60 personal
  prompt ssrch3 58 "Rebuild the search index without taking search offline"
  tool ssrch3 1 Edit '{"file_path": "Sources/Indexer/Rebuild.swift", "old_string": "a", "new_string": "b"}'
  session ssrch4 "Facet counts for filters" search-service facet-counts gsrchx 500
  prompt ssrch4 498 "Show result counts next to each filter"
  reply ssrch4 200 "PR #212 is approved and in the merge queue."
  pr ssrch4 20 search-service 212 "Show facet counts next to filters" facet-counts \
    "$(approved 60 | jq -c '. + {mergeQueue: true, inMergeQueue: true}')"

  session sdecid "Rate limits for the public API" web-app api-rate-limits "" 150
  prompt sdecid 148 "Add rate limits to the public API"
  reply sdecid 6 "The limiter works in staging. Before I open the PR I need three calls from you: where to keep the counters, what limit to start with, and how to tell clients they hit it."
  session sdevx2 "Bump CI runner image" platform-tools bump-ci-image "" 180 oss
  prompt sdevx2 178 "Move CI to the newer macOS runner image"
  reply sdevx2 30 "Updated the runner image and the cache keys. Want me to open a PR?"
  session sdevx3 "Document the search API" platform-tools search-api-docs gsrchx 300 oss
  prompt sdevx3 298 "Write reference docs for the search API"
  reply sdevx3 100 "Opened PR #77 for the docs team."
  pr sdevx3 100 platform-tools 77 "Document the search API" search-api-docs \
    '{"reviewDecision": "REVIEW_REQUIRED", "reviewRequests": ["docs-team"]}'
  session sweb2 "Dark mode for the settings page" web-app settings-dark-mode "" 45
  prompt sweb2 44 "Support dark mode on the settings page"
  tool sweb2 2 Edit '{"file_path": "src/settings/theme.css", "old_string": "a", "new_string": "b"}'

  echo "COMMIT;" >>"$sql"
  sqlite3 "$home/sb.db" <"$sql"
}

# A PermissionRequest hook that sbd holds open until its card gets an answer, as claude's hook does. The hook
# process keeps running in the background until the script ends it.
held_hook() { # session tool input-json
  jq -nc --arg t "$home/transcripts/$1.jsonl" --arg tool "$2" --argjson input "$3" \
    '{hook_event_name: "PermissionRequest", session_id: "seed", transcript_path: $t,
      permission_mode: "default", tool_name: $tool, tool_input: $input, cwd: "/tmp"}' |
    SB_SESSION_ID="$1" sb hook >/dev/null 2>&1 &
}

# Writes a transcript of user and assistant turns, one per argument, alternating from the user, and points the
# session at it, as claude's SessionStart hook does.
transcript() { # session text…
  local id=$1 file=$home/transcripts/$1.jsonl role=user minutes=$(($# * 3))
  shift
  : >"$file"
  for text in "$@"; do
    jq -nc --arg role "$role" --arg t "$text" --arg at "$(iso "$minutes")" \
      '{type: $role, message: {content: (if $role == "user" then $t else [{type: "text", text: $t}] end)}, timestamp: $at}' \
      >>"$file"
    if [ "$role" = user ]; then role=assistant; else role=user; fi
    minutes=$((minutes - 3))
  done
  jq -nc --arg t "$file" '{hook_event_name: "SessionStart", transcript_path: $t}' | SB_SESSION_ID="$id" sb hook
}

seed_live() {
  # A session that sbd can't decode drops out of every image without an error, so a short count fails here.
  local listed
  listed=$(sb ls --json | jq '[.[] | select(.kind == "work")] | length')
  [ "$listed" -eq "$seeded" ] || { echo "sbd lists $listed of the $seeded seeded sessions" >&2; return 1; }
  sb account use work >/dev/null
  sb usage >/dev/null

  held_hook sperm1 Bash '{"command": "bin/migrate --target ledger_v2 --tables invoices,invoice_lines", "description": "Run the ledger migration against the staging database"}'

  sb summary set sdecid >/dev/null <<'CARD'
{"title": "Three calls before the rate limit PR",
 "summary": "The token-bucket limiter passes its tests in staging.\nIt needs three calls from you before it opens the PR.",
 "decisions": [
  {"number": 1, "header": "Counters", "question": "Where should the limiter keep its counters?",
   "context": "Redis already runs next to the API. Memory is simpler but resets on deploy and differs per pod.",
   "options": [{"label": "Redis", "detail": "Shared across pods, survives deploys", "recommended": true},
               {"label": "In memory", "detail": "No new dependency, one bucket per pod"}]},
  {"number": 2, "header": "Limit", "question": "What limit should new API keys start with?",
   "options": [{"label": "600 requests a minute", "recommended": true}, {"label": "120 requests a minute"},
               {"label": "No limit until we measure"}]},
  {"number": 3, "header": "Response", "question": "How should a client learn that it hit the limit?",
   "options": [{"label": "429 with Retry-After", "recommended": true}, {"label": "429 with rate limit headers on every response"}]}]}
CARD
  sb summary set sdevx2 >/dev/null <<'CARD'
{"title": "Open a PR for the runner image?", "summary": "Updated the runner image and the cache keys.\nThe build passes on the new image.",
 "options": [{"label": "Open the PR", "action": "send", "message": "Yes, open the PR.", "recommended": true},
             {"label": "Something else", "action": "reply", "placeholder": "What should change?"}]}
CARD

  sb wait swait1 --kind ci --note "Resume when the checks on #4812 finish" >/dev/null
  sb wait swait1 "dana is out until Monday; ask her about the trigram threshold then" >/dev/null
  sb note swait1 --todo "Tell support that search tolerates typos once #4812 ships" >/dev/null
  sb note swait1 "Stacked on #4790, which adds the search analytics events" >/dev/null
  sb schedule swait1 --every 1h "Check the search error rate on the dashboard" >/dev/null

  chat=$(sb chat Payments --json | jq -r .id)
  transcript "$chat" \
    "How are the payments sessions doing?" \
    "Four sessions in Payments:

- [Round currency at the edge](switchboard://session/spayc4): #415 is approved and CI is green. It's ready to merge.
- [Verify refund webhook signatures](switchboard://session/spayb3): #418 waits on a review from dana.
- [Retry declined card charges](switchboard://session/spaya2): running the retry tests now.
- [Move invoices to the new ledger](switchboard://session/sperm1): waits on you to allow the staging migration.

Want me to merge #415?" \
    "Yes, merge it, and ask the refund session to ping dana if there's no review by 3pm." \
    "Done. I asked [Round currency at the edge](switchboard://session/spayc4) to merge #415, and set a wait on [Verify refund webhook signatures](switchboard://session/spayb3) that resumes it at 3pm to nudge dana."

  transcript "$(sb manager new --name "Morning review" --json | jq -r .id)" "What needs me first today?" \
    "Two sessions need you: [Move invoices to the new ledger](switchboard://session/sperm1) asks to run a migration, and [Rate limits for the public API](switchboard://session/sdecid) has three decisions for you."
}

