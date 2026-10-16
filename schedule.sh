#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Leed, Inc.
# SPDX-License-Identifier: MIT
# Schedule a Leed content release from the commits in a range.
#
# Kept as a separate file rather than inlined in `action.yml` so it can be linted, tested and
# read as a script. The GitLab template runs a byte-identical body — see ../gitlab-template.
set -euo pipefail

: "${LEED_AUDIENCE:?audience is required}"
LEED_PUBLISH_AT="${LEED_PUBLISH_AT:-}"
LEED_UNTIL="${LEED_UNTIL:-HEAD}"
LEED_SINCE="${LEED_SINCE:-}"
# An explicit list, if the caller has one. Whitespace- or comma-separated, so a newline-delimited
# file, a `git log` capture, or a comma list from a release tool all work unchanged.
LEED_SOURCE_IDS="${LEED_SOURCE_IDS:-}"
# Which tags count as releases when auto-detecting the previous one. `v*` skips a `nightly-…` or
# `build-123` tag that happens to sit between two releases.
LEED_TAG_PATTERN="${LEED_TAG_PATTERN:-*}"
# A merge commit whose second parent's history IS the release — the shape of a
# "merging to main is our release" workflow. Its parents give the range directly, so this works
# for a re-run or a manual dispatch long after the merge, when no "previous ref value" exists.
LEED_MERGE_COMMIT="${LEED_MERGE_COMMIT:-}"
# The ref's previous value on a push. GitHub has it only as a context, so the action passes it in;
# GitLab exports CI_COMMIT_BEFORE_SHA itself.
LEED_EVENT_BEFORE="${LEED_EVENT_BEFORE:-${CI_COMMIT_BEFORE_SHA:-}}"
# The tag being built, if any. GitHub sets REF_NAME + REF_TYPE; GitLab sets CI_COMMIT_TAG.
if [ -n "${CI_COMMIT_TAG:-}" ]; then
  LEED_TAG="${CI_COMMIT_TAG}"
elif [ "${GITHUB_REF_TYPE:-}" = "tag" ]; then
  LEED_TAG="${GITHUB_REF_NAME:-}"
else
  LEED_TAG=""
fi

ZERO_SHA_RE='^0{7,40}$'
ALL_FROM_ROOT=false
LEED_BASE_URL="${LEED_BASE_URL:-https://app.leed.ai}"
LEED_DRY_RUN="${LEED_DRY_RUN:-true}"
LEED_FAIL_ON_UNMATCHED="${LEED_FAIL_ON_UNMATCHED:-false}"
LEED_MINIMUM_STATUS="${LEED_MINIMUM_STATUS:-}"

ENDPOINT="${LEED_BASE_URL%/}/api/page/schedule-by-source"

# Leed's own request-body cap. A release with more commits than this is split across calls; each
# call carries the same publishedAt, so the pages still land in one slot.
MAX_SOURCE_IDS=1000

# GitHub understands ::error:: / ::add-mask:: workflow commands; GitLab does not, and would print
# them verbatim. One script, two hosts, so the annotation style is chosen at run time.
if [ "${GITHUB_ACTIONS:-}" = "true" ]; then ERR="::error::"; else ERR="ERROR: "; fi
# `mapfile` is bash 4+, and macOS still ships bash 3.2 as /bin/bash. Reading lines into an array
# this way works on both, so the script does not depend on which bash a runner puts on PATH.
read_lines_into_shas() {
  SHAS=()
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    SHAS+=("$line")
  done
}

die() { echo "${ERR}$*" >&2; exit 1; }
note() { echo "$*"; }
mask() { if [ "${GITHUB_ACTIONS:-}" = "true" ]; then echo "::add-mask::$1"; fi; }

# With no publish-at, publish 15 minutes after this job starts. Leed starts building pages a few
# minutes before their publish time, and scheduling goes one page at a time, so a time closer than
# this can let publishing begin while the release is still being scheduled — the early pages then
# go out in one publish and the rest in another. GNU date (Linux, Git Bash, BusyBox) takes `-d @N`;
# BSD date (macOS) takes `-r N`.
if [ -z "$LEED_PUBLISH_AT" ]; then
  publish_epoch=$(( $(date -u +%s) + 900 ))
  LEED_PUBLISH_AT="$(date -u -d "@$publish_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -r "$publish_epoch" +%Y-%m-%dT%H:%M:%SZ)"
  note "No publish-at given; publishing 15 minutes from now, at ${LEED_PUBLISH_AT}."
fi

# ---------------------------------------------------------------------------
# Preconditions, checked in the order that produces the most useful message.
# ---------------------------------------------------------------------------

command -v jq >/dev/null 2>&1 || die "jq is required and was not found on PATH."

