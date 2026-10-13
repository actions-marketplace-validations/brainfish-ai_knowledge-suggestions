#!/usr/bin/env bash
# Tests for scripts/prepare-content.sh. Builds throwaway git repos so the
# diffs are real git output. Run: bash tests/test-prepare-content.sh
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/scripts/prepare-content.sh"
FAILURES=0

pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; FAILURES=$((FAILURES + 1)); }

assert_contains() {
  if grep -qF -- "$2" <<< "$3"; then pass "$1"; else fail "$1 (missing: $2)"; fi
}
assert_not_contains() {
  if grep -qF -- "$2" <<< "$3"; then fail "$1 (unexpected: $2)"; else pass "$1"; fi
}
assert_empty() {
  if [ -z "$2" ]; then pass "$1"; else fail "$1 (got $(wc -l <<< "$2") lines)"; fi
}

new_repo() {
  REPO=$(mktemp -d)
  git -C "$REPO" init -q
  git -C "$REPO" config user.email test@example.com
  git -C "$REPO" config user.name test
  git -C "$REPO" config commit.gpgsign false
}
commit_all() {
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m "$1"
}
diff_since() {
  git -C "$REPO" diff --unified=3 --no-color --no-ext-diff \
    --src-prefix=a/ --dst-prefix=b/ "$1"
}
run() {
  "$SCRIPT" 2>/dev/null
}

# --- Small diff: sent in full, noise files stripped -------------------------
new_repo
mkdir -p "$REPO/src" "$REPO/dist"
printf 'export function greet(name) {\n  return "hi " + name;\n}\n' > "$REPO/src/app.js"
echo '{}' > "$REPO/package-lock.json"
commit_all base
BASE=$(git -C "$REPO" rev-parse HEAD)
printf 'export function greet(name) {\n  return "hello " + name;\n}\n' > "$REPO/src/app.js"
seq 1 500 | sed 's/^/"dep": /' > "$REPO/package-lock.json"
seq 1 200 > "$REPO/yarn.lock"
echo 'minified();' > "$REPO/dist/app.min.js"
printf '\x00\x01\x02binary' > "$REPO/logo.png"
commit_all change
OUT=$(diff_since "$BASE" | run)

assert_contains "small: full diff section" "## Diff" "$OUT"
assert_contains "small: code change included" '+  return "hello " + name;' "$OUT"
assert_not_contains "small: no summary" "## Diff summary" "$OUT"
assert_not_contains "small: lock content dropped" '"dep": 1' "$OUT"
assert_not_contains "small: no diff --git lines" "diff --git" "$OUT"
assert_not_contains "small: no index lines" "index " "$OUT"
assert_contains "small: package-lock.json listed as excluded" '`package-lock.json`' "$OUT"
assert_contains "small: yarn.lock listed as excluded" '`yarn.lock`' "$OUT"
assert_contains "small: dist file listed as excluded" '`dist/app.min.js`' "$OUT"
assert_contains "small: binary listed as excluded" '`logo.png`' "$OUT"
assert_contains "small: excluded count" "Excluded 4 lock, generated or binary file(s)" "$OUT"
rm -rf "$REPO"

# --- Large diff: summary only ------------------------------------------------
new_repo
mkdir -p "$REPO/src"
{
  echo "class Billing:"
  for i in $(seq 1 300); do printf '    def charge_%d(self):\n        return %d\n\n' "$i" "$i"; done
} > "$REPO/src/billing.py"
printf 'def old():\n    pass\n' > "$REPO/src/legacy.py"
printf 'line\n' > "$REPO/src/old_name.py"
commit_all base
BASE=$(git -C "$REPO" rev-parse HEAD)
sed -i.bak -E 's/return (50|100|150|200|250|300)$/return \1 * 2/' "$REPO/src/billing.py" && rm "$REPO/src/billing.py.bak"
git -C "$REPO" rm -q src/legacy.py
git -C "$REPO" mv src/old_name.py src/new_name.py
seq 1 1200 > "$REPO/src/added.txt"
seq 1 5000 > "$REPO/Cargo.lock"
commit_all change
OUT=$(diff_since "$BASE" | run)
LOG=$(diff_since "$BASE" | "$SCRIPT" 2>&1 >/dev/null)

