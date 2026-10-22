#!/usr/bin/env bash
# Integration tests for release mode. Extracts the "Generate diff" step from
# action.yml and runs it inside throwaway git repos with real tags.
# Requires python3 with PyYAML. Run: bash tests/test-release-mode.sh
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
FAILURES=0

pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; FAILURES=$((FAILURES + 1)); }

assert_contains() {
  if grep -qF -- "$2" <<< "$3"; then pass "$1"; else fail "$1 (missing: $2)"; fi
}
assert_not_contains() {
  if grep -qF -- "$2" <<< "$3"; then fail "$1 (unexpected: $2)"; else pass "$1"; fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

python3 - "$ROOT/action.yml" "$WORK/step.sh" <<'EOF'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
open(sys.argv[2], 'w').write(d['runs']['steps'][0]['run'])
EOF

# Stub gh: returns a canned release for any tag, so tests need no network
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "release" ] && [ "$2" = "view" ]; then
  printf '{"name":"Big Release","body":"Adds invoice exports.\\n\\nFixes the billing bug.","url":"https://github.com/o/r/releases/tag/%s"}\n' "$3"
  exit 0
fi
exit 1
EOF
chmod +x "$WORK/bin/gh"

new_repo() {
  REPO=$(mktemp -d "$WORK/repo.XXXXXX")
  git -C "$REPO" init -q
  git -C "$REPO" config user.email test@example.com
  git -C "$REPO" config user.name test
  git -C "$REPO" config commit.gpgsign false
  git -C "$REPO" config tag.gpgsign false
}
commit_file() { # file content message
  mkdir -p "$(dirname "$REPO/$1")"
  printf '%s\n' "$2" > "$REPO/$1"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m "$3"
}

# run_step [VAR=value ...]  -> sets OUT (content), STATUS, LOG, EMPTY
run_step() {
  local outfile="$WORK/github_output"
  : > "$outfile"
  set +e
  LOG=$(cd "$REPO" && env \
    ACTION_PATH="$ROOT" GITHUB_OUTPUT="$outfile" MAX_DIFF_LINES=1000 \
    INPUT_BASE= INPUT_PR_NUMBER= INPUT_RELEASE_TAG= INPUT_REPOSITORY=o/r \
    EVENT_NAME=release EVENT_RELEASE_TAG= GH_TOKEN= \
    EVENT_PR_BASE_SHA= EVENT_PUSH_BEFORE_SHA= EVENT_PR_TITLE= EVENT_PR_BODY= \
    PATH="$PATH" "$@" bash "$WORK/step.sh" 2>&1)
  STATUS=$?
  set -e
  EMPTY=$(grep '^empty=' "$outfile" | cut -d= -f2 || true)
  local f
  f=$(grep '^diff_file=' "$outfile" | cut -d= -f2 || true)
  OUT=""
  if [ -n "$f" ] && [ -f "$f" ]; then OUT=$(cat "$f"); rm -f "$f"; fi
}

# --- Basic release: only commits between the previous tag and this tag -------
new_repo
commit_file a.txt "first" "feat: first release work"
git -C "$REPO" tag v1.0.0
commit_file src/invoices.js "export const a = 1" "feat: add invoice export"
commit_file src/billing.js "export const b = 2" "fix: billing rounding bug"
git -C "$REPO" tag v1.1.0
commit_file later.txt "after release" "chore: work after the release"

run_step EVENT_RELEASE_TAG=v1.1.0
assert_contains "basic: succeeds" "Release v1.1.0: comparing with v1.0.0" "$LOG"
[ "$STATUS" -eq 0 ] && pass "basic: exit 0" || fail "basic: exit $STATUS"
assert_contains "basic: heading" "## Release v1.1.0" "$OUT"
assert_contains "basic: since previous tag" "changes since v1.0.0" "$OUT"
assert_contains "basic: includes commit 1" "feat: add invoice export" "$OUT"
assert_contains "basic: includes commit 2" "fix: billing rounding bug" "$OUT"
assert_not_contains "basic: excludes earlier commit" "feat: first release work" "$OUT"
assert_not_contains "basic: excludes later commit" "chore: work after the release" "$OUT"
assert_contains "basic: diff has release files" "+export const a = 1" "$OUT"
assert_not_contains "basic: diff excludes later files" "after release" "$OUT"
assert_not_contains "basic: no earlier file in diff" "+first" "$OUT"

