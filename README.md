# `leed-ai/schedule-release`

Continuous documentation for Leed: schedule the documentation and content pages tagged with the
commits in a release to publish at one time, so your docs ship with your code. Authenticates with a
GitHub OIDC token. **Nothing long-lived is stored in your repository.**

```yaml
name: Schedule Leed content release
on:
  push:
    tags: ["v*"]

permissions:
  id-token: write   # required — see below
  contents: read

jobs:
  schedule:
    runs-on: ubuntu-latest
    environment: leed-release
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
          fetch-tags: true
      - uses: leed-ai/schedule-release@v1
        with:
          audience: leed-cms:3f2a9c14-8b7e-4d61-9a03-1c5e77b2d840
          publish-at: "2026-10-01T09:00:00Z"
          tag-pattern: "v*"   # optional; skips nightly/build tags between releases
          dry-run: "false"
```

**There is no `since`.** On a tag build the action schedules everything in this tag that was not
in the previous matching tag — which is what a release means. On a branch push it uses the ref's
previous value. You override it only if your process is unusual.

## Before it will work

Register a **CI trust** in Leed: **Settings → CI trust**. Choose the GitHub Actions profile, set
the issuer to `https://token.actions.githubusercontent.com`, pin your repository *and* a ref or
deployment environment, tick the page types the pipeline may publish, and choose an editorial
ceiling.

The repository is pinned by its **numeric id**, not by `owner/repo`. Read yours with:

```bash
gh api repos/OWNER/REPO --jq .id
```

An id is stable across renames and transfers, and — unlike a path, which someone else can claim
once you free it — is never re-issued to a different repository. The form also asks for the
repository **name**; that is a label for the trust list only. It is never matched, so renaming the
repository leaves the label stale and the trust working.

Leed then shows you a generated **audience** of the form `leed-cms:<uuid>`. Copy it into
`audience:` above. You do not choose it, and there is no field for it — a value you pick is a
value another customer can pick too, and GitHub's issuer is identical for everyone.

## Inputs

| Input | Required | Default | |
|---|---|---|---|
| `audience` | yes | | The audience Leed generated for your trust. Matched byte-for-byte. Not a secret. |
| `publish-at` | no | *15 minutes after the job starts* | ISO 8601. A time already past is accepted, and those pages publish on Leed's next publish run. See below before setting a time close to now. |
| `since` | no | *(auto)* | Override the auto-detected start point. |
| `tag-pattern` | no | `*` | Which tags count as releases, e.g. `v*`. Tag builds only. |
| `merge-commit` | no | | A merge commit whose `^1..^2` is the release. See below. |
| `source-ids` | * | | An explicit list instead of a commit range. See below. |
| `until` | no | `HEAD` | Commit or ref the release ends at. |
| `minimum-status` | no | *(inherit)* | `draft`, `in_revision`, `approved`. Omitted, the trust's ceiling applies. A stricter value narrows it; a looser one is refused. |
| `dry-run` | no | `true` | `true` reports without changing anything. A dry run always runs first regardless. |
| `leed-url` | no | `https://app.leed.ai` | Base URL of your Leed instance. |
| `fail-on-unmatched` | no | `false` | Fail if any commit matched no page. Usually undesirable — most commits touch code, not content. |

## Which commits get used

**In the common cases, you configure nothing.** The action works it out from the CI context:

| Situation | What it uses | |
|---|---|---|
| **Tag build** (`GITHUB_REF_TYPE=tag`) | previous matching tag → this tag | The release workflow. Set `tag-pattern: "v*"` if non-release tags sit between releases. |
| **First tag ever** | all history up to the tag | There is no earlier release, so the whole history *is* the release. |
| **Branch push** | `github.event.before` → `HEAD` | Everything this push added, including a merge commit if one is in it. |
| **Merge to a branch, no usable `before`** | the merge's `^1..^2` | For "merging to `main` IS the release" — on a re-run, a manual dispatch, or a ref's first pipeline. |
| **First push to a new ref, no merge at HEAD** | *refuses* | Nothing to diff against; pass `since`, `merge-commit` or `source-ids`. |

