#!/usr/bin/env bash
# Behavioural tests for schedule.sh, run against a stubbed `curl` and real git repositories.
#
# Nothing here talks to Leed or mints a real OIDC token. What is covered is everything the script
# decides for itself: which commits form the release, how the request is built, how responses are
# handled, and which preconditions refuse to run. A real token against a real Leed is out of scope
# for CI and needs a live pipeline.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/schedule.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A git hook or a CI step can leave GIT_DIR / GIT_INDEX_FILE set, which silently redirects the
# fixture repositories below at the wrong repository.
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok   $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; echo "       $2"; }

# ---------------------------------------------------------------------------
# Stub curl. Behaviour is chosen by STUB_MODE; every request body is logged so tests can assert
# on exactly what the script sent.
# ---------------------------------------------------------------------------
mkdir -p "$WORK/bin"
cat > "$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
args="$*"
if [[ "$args" == *"api-version"* ]]; then echo '{"value":"stub.token"}'; exit 0; fi
out=""; body=""
for ((i = 1; i <= $#; i++)); do
  [[ "${!i}" == "-o" ]] && { j=$((i + 1)); out="${!j}"; }
  [[ "${!i}" == "-d" ]] && { j=$((i + 1)); body="${!j}"; }
done
echo "$body" >> "$STUB_LOG"
confirm="$(jq -r '.confirm' <<<"$body")"
case "${STUB_MODE:-ok}" in
  402)
    echo '{"error":"upgrade_required","message":"Growth plan required"}' > "$out"; echo 402; exit 0 ;;
esac
if [[ "$confirm" == "false" ]]; then
  echo '{"dryRun":true,"matched":1,"wouldSchedule":1,"wouldFail":0,"unmatchedSourceIds":[],"results":[]}' > "$out"
else
  n=$(cat "$STUB_COUNTER" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$STUB_COUNTER"
  case "${STUB_MODE:-ok}" in
    drain) if [[ $n -eq 1 ]]; then r=2; s=1; else r=0; s=2; fi
           echo "{\"dryRun\":false,\"scheduled\":$s,\"failed\":0,\"remaining\":$r,\"results\":[]}" > "$out" ;;
    stuck) echo '{"dryRun":false,"scheduled":0,"failed":1,"remaining":5,"results":[{"pageId":"p9","scheduled":false,"reason":"PUBLISHED, needs revise"}]}' > "$out" ;;
    *)     echo '{"dryRun":false,"scheduled":1,"failed":0,"remaining":0,"results":[]}' > "$out" ;;
  esac
fi
echo 200
STUB
chmod +x "$WORK/bin/curl"

# ---------------------------------------------------------------------------
# Fixture repositories.
# ---------------------------------------------------------------------------
git_commit() { git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "$1"; }

LINEAR="$WORK/linear"
git init -q "$LINEAR"
( cd "$LINEAR"
  for i in 1 2 3 4 5; do git_commit "c$i"; done
  git tag v1 HEAD~3
  git tag nightly-x HEAD~2
  git tag v2 HEAD~1 )

MERGE="$WORK/merge"
git init -q "$MERGE"
( cd "$MERGE"
  git_commit "base"
  base_branch="$(git symbolic-ref --short HEAD)"
  git checkout -q -b feature
  for i in 1 2 3; do git_commit "feat $i"; done
  git checkout -q "$base_branch"
  git_commit "unrelated"
  git -c user.email=t@t -c user.name=t merge -q --no-ff feature -m "merge feature" )

# ---------------------------------------------------------------------------
# Runner. Executes schedule.sh in a clean environment so this CI job's own GITHUB_* variables
# cannot leak in and change what the script detects.
# ---------------------------------------------------------------------------
run() {
  local dir="$1"; shift
  : > "$WORK/log"; rm -f "$WORK/counter"
  OUT="$( cd "$dir" && env -i HOME="$HOME" PATH="$WORK/bin:$PATH" \
      STUB_LOG="$WORK/log" STUB_COUNTER="$WORK/counter" \
      LEED_AUDIENCE="leed-cms:test" LEED_PUBLISH_AT="2030-01-01T00:00:00Z" "$@" \
      bash "$SCRIPT" 2>&1 )" && CODE=0 || CODE=$?
}
sent_count() { head -1 "$WORK/log" | jq '.sourceIds | length'; }
sent_field() { if [[ "$1" == -r ]]; then head -1 "$WORK/log" | jq -r "$2"; else head -1 "$WORK/log" | jq -c "$1"; fi; }

