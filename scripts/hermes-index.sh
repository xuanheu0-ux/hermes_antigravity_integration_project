#!/usr/bin/env bash
# hermes-index.sh — build the drop-zone map that keeps Hermes' prompt small.
#
# WHY THIS EXISTS
# The 2026-06-02 session log "fixed" 3-minute-per-token CPU inference by dropping a
# .hermesignore into the workspace root. Hermes never reads that file (upstream issue
# #50165 still asks for it), so the prompt bloat was never actually solved — only
# hidden by also trimming terminal.cwd. The real lever is: give the agent ONE small
# file to read instead of a 400 000-file walk. That file is INDEX.md.
#
# WHAT IT DOES
#   for each project in the drop zone:  file count, top-level layout, detected stack,
#   key files, git HEAD/branch/date, top extensions  ->  <dropzone>/INDEX.md
#
# USAGE
#   scripts/hermes-index.sh [options]
#     --dropzone DIR   directory to scan        (default: $HERMES_DROPZONE or ./hermes_shared_workspace)
#     --out FILE       output path              (default: <dropzone>/INDEX.md)
#     --ignore FILE    ignore list              (default: <dropzone>/.hermesignore, else repo .hermesignore)
#     --max N          file paths listed per project (default 800; counts are still exact up to 5000)
#     --check          exit 1 if INDEX.md is missing/stale, exit 0 if up to date (no write)
#     --quiet          no stdout
#     -h|--help
#
# Exit codes: 0 ok (or up to date with --check) / 1 stale (--check) or usage error / 2 no drop zone.
# POSIX-ish bash, no GNU-only deps beyond `find`, `sort`, `awk`, `sed`, `git` (optional).

set -eu  # deliberately no `pipefail`: `find | head` and `sort | head`
# legitimately SIGPIPE the producer (exit 141); under pipefail that would abort the report
# generator halfway, which is far worse than missing a broken-producer signal.

MAX_LIST=800
COUNT_CAP=5000
QUIET=0
CHECK=0
DROPZONE=""
OUT=""
IGNORE=""

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() { echo "hermes-index: $*" >&2; exit "${2:-1}"; }
say() { [ "$QUIET" = 1 ] || echo "hermes-index: $*"; }

usage() {
  cat <<'EOF'
usage: scripts/hermes-index.sh [--dropzone DIR] [--out FILE] [--ignore FILE]
                               [--max N] [--check] [--quiet]

  --dropzone DIR   directory to scan (default: $HERMES_DROPZONE or ./hermes_shared_workspace)
  --out FILE       output path       (default: <dropzone>/INDEX.md)
  --ignore FILE    ignore list       (default: <dropzone>/.hermesignore, else repo .hermesignore)
  --max N          file paths listed per project (default 800)
  --check          exit 1 if INDEX.md is missing/stale, 0 if current (writes nothing)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dropzone) DROPZONE="${2:-}"; shift 2 ;;
    --out)      OUT="${2:-}"; shift 2 ;;
    --ignore)   IGNORE="${2:-}"; shift 2 ;;
    --max)      MAX_LIST="${2:-}"; shift 2 ;;
    --check)    CHECK=1; shift ;;
    --quiet)    QUIET=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

# --- load .env for HERMES_DROPZONE if the caller did not pass --dropzone --------------
if [ -z "$DROPZONE" ] && [ -f "$repo_root/.env" ]; then
  DROPZONE="$(sed -n 's/^HERMES_DROPZONE=//p' "$repo_root/.env" | tail -1)"