# --- Release notes from GitHub, when available -------------------------------
PATH_BACKUP=$PATH
run_step EVENT_RELEASE_TAG=v1.1.0 GH_TOKEN=x PATH="$WORK/bin:$PATH"
assert_contains "notes: release name" "## Release Big Release" "$OUT"
assert_contains "notes: release url" "Release: https://github.com/o/r/releases/tag/v1.1.0" "$OUT"
assert_contains "notes: release body" "Adds invoice exports." "$OUT"

# --- Annotated tags and a moving major tag -----------------------------------
new_repo
commit_file a.txt "one" "feat: one"
git -C "$REPO" tag -a v1.0.0 -m "release 1.0.0"
git -C "$REPO" tag -f v1 v1.0.0 -q 2>/dev/null || git -C "$REPO" tag v1 v1.0.0
commit_file b.txt "two" "feat: two"
git -C "$REPO" tag -a v1.1.0 -m "release 1.1.0"
git -C "$REPO" tag -f v1 v1.1.0 -q 2>/dev/null || true
commit_file c.txt "three" "feat: three"
git -C "$REPO" tag -a v1.2.0 -m "release 1.2.0"

run_step EVENT_RELEASE_TAG=v1.1.0
assert_contains "annotated: v1.1.0 compares with v1.0.0" "changes since v1.0.0" "$OUT"
assert_contains "annotated: v1.1.0 has its commit" "feat: two" "$OUT"
assert_not_contains "annotated: v1.1.0 not v1.2.0 commit" "feat: three" "$OUT"
run_step EVENT_RELEASE_TAG=v1.2.0
assert_contains "annotated: v1.2.0 has only its commit" "feat: three" "$OUT"
assert_not_contains "annotated: v1.2.0 excludes v1.1.0 commit" "feat: two" "$OUT"

# --- First release: everything up to the tag ---------------------------------
new_repo
commit_file a.txt "alpha" "feat: alpha"
commit_file b.txt "beta" "feat: beta"
git -C "$REPO" tag v1.0.0
run_step EVENT_RELEASE_TAG=v1.0.0
[ "$STATUS" -eq 0 ] && pass "first: exit 0" || fail "first: exit $STATUS ($LOG)"
assert_contains "first: baseline noted" "changes since the beginning of the repository" "$OUT"
assert_contains "first: includes all commits" "feat: alpha" "$OUT"
assert_contains "first: includes all commits (2)" "feat: beta" "$OUT"
assert_contains "first: diff has all files" "+alpha" "$OUT"

# --- First release where the tag is the root commit --------------------------
new_repo
commit_file a.txt "only" "feat: only commit"
git -C "$REPO" tag v0.1.0
run_step EVENT_RELEASE_TAG=v0.1.0
[ "$STATUS" -eq 0 ] && pass "root: exit 0" || fail "root: exit $STATUS ($LOG)"
assert_contains "root: diff included" "+only" "$OUT"

# --- base overrides the previous tag -----------------------------------------
new_repo
commit_file a.txt "a" "feat: a"
A=$(git -C "$REPO" rev-parse HEAD)
commit_file b.txt "b" "feat: b"
git -C "$REPO" tag v1.0.0
commit_file c.txt "c" "feat: c"
git -C "$REPO" tag v1.1.0
run_step EVENT_RELEASE_TAG=v1.1.0 INPUT_BASE="$A"
assert_contains "base: override label" "changes since $A" "$OUT"
assert_contains "base: includes commit b" "feat: b" "$OUT"
assert_contains "base: includes commit c" "feat: c" "$OUT"
run_step EVENT_RELEASE_TAG=v1.1.0 INPUT_BASE=does-not-exist
[ "$STATUS" -ne 0 ] && pass "base: unknown base fails" || fail "base: unknown base should fail"
assert_contains "base: unknown base message" "Base ref 'does-not-exist' does not exist" "$LOG"