# Without `permissions: id-token: write` the runner exposes neither variable, and every other
# failure downstream is a confusing consequence of this one.
if [ -z "${LEED_OIDC_TOKEN:-}" ] && { [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] || [ -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]; }; then
  die "No OIDC token available.
On GitHub Actions: add 'permissions: id-token: write' to this job or workflow. Declaring id-token
also narrows every other permission to none, so list 'contents: read' too if the job checks out code.
On GitLab CI: declare an 'id_tokens:' block naming LEED_OIDC_TOKEN with the trust's audience."
fi

# ---------------------------------------------------------------------------
# Work out what to compare against, when the caller has not said.
#
# The point of this block is that the two dominant release shapes should need no configuration:
# a tag pipeline means "everything since the previous release tag", and a branch push means
# "everything this push added". Both are derivable from what CI already tells us.
# ---------------------------------------------------------------------------

# The two parents of a merge commit: `^1` is the branch merged INTO, `^2` the branch merged FROM,
# so `^1..^2` is exactly what that merge brought in — without the merge commit itself, which
# carries no sourceId and would only come back as an unmatched id.
use_merge_commit() {
  local sha="$1" origin="$2" parents
  git rev-parse --verify --quiet "${sha}^{commit}" >/dev/null \
    || die "Cannot resolve merge commit '${sha}'. Fetch depth may be too shallow, or the sha may be wrong."
  parents="$(git rev-list --parents -n1 "$sha" | wc -w)"
  if [ "$parents" -lt 3 ]; then
    die "'${sha}' is not a merge commit — it has $((parents - 1)) parent(s).
A squash or fast-forward merge produces an ordinary commit, and its own sha is the whole release:
pass it as 'since' with the commit before it, or pass 'source-ids' directly."
  fi
  LEED_SINCE="${sha}^1"
  LEED_UNTIL="${sha}^2"
  SINCE_ORIGIN="$origin"
}

resolve_since() {
  [ -n "$LEED_SINCE" ] && { SINCE_ORIGIN="the 'since' input"; return; }

  if [ -n "$LEED_MERGE_COMMIT" ]; then
    use_merge_commit "$LEED_MERGE_COMMIT" "the parents of merge commit ${LEED_MERGE_COMMIT}"
    return
  fi

  if [ -n "$LEED_TAG" ]; then
    # A tag build: the release is this tag minus the one before it. `--match` lets a project whose
    # tags include non-releases (nightly-…, build-123) name only the releases.
    LEED_UNTIL="$LEED_TAG"
    local prev
    prev="$(git describe --tags --abbrev=0 --match "$LEED_TAG_PATTERN" "${LEED_TAG}^" 2>/dev/null || true)"
    if [ -n "$prev" ]; then
      LEED_SINCE="$prev"
      SINCE_ORIGIN="the previous tag matching '${LEED_TAG_PATTERN}'"
      return
    fi
    # No earlier tag: this is the first release, so the whole history up to it IS the release.
    ALL_FROM_ROOT=true
    SINCE_ORIGIN="the start of history (no earlier tag matching '${LEED_TAG_PATTERN}')"
    return
  fi

  if [ -n "$LEED_EVENT_BEFORE" ] && ! [[ "$LEED_EVENT_BEFORE" =~ $ZERO_SHA_RE ]]; then
    LEED_SINCE="$LEED_EVENT_BEFORE"
    SINCE_ORIGIN="the ref's previous value for this push"
    return
  fi

  # No usable "previous value" — but if the tip is a merge commit, that merge IS the release.
  # This is the "merging to main is our release" workflow on a re-run, a manual dispatch, or the
  # first pipeline for a ref, where `before` is the all-zero sha.
  if [ "$(git rev-list --parents -n1 HEAD 2>/dev/null | wc -w)" -ge 3 ]; then
    use_merge_commit "HEAD" "the parents of the merge commit at HEAD"
    return
  fi

  if [ -n "$LEED_EVENT_BEFORE" ]; then
    die "This looks like the first push to a new ref — the ref had no previous value, so there is
nothing to diff against. Pass 'since' explicitly, or 'source-ids' with the list you want."
  fi
  die "Cannot work out what to compare against. This is not a tag build and no previous ref value
was available. Pass 'since' (a commit or ref) or 'source-ids' (an explicit list)."
}

if [ -z "$LEED_SOURCE_IDS" ]; then
  resolve_since
  # A shallow clone is the worst failure mode here: git log succeeds, returns nothing, and the run
  # reports a clean 'scheduled 0 pages' while silently omitting the entire release.
  if [ "$(git rev-parse --is-shallow-repository 2>/dev/null || echo false)" = "true" ]; then
    die "This is a shallow clone, so the commit range would be empty or wrong.
