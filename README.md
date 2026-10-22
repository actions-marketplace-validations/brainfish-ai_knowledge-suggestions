# Brainfish Knowledge Suggestions

A GitHub Action that generates AI-powered article suggestions from git diffs using the Brainfish API.

Full setup guide: [Generate knowledge suggestions from GitHub pull requests](https://help.brainfi.sh/articles/generate-knowledge-suggestions-from-github-pull-requests-fqZjjnDVOl)

## Getting started

1. **Create a Brainfish API token.** In the [Brainfish Dashboard](https://app.brainfi.sh), go to **Settings → API Tokens** and click **Create token**. The token starts with `bf_api_`.
2. **Store it as a GitHub secret.** In your repository, go to **Settings → Secrets and variables → Actions → New repository secret**, name it `BRAINFISH_API_KEY`, and paste the token.
3. **Add a workflow** using one of the examples below.

Suggestions go to a review queue in Brainfish, so nothing changes in your knowledge base until you approve it.

## Usage

```yaml
- uses: brainfish-ai/knowledge-suggestions@v1
  with:
    api_key: ${{ secrets.BRAINFISH_API_KEY }}
```

### On pull requests

```yaml
name: Suggest articles
on:
  pull_request:
    types: [opened, synchronize]

jobs:
  suggest:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - uses: brainfish-ai/knowledge-suggestions@v1
        with:
          api_key: ${{ secrets.BRAINFISH_API_KEY }}
          collection_id: "your-collection-uuid" # optional
```

### On releases

Run the action when you publish a release. It compares the release tag with the **previous tag** and sends the release title and notes, every commit in between (the latest 200), and the diff. This suits teams that ship in batches and want one set of suggestions per release.

```yaml
name: Suggest articles from release
on:
  release:
    types: [published]

jobs:
  suggest:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0 # needed so tags are available

      - uses: brainfish-ai/knowledge-suggestions@v1
        with:
          api_key: ${{ secrets.BRAINFISH_API_KEY }}
```

- The previous tag is the nearest earlier tag in the release's history. For the first release, everything up to the tag is used.
- Set `base` to compare against a different tag or commit instead.
- To run it for any tag, for example from `workflow_dispatch`, set `release_tag: v1.2.0`.
- Release notes are read with the workflow's `github.token`. If they can't be read, the action still runs without them.

### On push to main

```yaml
name: Suggest articles
on:
  push:
    branches: [main]

jobs:
  suggest:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - uses: brainfish-ai/knowledge-suggestions@v1
        with:
          api_key: ${{ secrets.BRAINFISH_API_KEY }}
```

### With explicit base commit

```yaml
- uses: brainfish-ai/knowledge-suggestions@v1
  with:
    api_key: ${{ secrets.BRAINFISH_API_KEY }}
    base: "abc123"
```

### From a specific pull request

Set `pr_number` to generate suggestions from any pull request. The PR title, description, labels, commits and diff are fetched from the GitHub API, so **no checkout is needed** and the action can run on any event, such as when a PR is merged or from a manual run.

```yaml
name: Suggest articles from merged PR
on:
  pull_request:
    types: [closed]

permissions:
  pull-requests: read

jobs:
  suggest:
    if: github.event.pull_request.merged == true
    runs-on: ubuntu-latest
    steps:
      - uses: brainfish-ai/knowledge-suggestions@v1
        with:
          api_key: ${{ secrets.BRAINFISH_API_KEY }}
          pr_number: ${{ github.event.pull_request.number }}
```

Or run it manually for any PR:

```yaml
on:
  workflow_dispatch:
    inputs:
      pr_number:
        description: "Pull request number"
        required: true

jobs:
  suggest:
    runs-on: ubuntu-latest
    permissions:
      pull-requests: read
    steps:
      - uses: brainfish-ai/knowledge-suggestions@v1
        with:
          api_key: ${{ secrets.BRAINFISH_API_KEY }}
          pr_number: ${{ inputs.pr_number }}
```

To read a PR from another repository, also set `repository` (`owner/name`) and a `github_token` that can read it.

> **Note:** Large diffs are summarized before sending (see [What gets sent](#what-gets-sent)), but GitHub's API itself does not return diffs larger than 300 files / 20,000 lines. For PRs that large, use a full checkout with `base` instead.

## Inputs

| Input           | Required | Description                                      |
| --------------- | -------- | ------------------------------------------------ |
| `api_key`       | Yes      | Brainfish API token (`bf_api_...`) for authentication |
| `collection_id` | No       | Collection ID to target for suggestions          |
| `base`          | No       | Base commit SHA (or tag) to generate the diff from. With a release, replaces the previous tag as the starting point |
| `release_tag`   | No       | Release tag to generate suggestions from, such as `v1.2.0`. Set automatically on `release` events. Needs a checkout with `fetch-depth: 0` |
| `pr_number`     | No       | Pull request number to generate suggestions from (fetched via the GitHub API, no checkout needed) |
| `repository`    | No       | Repository (`owner/name`) containing the PR. Only used with `pr_number` (default: current repo) |
| `github_token`  | No       | Token used to read the PR. Only used with `pr_number` (default: `github.token`) |
| `max_diff_lines` | No      | Diffs up to this many lines are sent in full; larger diffs are replaced by a summary (default: `1000`) |
| `api_url`       | No       | API base URL (default: `https://api.brainfi.sh`) |

## Outputs

| Output    | Description                                       |
| --------- | ------------------------------------------------- |
| `task_id` | The task ID for the triggered suggestion pipeline |
| `status`  | The status of the suggestion request              |

## How the diff is resolved

1. If `pr_number` is provided, the PR's content and diff are fetched from the GitHub API (steps below are skipped)
2. Otherwise, if `release_tag` is provided or the workflow runs on a **release**, uses the diff between the previous tag (or `base`, if set) and the release tag, and includes the release notes
3. If `base` is provided, uses the diff between `base` and `HEAD`
4. If triggered by a **pull request**, uses the PR base branch SHA
5. If triggered by a **push**, uses the `before` SHA from the push event
6. Otherwise, falls back to `HEAD~1`

> **Note:** Unless you use `pr_number`, run `actions/checkout` with `fetch-depth: 0` first so the full git history is available for diff generation.

## What gets sent

The content sent to Brainfish always includes the PR title, description and labels (or the release title and notes, for releases) and the commit messages. The diff is handled as follows:

1. **Noise files are dropped.** These files are never sent:
   - Lock files: `package-lock.json`, `npm-shrinkwrap.json`, `pnpm-lock.yaml`, `go.sum`, and any `*.lock` / `*.lockb` file (`yarn.lock`, `Cargo.lock`, `poetry.lock`, `uv.lock`, `Gemfile.lock`, `composer.lock`, `Podfile.lock`, ...)
   - Generated or minified files: `*.min.js`, `*.min.css`, `*.map`, `*.snap`
   - Anything under `dist/`, `build/`, `node_modules/` or `vendor/`
   - Binary files

   Dropped files are listed by name so Brainfish knows they changed.
2. **Small diffs are sent in full.** If the remaining diff is at most `max_diff_lines` lines (default 1000), it is sent as is. Lock files don't count toward the limit.
3. **Large diffs are summarized.** Otherwise the raw diff is replaced by a deterministic summary (no LLM involved):
   - Total files changed and lines added/removed
   - A table of every changed file with its status (added, modified, deleted, renamed) and `+N / -M`, ordered by size of change (up to 300 files)
   - The functions, classes or sections touched in each file, taken from git's hunk headers (up to 10 per file)

If nothing is left after dropping noise files (for example a PR that only updates a lock file), no request is sent.

## Versions

| Reference | What you get |
| --------- | ------------ |
| `@v1`     | The latest `v1.x` release, including fixes and new features, with no breaking changes (recommended) |
| `@v1.0.0` | Exactly that release; nothing changes until you update the reference |

See the [releases page](https://github.com/brainfish-ai/knowledge-suggestions/releases) for release notes.

## Development

Run the tests for the diff filtering and summary logic:

```bash
bash tests/test-prepare-content.sh
```

The release mode tests build throwaway git repos with real tags and run the step from `action.yml` (they need `python3` with PyYAML):

```bash
bash tests/test-release-mode.sh
```

### Releasing

1. Merge changes to `main` and confirm the tests pass.
2. Create a release with a new semver tag, for example `v1.1.0`:

   ```bash
   gh release create v1.1.0 --target main --generate-notes
   ```

3. Move the major tag so users on `@v1` get the release. Skip this for a breaking change; release it as `v2.0.0` and create a new `v2` tag instead.

   ```bash
   git fetch --tags
   git tag -f v1 v1.1.0
   git push -f origin v1
   ```

## License

MIT