# --- release_tag input works on any event ------------------------------------
run_step EVENT_NAME=workflow_dispatch INPUT_RELEASE_TAG=v1.1.0
assert_contains "input: release_tag on workflow_dispatch" "## Release v1.1.0" "$OUT"
assert_contains "input: compares with previous tag" "changes since v1.0.0" "$OUT"
assert_not_contains "input: only that release's commits" "feat: b" "$OUT"

# --- Missing tag -------------------------------------------------------------
run_step EVENT_RELEASE_TAG=v9.9.9
[ "$STATUS" -ne 0 ] && pass "missing tag: fails" || fail "missing tag: should fail"
assert_contains "missing tag: helpful message" "fetch-depth: 0" "$LOG"

# --- Option-like tag names are rejected, not treated as flags ----------------
run_step EVENT_RELEASE_TAG=--all
[ "$STATUS" -ne 0 ] && pass "flag-like tag: fails" || fail "flag-like tag: should fail"

# --- Release that only touches lock files is skipped -------------------------
new_repo
commit_file a.txt "a" "feat: a"
git -C "$REPO" tag v1.0.0
seq 1 50 > "$REPO/package-lock.json"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m "chore: bump deps"
git -C "$REPO" tag v1.0.1
run_step EVENT_RELEASE_TAG=v1.0.1
[ "$EMPTY" = "true" ] && pass "lock-only: skipped" || fail "lock-only: expected empty=true (got '$EMPTY')"
[ -z "$OUT" ] && pass "lock-only: no content" || fail "lock-only: content produced"

# --- Large release is summarized ---------------------------------------------
new_repo
commit_file a.txt "a" "feat: a"
git -C "$REPO" tag v1.0.0
seq 1 1500 > "$REPO/src_big.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m "feat: big change"
git -C "$REPO" tag v1.1.0
run_step EVENT_RELEASE_TAG=v1.1.0
assert_contains "large: summary" "## Diff summary" "$OUT"
assert_contains "large: file listed" '`src_big.txt`' "$OUT"
assert_contains "large: commits still sent" "feat: big change" "$OUT"

# --- Commit list is capped at 200 --------------------------------------------
new_repo
commit_file a.txt "a" "feat: a"
git -C "$REPO" tag v1.0.0
for i in $(seq 1 205); do git -C "$REPO" commit -q --allow-empty -m "chore: empty $i"; done
commit_file z.txt "z" "feat: last"
git -C "$REPO" tag v1.1.0
run_step EVENT_RELEASE_TAG=v1.1.0
assert_contains "cap: noted" "Showing the most recent 200 of 206 commits." "$OUT"
assert_contains "cap: newest kept" "feat: last" "$OUT"
if grep -qxF -- "### chore: empty 1" <<< "$OUT"; then fail "cap: oldest dropped"; else pass "cap: oldest dropped"; fi
if grep -qxF -- "### chore: empty 205" <<< "$OUT"; then pass "cap: second newest kept"; else fail "cap: second newest kept"; fi

# --- Regression: push events still use the old behavior ----------------------
new_repo
commit_file a.txt "a" "feat: a"
B=$(git -C "$REPO" rev-parse HEAD)
commit_file b.txt "b" "feat: pushed work"
run_step EVENT_NAME=push EVENT_PUSH_BEFORE_SHA="$B"
assert_contains "push: still works" "feat: pushed work" "$OUT"
assert_not_contains "push: not release mode" "## Release" "$OUT"

echo ""
if [ "$FAILURES" -eq 0 ]; then
  echo "All tests passed"
else
  echo "$FAILURES test(s) failed"
  exit 1
fi