Set 'fetch-depth: 0' on actions/checkout (GIT_DEPTH: 0 on GitLab), and 'fetch-tags: true' if <since> is a tag."
  fi
  # The all-zero SHA is what GitHub's `github.event.before` and GitLab's $CI_COMMIT_BEFORE_SHA
  # both contain when the ref did not previously exist — a brand-new tag or the first push to a
  # branch. It is the single most common wrong value for <since>, and "cannot resolve" alone sends
  # people looking for a fetch problem they do not have.
  $ALL_FROM_ROOT || case "$LEED_SINCE" in
    0000000000000000000000000000000000000000|0000000)
      die "<since> is the all-zero SHA, which means the ref had no previous value — a newly created
tag, or the first push to a branch. 'github.event.before' / \$CI_COMMIT_BEFORE_SHA cannot be used here.
For a tag-triggered release use the PREVIOUS tag, e.g.
  git describe --tags --abbrev=0 \"\${GITHUB_REF_NAME}^\"
or pass 'source-ids' with an explicit list." ;;
  esac
  if ! $ALL_FROM_ROOT; then
    git rev-parse --verify --quiet "${LEED_SINCE}^{commit}" >/dev/null \
      || die "Cannot resolve <since> '${LEED_SINCE}' (from ${SINCE_ORIGIN}). If it is a tag, set 'fetch-tags: true' on checkout."
  fi
  git rev-parse --verify --quiet "${LEED_UNTIL}^{commit}" >/dev/null \
    || die "Cannot resolve <until> '${LEED_UNTIL}'."
fi

# ---------------------------------------------------------------------------
# The source ids: an explicit list if given, otherwise the commit range.
#
# Leed treats a sourceId as an ARBITRARY STRING that is merely usually a commit SHA, so nothing
# here validates the shape of an id — a release tool emitting `release-2026-10-01` is legitimate.
# What is normalized is only what a shell reliably gets wrong: surrounding whitespace, blank
# entries, and duplicates.
# ---------------------------------------------------------------------------

if [ -n "$LEED_SOURCE_IDS" ]; then
  read_lines_into_shas < <(printf '%s' "$LEED_SOURCE_IDS" | tr ',' '\n' | tr -d '\r' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$' | awk '!seen[$0]++')
  SOURCE_DESC="the supplied source-ids list"
else
  if $ALL_FROM_ROOT; then
    read_lines_into_shas < <(git log "${LEED_UNTIL}" --format=%H)
    SOURCE_DESC="all history up to ${LEED_UNTIL} (${SINCE_ORIGIN})"
  else
    read_lines_into_shas < <(git log "${LEED_SINCE}..${LEED_UNTIL}" --format=%H)
    SOURCE_DESC="${LEED_SINCE}..${LEED_UNTIL} (from ${SINCE_ORIGIN})"
  fi
fi

if [ "${#SHAS[@]}" -eq 0 ]; then
  note "No source ids in ${SOURCE_DESC}. Nothing to schedule."
  {
    echo "scheduled=0"; echo "would-schedule=0"; echo "matched=0"; echo "unmatched-source-ids=[]"
  } >> "${GITHUB_OUTPUT:-/dev/null}"
  exit 0
fi
note "Found ${#SHAS[@]} source id(s) from ${SOURCE_DESC}."

# ---------------------------------------------------------------------------
# Mint the token.
# ---------------------------------------------------------------------------

if [ -n "${LEED_OIDC_TOKEN:-}" ]; then
  # GitLab injects the token from the job's `id_tokens:` block. Nothing to mint.
  TOKEN="${LEED_OIDC_TOKEN}"
else
  # ACTIONS_ID_TOKEN_REQUEST_URL already carries `?api-version=…`, so the audience is appended
  # with `&`. Using `?` yields a token carrying GitHub's DEFAULT audience — the repository
  # owner's URL, identical for every workflow in the organization — which Leed rejects.
  TOKEN="$(curl -sS --fail-with-body \
    -H "Authorization: Bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
    "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${LEED_AUDIENCE}" | jq -r '.value')"
fi
if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then die "Failed to mint an OIDC token."; fi
mask "${TOKEN}"

# ---------------------------------------------------------------------------
# Call Leed. `post <chunk-json> <confirm>` echoes the response body.
# ---------------------------------------------------------------------------