Override with `since`/`until` when your process does not fit, or bypass ranges entirely with
`source-ids`.

### The underlying semantics

`since`/`until` go straight to `git log "<since>..<until>" --format=%H` — git's two-dot range:
**commits reachable from `until` but not from `since`.**

- **`since` is exclusive** — the boundary you start *after*. Its own commit is not included, which
  is what you want when it is the previous release tag.
- **`until` is inclusive**, and defaults to `HEAD`.

On linear history that reads as "everything after the last release, up to now". With merges it is
a set difference rather than a straight line, so a commit brought in by merging a long-lived
branch lands in whichever release first made it reachable — usually what you want, occasionally
surprising.

**A caution if you do set `since` by hand:** do not use `github.event.before` on a tag push. A
newly created tag has no previous value, so that context is the all-zero SHA. The action detects
that specific value and says so, rather than leaving you hunting a fetch problem you do not have.

### When merging to `main` is the release

If your release is "we merged a branch to `main`", the action already does the right thing on a
push — `github.event.before` → `HEAD` covers everything the merge brought in (plus the merge
commit itself, which matches no page and is reported as one unmatched id).

`merge-commit` exists for when there is no usable "previous value": re-running a past release,
scheduling from a `workflow_dispatch`, or the first pipeline on a ref. Given a merge sha it uses
`<sha>^1..<sha>^2` — the commits that merge brought in, without the merge commit — and the action
falls back to the merge at `HEAD` automatically when `before` is missing or all-zero.

```yaml
on:
  workflow_dispatch:
    inputs:
      merge: { description: "Merge commit to release", required: true }

# ...
      - uses: leed-ai/schedule-release@v1
        with:
          audience: leed-cms:3f2a9c14-…
          merge-commit: ${{ inputs.merge }}
          publish-at: "2026-10-01T09:00:00Z"
```

**Squash and fast-forward merges produce no merge commit**, so `merge-commit` refuses them and
says so. For those, the squashed commit *is* the release — use `since` with the commit before it,
or pass `source-ids`.

## Supplying the commit list yourself

If a release tool, changelog generator or manifest already knows which commits ship, hand them
over directly and skip the range entirely:

```yaml
      - id: release
        run: echo "ids=$(my-release-tool --commits)" >> "$GITHUB_OUTPUT"

      - uses: leed-ai/schedule-release@v1
        with:
          audience: leed-cms:3f2a9c14-…
          source-ids: ${{ steps.release.outputs.ids }}
          publish-at: "2026-10-01T09:00:00Z"
```

**Format:** separate with newlines, commas, or both. Surrounding whitespace is trimmed, blank
entries dropped, duplicates removed. So a `git log` capture, a file read with `$(cat ids.txt)`,
and a comma list all work without reshaping.

**A source id is an arbitrary string.** It is *usually* a commit SHA, but Leed does not require
one — `release-2026-10-01` is a perfectly good id if that is what tagged the pages. Nothing here
validates the shape, precisely so that stays true.

Supplying `source-ids` takes precedence over `since`/`until`, and skips git entirely — so it also
works in a shallow clone, where the range path deliberately refuses to run.

## Outputs

`scheduled`, `would-schedule`, `matched`, `unmatched-source-ids` (JSON array).

## Things that will bite you, and what the action does about them

**`permissions: id-token: write`.** Without it the runner exposes no OIDC variables at all. The
action checks first and says so, instead of failing later on an unset variable. Note that
declaring `id-token` narrows *every other* permission to none, which is why `contents: read` is
spelled out for the checkout.

**`fetch-depth: 0`.** A shallow clone makes `git log` return an empty range — so the job would
*succeed*, report zero pages, and silently skip your entire release. The action refuses to run in
a shallow clone. Add `fetch-tags: true` if `since` is a tag.

