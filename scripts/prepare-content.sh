#!/usr/bin/env bash
# Reads a unified git diff (with a/ and b/ path prefixes) on stdin and prints
# the diff section of the Brainfish payload on stdout.
#
# - Lock files, generated/minified files, vendored code and binary files are
#   always dropped.
# - If the remaining diff is at most MAX_DIFF_LINES lines it is printed in full,
#   otherwise only a deterministic summary is printed.
# - Prints nothing when no files remain after filtering.
#
# A one-line description of the decision is written to stderr.
set -euo pipefail

MAX_DIFF_LINES="${MAX_DIFF_LINES:-1000}"
MAX_SUMMARY_FILES="${MAX_SUMMARY_FILES:-300}"
MAX_CONTEXTS_PER_FILE="${MAX_CONTEXTS_PER_FILE:-10}"
MAX_LISTED_EXCLUDED="${MAX_LISTED_EXCLUDED:-20}"

for var in MAX_DIFF_LINES MAX_SUMMARY_FILES MAX_CONTEXTS_PER_FILE MAX_LISTED_EXCLUDED; do
  if ! [[ "${!var}" =~ ^[0-9]+$ ]]; then
    echo "$var must be a non-negative integer, got '${!var}'" >&2
    exit 1
  fi
done

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
: > "$WORK/kept.diff"
: > "$WORK/stats.tsv"
: > "$WORK/excluded.txt"

# Split the diff into per-file blocks. Kept blocks go to kept.diff (without the
# "diff --git" and "index" noise lines); one TSV row per kept file goes to
# stats.tsv: churn, status, path, additions, deletions, hunk contexts (\037-separated).
awk \
  -v kept="$WORK/kept.diff" \
  -v stats="$WORK/stats.tsv" \
  -v excluded="$WORK/excluded.txt" \
  -v maxctx="$MAX_CONTEXTS_PER_FILE" '