post() {
  local ids_json="$1" confirm="$2" body http status
  body="$(jq -nc \
    --argjson sourceIds "$ids_json" \
    --arg publishedAt "$LEED_PUBLISH_AT" \
    --argjson confirm "$confirm" \
    --arg minimumStatus "$LEED_MINIMUM_STATUS" \
    '{sourceIds: $sourceIds, publishedAt: $publishedAt, confirm: $confirm}
     + (if $minimumStatus == "" then {} else {minimumStatus: $minimumStatus} end)')"

  http="$(curl -sS -o /tmp/leed-response.json -w '%{http_code}' \
    -X POST "$ENDPOINT" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$body")"
  status="$http"

  if [ "$status" != "200" ]; then
    echo "${ERR}Leed refused the request (HTTP ${status}):" >&2
    jq -r '.message // .error // .' /tmp/leed-response.json >&2 || cat /tmp/leed-response.json >&2
    case "$status" in
      401) echo "${ERR}Check the audience matches the trust exactly, and that the token's claims match the trust's constraints." >&2 ;;
      402) echo "${ERR}Scheduling by source requires the Growth plan. The dry run is free on every plan." >&2 ;;
      403) echo "${ERR}The trust does not grant this. Check its capability scope and page types." >&2 ;;
    esac
    exit 1
  fi
  cat /tmp/leed-response.json
}

TOTAL_SCHEDULED=0
TOTAL_WOULD=0
TOTAL_MATCHED=0
UNMATCHED="[]"

# Chunk the id list at Leed's request-body cap.
for ((i = 0; i < ${#SHAS[@]}; i += MAX_SOURCE_IDS)); do
  chunk_json="$(printf '%s\n' "${SHAS[@]:i:MAX_SOURCE_IDS}" | jq -R . | jq -sc .)"

  # Always dry run first, on every chunk, whatever the mode.
  resp="$(post "$chunk_json" false)"
  matched=$(jq -r '.matched' <<<"$resp")
  would=$(jq -r '.wouldSchedule' <<<"$resp")
  wouldfail=$(jq -r '.wouldFail' <<<"$resp")
  unmatched=$(jq -c '.unmatchedSourceIds // []' <<<"$resp")
  TOTAL_MATCHED=$((TOTAL_MATCHED + matched))
  TOTAL_WOULD=$((TOTAL_WOULD + would))
  UNMATCHED="$(jq -cn --argjson a "$UNMATCHED" --argjson b "$unmatched" '$a + $b')"

  note "Dry run: ${matched} page(s) matched, ${would} would be scheduled, ${wouldfail} would fail."
  jq -r '.results[]? | select(.wouldSchedule == false)
         | "  ✗ \(.pageId) \(.title // "") — \(.reason // "no reason given")"' <<<"$resp" || true

  [ "$LEED_DRY_RUN" = "true" ] && continue

  # Execute, then drain. Leed caps pages per call and reports `remaining`; repeating the identical
  # confirmed request advances by the pages it scheduled. A page that fails PERMANENTLY still
  # consumes a slot, so `remaining` can hold steady while `failed` grows — hence the no-progress
  # guard, without which this loop would spin forever on such a page.
  while :; do
    resp="$(post "$chunk_json" true)"
    scheduled=$(jq -r '.scheduled' <<<"$resp")
    failed=$(jq -r '.failed' <<<"$resp")
    remaining=$(jq -r '.remaining // 0' <<<"$resp")
    TOTAL_SCHEDULED=$((TOTAL_SCHEDULED + scheduled))
    note "Scheduled ${scheduled}, ${failed} failed, ${remaining} remaining."
    jq -r '.results[]? | select(.scheduled == false)
           | "  ✗ \(.pageId) \(.title // "") — \(.reason // "no reason given")"' <<<"$resp" || true
    [ "$remaining" -gt 0 ] || break
    if [ "$scheduled" -eq 0 ]; then
      die "${remaining} page(s) still unscheduled but the last call scheduled none — they cannot be scheduled as requested. See the per-page reasons above."
    fi
  done
done

unmatched_count=$(jq 'length' <<<"$UNMATCHED")
if [ "$unmatched_count" -gt 0 ]; then
  note "${unmatched_count} source id(s) matched no page. That is normal — most commits touch code, not content."
fi

{
  echo "scheduled=${TOTAL_SCHEDULED}"
  echo "would-schedule=${TOTAL_WOULD}"
  echo "matched=${TOTAL_MATCHED}"
  echo "unmatched-source-ids=${UNMATCHED}"
} >> "${GITHUB_OUTPUT:-/dev/null}"

if [ "$LEED_FAIL_ON_UNMATCHED" = "true" ] && [ "$unmatched_count" -gt 0 ]; then
  die "${unmatched_count} source id(s) matched no page and fail-on-unmatched is set."
fi

if [ "$LEED_DRY_RUN" = "true" ]; then
  note "Dry run only. Set dry-run: false to schedule."
fi