expect() {
  local name="$1" want_code="$2" want_text="$3"
  if [[ "$CODE" != "$want_code" ]]; then fail "$name" "exit $CODE, expected $want_code. Output: $OUT"; return; fi
  if [[ -n "$want_text" && "$OUT" != *"$want_text"* ]]; then fail "$name" "missing '$want_text'. Output: $OUT"; return; fi
  pass "$name"
}
expect_sent() {
  local name="$1" want="$2" got; got="$(sent_count)"
  if [[ "$got" == "$want" ]]; then pass "$name"; else fail "$name" "sent $got source ids, expected $want"; fi
}

echo "range resolution"
run "$LINEAR" LEED_OIDC_TOKEN=t GITHUB_REF_TYPE=tag GITHUB_REF_NAME=v2
expect "tag build uses the previous tag of any name" 0 "nightly-x..v2"
expect_sent "  ...and sends exactly that range" 1

run "$LINEAR" LEED_OIDC_TOKEN=t GITHUB_REF_TYPE=tag GITHUB_REF_NAME=v2 LEED_TAG_PATTERN='v*'
expect "tag-pattern skips a non-release tag between releases" 0 "v1..v2"
expect_sent "  ...and sends exactly that range" 2

run "$LINEAR" LEED_OIDC_TOKEN=t CI_COMMIT_TAG=v2 LEED_TAG_PATTERN='v*'
expect "GitLab's CI_COMMIT_TAG is detected the same way" 0 "v1..v2"

run "$LINEAR" LEED_OIDC_TOKEN=t GITHUB_REF_TYPE=tag GITHUB_REF_NAME=v1 LEED_TAG_PATTERN='v*'
expect "the first tag schedules all history up to it" 0 "all history up to v1"

run "$LINEAR" LEED_OIDC_TOKEN=t LEED_EVENT_BEFORE="$(git -C "$LINEAR" rev-parse HEAD~2)"
expect "a branch push uses the ref's previous value" 0 "previous value"
expect_sent "  ...and sends the two new commits" 2

run "$MERGE" LEED_OIDC_TOKEN=t LEED_MERGE_COMMIT="$(git -C "$MERGE" rev-parse HEAD)"
expect "merge-commit uses the merge's parents" 0 "parents of merge commit"
expect_sent "  ...and excludes the merge commit itself" 3

run "$MERGE" LEED_OIDC_TOKEN=t
expect "a merge at HEAD is the fallback when there is no previous value" 0 "merge commit at HEAD"

run "$MERGE" LEED_OIDC_TOKEN=t LEED_EVENT_BEFORE="$(git -C "$MERGE" rev-parse HEAD^1)"
expect "a valid previous value still takes precedence over the merge" 0 "previous value"
expect_sent "  ...and includes the merge commit" 4

run "$MERGE" LEED_OIDC_TOKEN=t LEED_MERGE_COMMIT="$(git -C "$MERGE" rev-parse HEAD^2)"
expect "a non-merge sha is refused as merge-commit" 1 "is not a merge commit"

run "$LINEAR" LEED_OIDC_TOKEN=t LEED_SINCE=0000000000000000000000000000000000000000
expect "the all-zero sha is named rather than reported as unresolvable" 1 "all-zero SHA"

run "$LINEAR" LEED_OIDC_TOKEN=t LEED_EVENT_BEFORE=0000000000000000000000000000000000000000
expect "a first push with nothing to diff refuses" 1 "first push to a new ref"

echo "source-ids"
run "$LINEAR" LEED_OIDC_TOKEN=t LEED_SOURCE_IDS='  aaa , bbb
ccc
aaa

  release-2030-01-01  '
expect "an explicit list is accepted" 0 "supplied source-ids list"
if [[ "$(sent_field .sourceIds)" == '["aaa","bbb","ccc","release-2030-01-01"]' ]]; then pass "  ...trimmed, deduplicated, blanks dropped, shape not validated"; else fail "  ...normalisation" "sent $(sent_field .sourceIds)"; fi

echo "request"
run "$LINEAR" LEED_OIDC_TOKEN=t LEED_SOURCE_IDS=aaa
if [[ "$(sent_field 'has("minimumStatus")')" == "false" ]]; then pass "minimumStatus is omitted by default, so the trust's ceiling applies"; else fail "minimumStatus omitted" "body: $(head -1 "$WORK/log")"; fi