fi
DROPZONE="${DROPZONE:-$repo_root/hermes_shared_workspace}"
case "$DROPZONE" in
  /*) : ;;
  *) DROPZONE="$repo_root/${DROPZONE#./}" ;;
esac
[ -d "$DROPZONE" ] || { echo "hermes-index: drop zone not found: $DROPZONE" >&2
                        echo "  create it (and add symlinks to your projects), or pass --dropzone" >&2
                        exit 2; }

if [ -z "$IGNORE" ]; then
  if [ -f "$DROPZONE/.hermesignore" ]; then IGNORE="$DROPZONE/.hermesignore"
  else IGNORE="$repo_root/.hermesignore"; fi
fi

OUT="${OUT:-$DROPZONE/INDEX.md}"

# --- build the prune expression from the ignore list ----------------------------------
# Basename globs, matched at any depth. Directory matches are pruned (never descended),
# file matches are silently dropped from the listing.
find_expr=()
if [ -f "$IGNORE" ]; then
  while IFS= read -r line; do
    pat="${line%%#*}"
    pat="$(printf '%s' "$pat" | tr -d '[:space:]')"
    [ -n "$pat" ] || continue
    case "$pat" in
      '!'*) continue ;;                       # negations are not supported while walking
      *'/') pat="${pat%/}" ;;                 # `node_modules/` -> `node_modules`
    esac
    [ -n "$pat" ] || continue
    [ "${#find_expr[@]}" -gt 0 ] && find_expr+=( -o )
    find_expr+=( -name "$pat" )
  done < "$IGNORE"
  say "ignore list: $IGNORE (${#find_expr[@]} tokens)"
else
  say "no .hermesignore found — indexing everything (slow and prompt-hostile)"
fi

if [ "${#find_expr[@]}" -gt 0 ]; then
  PRUNE=( \( \( "${find_expr[@]}" \) -prune \) -o )
else
  PRUNE=()
fi

# list_files <dir> -> newline list of paths (trailing slash makes find follow a
# symlinked project dir without following links inside it)
list_files() {
  local root="$1" cap="${2:-$COUNT_CAP}"
  find "$root/" "${PRUNE[@]}" -type f -print 2>/dev/null | head -n "$((cap + 1))"
}

# --- walk the drop zone ----------------------------------------------------------------
tmp="$(mktemp "${TMPDIR:-/tmp}/hermes-index.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

{
  echo "# Drop Zone Index"
  echo
  echo "<!-- Generated by scripts/hermes-index.sh. Read this BEFORE opening files: it is"
  echo "     deliberately small so your system prompt stays cheap on CPU inference. -->"
  echo
  echo "- generated_utc: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "- dropzone: \`$DROPZONE\`"
  echo "- ignore_list: \`$IGNORE\`"
  echo "- listed_per_project_max: $MAX_LIST"
  echo
} > "$tmp"

projects=0; total_files=0
for entry in "$DROPZONE"/*/; do
  [ -d "$entry" ] || continue
  name="$(basename "$entry")"
  [ "$name" = "outbox" ] && continue
  files="$(list_files "${entry%/}")" || true
  if [ -z "$files" ]; then
    {
      echo "## $name"
      echo
      echo "_No files matched the ignore list (empty project, or everything is ignored)._"
      echo
    } >> "$tmp"
    projects=$((projects + 1))
    continue
  fi
  count="$(printf '%s\n' "$files" | grep -c '' || true)"
  truncated=0
  if [ "$count" -gt "$COUNT_CAP" ]; then count="$COUNT_CAP"; truncated=1; fi
  listed="$(printf '%s\n' "$files" | head -n "$MAX_LIST" | sed "s#^${entry%/}/##")"
  n_listed="$(printf '%s\n' "$listed" | grep -c '' || true)"
  projects=$((projects + 1)); total_files=$((total_files + count))

  {
    echo "## $name"
    echo
    printf -- '- files: %s%s\n' "$count" "$([ "$truncated" = 1 ] && printf ' (>= %s, walk capped)' "$COUNT_CAP")"
    # stack detection from manifests (unique basenames: one sed, then cheap matching)
    basenames="$(printf '%s\n' "$listed" | sed 's#.*/##' | sort -u)"
    stacks=""
    for m in package.json:node deno.json:deno pyproject.toml:python \
             requirements.txt:python setup.py:python Pipfile:python go.mod:go \
             Cargo.toml:rust pom.xml:java build.gradle:java composer.json:php \
             CMakeLists.txt:cmake Makefile:make platformio.ini:embedded \
             docker-compose.yml:docker Dockerfile:docker "*.kicad_pcb":kicad \
             "*.ewprj":eplan "*.dwg":autocad "*.twincat":twincat "*.pro":plc_program; do
      mf="${m%%:*}"; label="${m##*:}"
      while IFS= read -r bn; do
        # shellcheck disable=SC2053  # $mf is intentionally an unquoted glob pattern
        case "$bn" in $mf) stacks="$stacks $label"; break ;; esac
      done <<< "$basenames"
    done
    [ -n "$stacks" ] && printf -- '- stack:%s\n' "$stacks"
    # top extensions
    exts="$(printf '%s\n' "$listed" | awk -F. 'NF>1 && $NF !~ /\// {print tolower($NF)}' \
            | sort | uniq -c | sort -rn | head -6 \
            | awk '{printf "%s(%s) ", $2, $1}')"
    [ -n "$exts" ] && printf -- '- by_extension: %s\n' "${exts% }"
    # top-level layout
    tops="$(printf '%s\n' "$listed" | awk -F/ '{print $1}' | sort -u | head -20 | paste -sd' ' -)"
    [ -n "$tops" ] && printf -- '- top_level: %s\n' "$tops"
    # key files worth reading first
    keys="$(printf '%s\n' "$listed" | grep -iE '(^|/)(README|readme|ARCHITECTURE|CHANGELOG|SPEC|NOTES)(\..*)?$|(^|/)(package\.json|pyproject\.toml|go\.mod|Cargo\.toml|Makefile|CMakeLists\.txt|docker-compose\.[ay]?ml)$' | head -8 | paste -sd', ' -)"
    [ -n "$keys" ] && printf -- '- key_files: %s\n' "$keys"
    # git provenance (read-only inspection; never writes)
    if command -v git >/dev/null 2>&1 && git -C "${entry%/}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      br="$(git -C "${entry%/}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
      head="$(git -C "${entry%/}" log -1 --format='%h %cd' --date=short 2>/dev/null || echo '?')"
      remote="$(git -C "${entry%/}" config --get remote.origin.url 2>/dev/null | sed -E 's#(https?://)[^@/]+@#\1#' || true)"
      printf -- '- git: branch `%s`, head `%s`%s\n' "$br" "$head" "${remote:+, origin \`$remote\`}"
    fi
    if [ "$n_listed" -lt "$count" ]; then
      printf -- '\n<details><summary>%s of %s paths shown (truncated)</summary>\n\n' "$n_listed" "$count"
      printf '```\n%s\n```\n' "$listed"
      echo '</details>'
    else
      printf '\n```\n%s\n```\n' "$listed"
    fi
    echo
  } >> "$tmp"
done

{
  echo "---"
  echo
  echo "_projects: $projects · indexed file paths: $total_files (capped per project)_"
  echo
  echo "Not listed here = not available to you. Ask the developer to add a symlink:"
  echo '```sh'
  echo "ln -s ~/path/to/project '$DROPZONE/'   # then rerun: scripts/hermes-index.sh"
  echo '```'
} >> "$tmp"

if [ "$CHECK" = 1 ]; then
  if diff -q <(grep -v '^- generated_utc:' "$tmp") <(grep -v '^- generated_utc:' "$OUT" 2>/dev/null) >/dev/null 2>&1; then
    say "INDEX.md is up to date"
    exit 0
  fi
  echo "hermes-index: INDEX.md is stale or missing -> rerun without --check" >&2
  exit 1
fi

if [ -f "$OUT" ] && diff -q <(grep -v '^- generated_utc:' "$tmp") <(grep -v '^- generated_utc:' "$OUT") >/dev/null 2>&1; then
  say "unchanged, leaving $OUT alone"
  exit 0
fi

cat "$tmp" > "$OUT"
say "wrote $OUT ($projects project(s), $total_files file path(s))"