**Pin the environment, not the ref, for tag-triggered jobs.** GitHub's `ref` claim on a tag push
is `refs/tags/v1.2.3` — different every release, so no fixed `ref` constraint can match twice.
A deployment environment is stable. If your job runs on a branch instead, pin
`refs/heads/main` (GitHub sends the long form) and drop `environment:`.

**Do not name the environment `production` unless you mean it.** Declaring an environment
subjects the job to its deployment protection rules; a real `production` environment often
carries required reviewers, and the release job will sit waiting for approval. A dedicated
environment with no protection rules keeps the claim stable without inheriting a gate.

**The audience goes in the query string with `&`, not `?`.** The action does this correctly. If
you ever hand-roll it: `ACTIONS_ID_TOKEN_REQUEST_URL` already carries `?api-version=…`, and using
`?` yields a token with GitHub's *default* audience — the organization URL, shared by every
workflow in it — which Leed rejects.

## Why a composite action and not JavaScript

`@actions/core.getIDToken()` is more ergonomic than the `curl`, but a JS action carries a bundled
runtime that GitHub deprecates on its own schedule, independent of anything here. A composite
action has no build step and nothing to age out. The one footgun `getIDToken` would remove — the
`&`/`?` mistake — is removed anyway, because the action makes the request for you.

## Behaviour worth knowing

- A **dry run always runs first**, on every chunk, in both modes.
- Releases with more than 1000 commits are **split across calls**, all sharing one `publish-at`.
- **Leave `publish-at` unset unless you need a specific time.** Leed starts building pages a few
  minutes before their publish time, and scheduling goes one page at a time, so a time only a few
  minutes away can let publishing begin while the release is still being scheduled; the early
  pages then go out separately from the rest. The default, 15 minutes after the job starts, leaves
  room for releases of several hundred pages.
- Leed caps pages per call and reports `remaining`; the action **repeats the confirmed request
  until the remainder is drained**. A page that can never be scheduled (a PUBLISHED one needing a
  revise, say) still consumes a slot, so the action stops with an explanatory error rather than
  looping when a call makes no progress.
- Per-page failures (a page below the trust's minimum status, a page type the trust doesn't grant, a missing required field) are printed with their reasons, one ✗ line per page, and **do not fail the job**: the rest of the release is still scheduled, so read the ✗ lines. The job fails when Leed refuses the request itself (HTTP 401, 402 or 403, with the likely cause printed), when a confirmed call schedules nothing while pages remain, or when `fail-on-unmatched` is set and a commit in the range matched no page.

## Releasing a new version (maintainers)

Every release takes four steps. Steps 3 and 4 are the ones that get forgotten.

1. **Merge through a pull request.** `main` rejects direct pushes and requires both test jobs
   (Ubuntu and macOS) to pass.
2. **Tag the merge commit with the full version**, e.g. `v1.0.3`. The "Protect release tags"
   ruleset restricts tag creation, so only an account with bypass can push it.
3. **Move the major tag to the same commit**, so everyone pinned to `@v1` gets the update:
   ```sh
   git tag -f v1 && git push -f origin v1
   ```
   Moving a tag is an update under the same ruleset, so it also needs an account with bypass.
4. **Create the GitHub release and tick "Publish this Action to the GitHub Marketplace".**
   Publishing is per release: a release without the box ticked does not update the Marketplace
   listing, which keeps showing the last release that had it. The categories carry over.

Keep in mind:

- The `description` in `action.yml` must be **under 125 characters**, or the Marketplace refuses
  the release.
- A **breaking change** (a removed or renamed input, a changed default) gets `v2.0.0` and a new
  `v2` tag. Leave `v1` where it is so workflows pinned to `@v1` keep working.
- Add an entry to [`CHANGELOG.md`](CHANGELOG.md) for each version and use it as the release notes.

## License

[MIT](LICENSE) © Leed, Inc. Using this does not require a Leed license; scheduling content requires a Leed account on a plan that includes it.