assert_contains "large: summary section" "## Diff summary" "$OUT"
assert_not_contains "large: raw diff omitted" "return 50 * 2" "$OUT"
assert_contains "large: modified file row" '| modified | `src/billing.py` | +6 / -6 |' "$OUT"
assert_contains "large: deleted file row" '| deleted | `src/legacy.py` | +0 / -2 |' "$OUT"
assert_contains "large: renamed file row" '| renamed | `src/new_name.py (from src/old_name.py)` | +0 / -0 |' "$OUT"
assert_contains "large: added file row" '| added | `src/added.txt` | +1200 / -0 |' "$OUT"
assert_contains "large: totals" "Files changed: 4 (+1206 / -8)" "$OUT"
assert_contains "large: hunk context" '- `class Billing:`' "$OUT"
assert_contains "large: lock file excluded" '`Cargo.lock`' "$OUT"
assert_contains "large: log explains decision" "sending summary" "$LOG"
FIRST_ROW=$(grep -m1 '^| [a-z]* | `' <<< "$OUT")
assert_contains "large: sorted by churn" "src/added.txt" "$FIRST_ROW"
# Unique contexts per file are capped
CAPPED=$(printf 'diff --git a/m.c b/m.c\n--- a/m.c\n+++ b/m.c\n%s' \
  "$(for i in $(seq 1 15); do printf '@@ -%d +%d @@ int fn_%d(void)\n-a\n+b\n' "$i" "$i" "$i"; done)" \
  | MAX_DIFF_LINES=0 run)
CTX_COUNT=$(grep -c '^- `int fn_' <<< "$CAPPED" || true)
if [ "$CTX_COUNT" -eq 10 ]; then pass "large: hunk contexts capped at 10"; else fail "large: hunk contexts capped at 10 (got $CTX_COUNT)"; fi

# Lock file must not count toward the threshold
OUT=$(diff_since "$BASE" | MAX_DIFF_LINES=100000 run)
assert_contains "large: under raised limit sends full diff" "## Diff" "$OUT"
assert_not_contains "large: under raised limit no summary" "## Diff summary" "$OUT"
rm -rf "$REPO"

# --- Lock file push: below limit only because lock is excluded ---------------
new_repo
printf 'a\n' > "$REPO/README.md"
commit_all base
BASE=$(git -C "$REPO" rev-parse HEAD)
printf 'b\n' > "$REPO/README.md"
seq 1 5000 > "$REPO/pnpm-lock.yaml"
commit_all change
OUT=$(diff_since "$BASE" | run)
assert_contains "threshold: counted after filtering" "## Diff" "$OUT"
assert_not_contains "threshold: not summarized" "## Diff summary" "$OUT"
rm -rf "$REPO"

# --- Only noise files: nothing to send ---------------------------------------
new_repo
echo x > "$REPO/README.md"
commit_all base
BASE=$(git -C "$REPO" rev-parse HEAD)
seq 1 100 > "$REPO/go.sum"
seq 1 100 > "$REPO/Gemfile.lock"
mkdir -p "$REPO/node_modules/x" && echo y > "$REPO/node_modules/x/index.js"
commit_all change
OUT=$(diff_since "$BASE" | run)
assert_empty "noise-only: prints nothing" "$OUT"
rm -rf "$REPO"

# --- Empty input -------------------------------------------------------------
OUT=$(printf '' | run)
assert_empty "empty input: prints nothing" "$OUT"

# --- Paths without a/ b/ prefixes still parse --------------------------------
OUT=$(printf 'diff --git x/y.txt x/y.txt\n--- /dev/null\n+++ b/docs/guide.md\n@@ -0,0 +1 @@\n+hello\n' | run)
assert_contains "gh-style new file: included" "+hello" "$OUT"

# --- Invalid limit -----------------------------------------------------------
if printf '' | MAX_DIFF_LINES=abc "$SCRIPT" 2>/dev/null; then
  fail "invalid MAX_DIFF_LINES rejected"
else
  pass "invalid MAX_DIFF_LINES rejected"
fi

echo ""
if [ "$FAILURES" -eq 0 ]; then
  echo "All tests passed"
else
  echo "$FAILURES test(s) failed"
  exit 1
fi
