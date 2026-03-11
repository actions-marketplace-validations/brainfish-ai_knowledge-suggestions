# Brainfish Create Suggestions

A GitHub Action that generates AI-powered article suggestions from git diffs using the Brainfish API.

## Usage

```yaml
- uses: brainfish-ai/create-suggestions@v1
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

      - uses: brainfish-ai/create-suggestions@v1
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

      - uses: brainfish-ai/create-suggestions@v1
        with:
          api_key: ${{ secrets.BRAINFISH_API_KEY }}
      
```

### With explicit base commit

```yaml
- uses: brainfish-ai/create-suggestions@v1
  with:
    api_key: ${{ secrets.BRAINFISH_API_KEY }}

    base: "abc123"
```

## Inputs

| Input           | Required | Description                                      |
| --------------- | -------- | ------------------------------------------------ |
| `api_key`       | Yes      | Brainfish public API key for authentication      |
| `collection_id` | No       | Collection ID to target for suggestions          |
| `base`          | No       | Base commit SHA to generate the diff from        |
| `api_url`       | No       | API base URL (default: `https://api.brainfi.sh`) |

## Outputs

| Output    | Description                                       |
| --------- | ------------------------------------------------- |
| `task_id` | The task ID for the triggered suggestion pipeline |
| `status`  | The status of the suggestion request              |

## How the diff is resolved

1. If `base` is provided, uses the diff between `base` and `HEAD`
2. If triggered by a **pull request**, uses the PR base branch SHA
3. If triggered by a **push**, uses the `before` SHA from the push event
4. Otherwise, falls back to `HEAD~1`

> **Note:** Always use `actions/checkout` with `fetch-depth: 0` to ensure the full git history is available for diff generation.

## License

MIT
