# Automation naming

ArkDB-owned GitHub Actions workflows use source-first run titles, action-first job names, and stable required-check names. These rules do not introduce HAR build or publication automation, change event triggers, or govern the documentation site's independently managed Wiki publication jobs.

## Naming layers

| Layer | Convention | Example |
| --- | --- | --- |
| Workflow `name` | Stable action and scope, without a PR number, branch, or version | `Validate ArkDB` |
| Run `run-name` | `<Source> \| <Stage> \| <Target>` | `PR #100 \| Validate \| ArkDB Source` |
| Required-check job `name` | Fixed `<Action> <Target>`, subject to the legacy exception below | `Validate ArkDB Source` |
| Non-gate job `name` | `<Action> <Target>`, optionally prefixed by `<Source> \| ` | `PR #100 \| Publish MySQL HAR to GitHub Releases` |
| Step `name` | Concrete action and object | `Install Tooling Dependencies` |

Use English display names, canonical capitalization such as `ArkDB`, `MySQL`, `HAR`, and `OHPM`, and ASCII ` | ` separators. Include the actual target rather than ambiguous standalone names such as `Build`, `Publish`, or `Checks`.

Technical identifiers are separate from display names. Preserve existing workflow filenames and job IDs. New workflow filenames use kebab-case with a `.yml` extension; new job IDs use snake_case. Do not rename an identifier solely to improve its display name.

## Run sources

| Event | Source label | Example run title |
| --- | --- | --- |
| Pull request | `PR #<number>` from the event | `PR #100 \| Validate \| ArkDB Source` |
| Branch push, including a merge | `Push <branch>` | `Push main \| Validate \| ArkDB Source` |
| Tag push | `Tag <tag>` | `Tag mysql-v1.0.2 \| Validate \| ArkDB Source` |
| Manual execution, if introduced | `Manual <ref>` | `Manual main \| Validate \| ArkDB Source` |

The current workflow accepts push and pull request events; it has no manual trigger. Pushes to feature branches and tags remain validation runs. The commit SHA is available in run metadata and need not be repeated in the title.

Do not infer a PR number from a commit message. A future non-gate job may resolve a push to a PR through the read-only GitHub API, but may use the PR label only when exactly one merged PR matches both the pushed SHA and destination branch. No unique match means a push label; an API failure must be reported, not disguised as an unmatched push.

`run-name` is determined before jobs execute and cannot reference preceding job outputs. Exact merged-PR attribution is therefore not required in push run titles. Do not add a source resolver or change triggers solely to name the existing required check.

## Stages and targets

| Stage | Meaning |
| --- | --- |
| `Validate` | Check source, tooling, or repository invariants without publication |
| `Build` | Produce an artifact |
| `Verify` | Exercise a named runtime, artifact, or consumer boundary |
| `Pre-publish Check` | Check a candidate in an actual publication path |
| `Publish` | Transfer an artifact or release to an external destination |

Only `Validate` applies to the current workflow. A merge or tag push does not make it a publication workflow. `ArkDB Source` covers its tooling tests and package/interface/import checks; it does not claim ArkTS compilation, HAR consumer verification, or device interoperability.

For future jobs, name the actual driver, artifact, and destination where relevant. `Publish MySQL HAR to GitHub Releases` and `Publish MySQL Package to OHPM` describe different operations. These are reserved examples, not configured jobs. Keep combined work under its true combined scope rather than claiming separate per-driver execution.

## Current workflow and required-check compatibility

`.github\workflows\checks.yml` is named `Validate ArkDB`. Its run title distinguishes PR, branch-push, and tag-push sources, and its steps name their concrete actions. The existing events, read-only token permissions, runner, action versions, Node.js selection, and npm commands are unchanged.

The job ID and display name remain **`tooling`** because the `main` ruleset requires that check. This is an intentional legacy exception to the display-name convention. The final step is named `Validate ArkDB Source`, but a step name does not replace the required job check.

Required-check names must not contain PR numbers, SHAs, timestamps, or changing versions. A future matrix must preserve a stable gate identity rather than making the required check depend on a changing set of matrix entries.

Renaming the legacy check to `Validate ArkDB Source` requires a separately coordinated migration:

1. Inspect the applicable branch protection and rulesets, including the check's GitHub App binding.
2. Make the replacement workflow available on the migration PR and confirm the new check runs successfully.
3. Update the required-check context with explicit maintainer authorization, preserving all other protection settings and accounting for open PRs that still emit `tooling`.
4. Merge the workflow change and confirm subsequent PRs emit the required replacement check.

Until that migration is authorized and coordinated, preserve `tooling`. Changing workflow/run/step display names does not require changing that gate.
