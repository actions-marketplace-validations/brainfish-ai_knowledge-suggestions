# Brainfish Knowledge Suggestions

A GitHub Action that generates AI-powered article suggestions from git diffs using the Brainfish API.

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

> **Note:** GitHub's API does not return diffs larger than 300 files / 20,000 lines. For PRs that large, use a full checkout with `base` instead.

## Inputs

| Input           | Required | Description                                      |
| --------------- | -------- | ------------------------------------------------ |
| `api_key`       | Yes      | Brainfish public API key for authentication      |
| `collection_id` | No       | Collection ID to target for suggestions          |
| `base`          | No       | Base commit SHA to generate the diff from        |
| `pr_number`     | No       | Pull request number to generate suggestions from (fetched via the GitHub API, no checkout needed) |
| `repository`    | No       | Repository (`owner/name`) containing the PR. Only used with `pr_number` (default: current repo) |
| `github_token`  | No       | Token used to read the PR. Only used with `pr_number` (default: `github.token`) |
| `api_url`       | No       | API base URL (default: `https://api.brainfi.sh`) |

## Outputs

| Output    | Description                                       |
| --------- | ------------------------------------------------- |
| `task_id` | The task ID for the triggered suggestion pipeline |
| `status`  | The status of the suggestion request              |

## How the diff is resolved

0. If `pr_number` is provided, the PR's content and diff are fetched from the GitHub API (steps below are skipped)
1. If `base` is provided, uses the diff between `base` and `HEAD`
2. If triggered by a **pull request**, uses the PR base branch SHA
3. If triggered by a **push**, uses the `before` SHA from the push event
4. Otherwise, falls back to `HEAD~1`

> **Note:** Always use `actions/checkout` with `fetch-depth: 0` to ensure the full git history is available for diff generation.

## License

MIT