run "$LINEAR" LEED_OIDC_TOKEN=t LEED_SOURCE_IDS=aaa LEED_MINIMUM_STATUS=approved
if [[ "$(sent_field .minimumStatus)" == '"approved"' ]]; then pass "minimumStatus is sent when set"; else fail "minimumStatus sent" "body: $(head -1 "$WORK/log")"; fi

run "$LINEAR" LEED_OIDC_TOKEN=t LEED_SOURCE_IDS=aaa
if [[ "$(sent_field .confirm)" == "false" ]]; then pass "a dry run is the default"; else fail "dry run default" "body: $(head -1 "$WORK/log")"; fi

run "$LINEAR" LEED_OIDC_TOKEN=t LEED_SOURCE_IDS=aaa
if [[ "$(sent_field .publishedAt)" == '"2030-01-01T00:00:00Z"' ]]; then pass "publish-at is sent as given"; else fail "publish-at as given" "body: $(head -1 "$WORK/log")"; fi

# The same GNU-then-BSD date the script uses, so the bounds are computed the way the script computes.
iso_in() { local t=$(( $(date -u +%s) + $1 )); date -u -d "@$t" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$t" +%Y-%m-%dT%H:%M:%SZ; }
low="$(iso_in 900)"
run "$LINEAR" LEED_OIDC_TOKEN=t LEED_SOURCE_IDS=aaa LEED_PUBLISH_AT=
high="$(iso_in 900)"
sent_at="$(sent_field -r .publishedAt)"
# Same fixed-width UTC format on both sides, so string order is time order.
if [[ ! "$sent_at" < "$low" && ! "$sent_at" > "$high" ]]; then pass "an empty publish-at defaults to 15 minutes after the job starts"; else fail "publish-at default" "sent $sent_at, expected $low..$high"; fi
expect "  ...and says so in the log" 0 "publishing 15 minutes from now, at ${sent_at}"

echo "responses"
run "$LINEAR" LEED_OIDC_TOKEN=t LEED_SOURCE_IDS=aaa LEED_DRY_RUN=false STUB_MODE=drain
expect "remaining pages are drained across repeated calls" 0 "0 remaining"

run "$LINEAR" LEED_OIDC_TOKEN=t LEED_SOURCE_IDS=aaa LEED_DRY_RUN=false STUB_MODE=stuck
expect "a call that makes no progress stops instead of looping" 1 "scheduled none"

run "$LINEAR" LEED_OIDC_TOKEN=t LEED_SOURCE_IDS=aaa STUB_MODE=402
expect "an HTTP error from Leed fails the job with its message" 1 "Growth plan required"

echo "preconditions"
run "$LINEAR" LEED_SOURCE_IDS=aaa
expect "no OIDC token available refuses with setup guidance" 1 "id-token: write"

# `::add-mask::<value>` is GitHub's instruction to redact a value from the log — the runner consumes
# the line rather than printing it. So the property is: masked on GitHub, and no GitHub-only
# workflow command emitted anywhere else, where it would print verbatim.
run "$LINEAR" LEED_OIDC_TOKEN=secret-token LEED_SOURCE_IDS=aaa GITHUB_ACTIONS=true
if [[ "$OUT" == *"::add-mask::secret-token"* ]]; then pass "the token is masked on GitHub"; else fail "token masked on GitHub" "output: $OUT"; fi

run "$LINEAR" LEED_OIDC_TOKEN=secret-token LEED_SOURCE_IDS=aaa
if [[ "$OUT" != *"::"* && "$OUT" != *"secret-token"* ]]; then pass "off GitHub, no workflow commands are emitted and the token never appears"; else fail "no GitHub commands off GitHub" "output: $OUT"; fi

SHALLOW="$WORK/shallow"
git clone -q --depth 1 "file://$LINEAR" "$SHALLOW" 2>/dev/null
run "$SHALLOW" LEED_OIDC_TOKEN=t LEED_SINCE=HEAD
expect "a shallow clone refuses rather than scheduling an empty release" 1 "shallow clone"

run "$SHALLOW" LEED_OIDC_TOKEN=t LEED_SOURCE_IDS=aaa
expect "source-ids works in a shallow clone, since git is not consulted" 0 "supplied source-ids list"

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