function is_noise(p,   base) {
  base = p
  sub(/.*\//, "", base)
  if (base == "package-lock.json" || base == "npm-shrinkwrap.json" || \
      base == "pnpm-lock.yaml" || base == "go.sum") return 1
  if (p ~ /\.lockb?$/) return 1
  if (p ~ /\.min\.(js|css)$/ || p ~ /\.map$/ || p ~ /\.snap$/) return 1
  if (p ~ /(^|\/)(dist|build|node_modules|vendor)\//) return 1
  return 0
}
function strip_prefix(p) {
  sub(/^[ab]\//, "", p)
  return p
}
function flush(   i, name, shown) {
  if (n == 0) return
  name = path
  if (name == "") name = oldpath
  if (name == "") name = hdr_path
  if (binary || is_noise(name)) {
    print name > excluded
  } else {
    for (i = 1; i <= n; i++)
      if (buf[i] !~ /^diff --git / && buf[i] !~ /^index /) print buf[i] > kept
    shown = name
    if (status == "renamed" && from != "") shown = name " (from " from ")"
    printf "%d\t%s\t%s\t%d\t%d\t%s\n", adds + dels, status, shown, adds, dels, ctx > stats
  }
  n = 0
}
/^diff --git / {
  flush()
  s = $0
  sub(/^diff --git /, "", s)
  i = index(s, " b/")
  hdr_path = (i > 0) ? substr(s, i + 3) : s
  path = ""; oldpath = ""; from = ""; status = "modified"
  binary = 0; in_hunk = 0; adds = 0; dels = 0; ctx = ""; nctx = 0
  delete seen
}
{ buf[++n] = $0 }
/^@@ / {
  in_hunk = 1
  c = $0
  sub(/^@@ [^@]* @@ ?/, "", c)
  if (c != "" && nctx < maxctx + 0 && !(c in seen)) {
    seen[c] = 1
    ctx = ctx (nctx ? "\037" : "") c
    nctx++
  }
  next
}
!in_hunk {
  if ($0 ~ /^new file mode/) status = "added"
  else if ($0 ~ /^deleted file mode/) status = "deleted"
  else if ($0 ~ /^rename from /) { status = "renamed"; from = substr($0, 13) }
  else if ($0 ~ /^rename to /) { status = "renamed"; path = substr($0, 11) }
  else if ($0 ~ /^\+\+\+ /) { p = substr($0, 5); if (p != "/dev/null") path = strip_prefix(p) }
  else if ($0 ~ /^--- /) { p = substr($0, 5); if (p != "/dev/null") oldpath = strip_prefix(p) }
  else if ($0 ~ /^Binary files / || $0 ~ /^GIT binary patch/) binary = 1
  next
}
/^\+/ { adds++; next }
/^-/ { dels++; next }
END { flush() }
'

FILES=$(wc -l < "$WORK/stats.tsv" | tr -d ' ')
EXCLUDED=$(wc -l < "$WORK/excluded.txt" | tr -d ' ')
LINES=$(wc -l < "$WORK/kept.diff" | tr -d ' ')

if [ "$FILES" -eq 0 ]; then
  echo "No changes left after excluding $EXCLUDED lock, generated or binary file(s)" >&2
  exit 0
fi

print_excluded() {
  if [ "$EXCLUDED" -gt 0 ]; then
    local listed
    listed=$(head -n "$MAX_LISTED_EXCLUDED" "$WORK/excluded.txt" | awk '{ printf "%s`%s`", (NR > 1 ? ", " : ""), $0 }')
    if [ "$EXCLUDED" -gt "$MAX_LISTED_EXCLUDED" ]; then
      listed="$listed and $((EXCLUDED - MAX_LISTED_EXCLUDED)) more"
    fi
    echo "Excluded $EXCLUDED lock, generated or binary file(s): $listed"
    echo ""
  fi
}

if [ "$LINES" -le "$MAX_DIFF_LINES" ]; then
  echo "Diff: $LINES lines across $FILES file(s), $EXCLUDED excluded; sending full diff" >&2
  echo "## Diff"
  echo ""
  print_excluded
  cat "$WORK/kept.diff"
  exit 0
fi

echo "Diff: $LINES lines across $FILES file(s), $EXCLUDED excluded; over $MAX_DIFF_LINES lines, sending summary" >&2

sort -t "$(printf '\t')" -k1,1nr "$WORK/stats.tsv" > "$WORK/sorted.tsv"

echo "## Diff summary"
echo ""
echo "The full diff is $LINES lines, which is over the $MAX_DIFF_LINES-line limit, so only a summary is included. Files are ordered by the number of changed lines."
echo ""
print_excluded

awk -F '\t' '
{ adds += $4; dels += $5 }
END {
  printf "Files changed: %d (+%d / -%d)\n\n", NR, adds, dels
}
' "$WORK/sorted.tsv"

echo "### Files"
echo ""
echo "| Status | File | Lines |"
echo "|----|----|----|"
awk -F '\t' -v maxfiles="$MAX_SUMMARY_FILES" '
NR <= maxfiles + 0 { printf "| %s | `%s` | +%d / -%d |\n", $2, $3, $4, $5 }
END { if (NR > maxfiles + 0) printf "\n%d more file(s) omitted.\n", NR - maxfiles }
' "$WORK/sorted.tsv"
echo ""

if awk -F '\t' '$6 != "" { found = 1 } END { exit !found }' "$WORK/sorted.tsv"; then
  echo "### Changed areas"
  echo ""
  echo "Functions, classes or sections touched in each file, taken from the diff hunk headers."
  echo ""
  awk -F '\t' -v maxfiles="$MAX_SUMMARY_FILES" '
  NR <= maxfiles + 0 && $6 != "" {
    printf "#### `%s`\n\n", $3
    n = split($6, parts, "\037")
    for (i = 1; i <= n; i++) printf "- `%s`\n", parts[i]
    printf "\n"
  }
  ' "$WORK/sorted.tsv"
fi
