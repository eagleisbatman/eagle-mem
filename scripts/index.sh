#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Index
# Chunks source files and indexes them for FTS5 code search
# Incremental: only re-indexes files that changed since last run
# ═══════════════════════════════════════════════════════════
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPTS_DIR/../lib"

. "$SCRIPTS_DIR/style.sh"
. "$LIB_DIR/common.sh"
. "$LIB_DIR/db.sh"

eagle_ensure_db

TARGET_DIR="${1:-.}"
TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"
PROJECT=$(eagle_project_from_cwd "$TARGET_DIR")

CHUNK_SIZE="${EAGLE_MEM_CHUNK_SIZE:-80}"
if ! [[ "$CHUNK_SIZE" =~ ^[0-9]+$ ]] || [ "$CHUNK_SIZE" -lt 1 ]; then
    CHUNK_SIZE=80
fi
MAX_FILE_SIZE=1048576  # 1MB

eagle_header "Index"
eagle_info "Indexing ${BOLD}$PROJECT${RESET} at $TARGET_DIR"
echo ""

# ─── Source file extensions to index ───────────────────────

SOURCE_EXTS="sh|bash|zsh|js|jsx|mjs|cjs|ts|tsx|mts|py|rb|go|rs|java|kt|kts|swift|c|h|cpp|cc|cxx|hpp|cs|php|sql|html|htm|css|scss|vue|svelte|dart|ex|exs|zig|lua|r|scala|yaml|yml|toml|json|md"

ext_to_lang() {
    case "$1" in
        sh|bash|zsh) echo "Bash" ;;
        js|jsx|mjs|cjs) echo "JavaScript" ;;
        ts|tsx|mts) echo "TypeScript" ;;
        py) echo "Python" ;;
        rb) echo "Ruby" ;;
        go) echo "Go" ;;
        rs) echo "Rust" ;;
        java) echo "Java" ;;
        kt|kts) echo "Kotlin" ;;
        swift) echo "Swift" ;;
        c|h) echo "C" ;;
        cpp|cc|cxx|hpp) echo "C++" ;;
        cs) echo "C#" ;;
        php) echo "PHP" ;;
        sql) echo "SQL" ;;
        html|htm) echo "HTML" ;;
        css|scss|sass|less) echo "CSS" ;;
        vue) echo "Vue" ;;
        svelte) echo "Svelte" ;;
        dart) echo "Dart" ;;
        ex|exs) echo "Elixir" ;;
        zig) echo "Zig" ;;
        lua) echo "Lua" ;;
        r) echo "R" ;;
        scala) echo "Scala" ;;
        yaml|yml) echo "YAML" ;;
        toml) echo "TOML" ;;
        json) echo "JSON" ;;
        md) echo "Markdown" ;;
        *) echo "" ;;
    esac
}

# ─── Collect files ─────────────────────────────────────────

TMPDIR_IDX=$(mktemp -d)
trap 'rm -rf "$TMPDIR_IDX"' EXIT

ALL_FILES="$TMPDIR_IDX/all_files"

eagle_collect_files "$TARGET_DIR" "$ALL_FILES"

# Filter to source files only, skip large files
SOURCE_FILES="$TMPDIR_IDX/source_files"
while IFS= read -r file; do
    ext="${file##*.}"
    [ "$ext" = "$file" ] && continue
    ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
    echo "$ext" | grep -qE "^($SOURCE_EXTS)$" || continue
    full_path="$TARGET_DIR/$file"
    [ ! -f "$full_path" ] && continue
    file_size=$(wc -c < "$full_path" 2>/dev/null | tr -d ' ')
    [ "$file_size" -gt "$MAX_FILE_SIZE" ] && continue
    echo "$file"
done < "$ALL_FILES" > "$SOURCE_FILES"

total_source=$(wc -l < "$SOURCE_FILES" | tr -d ' ')
eagle_ok "$total_source source files found"

if [ "$total_source" -eq 0 ]; then
    eagle_info "Nothing to index"
    exit 0
fi

# ─── Check which files need re-indexing ────────────────────

project_sql=$(eagle_sql_escape "$PROJECT")
NEEDS_INDEX="$TMPDIR_IDX/needs_index"

skipped_count=0

while IFS= read -r file; do
    full_path="$TARGET_DIR/$file"
    current_mtime=$(stat -f '%m' "$full_path" 2>/dev/null || stat -c '%Y' "$full_path" 2>/dev/null || echo "0")

    stored_mtime=$(eagle_db "SELECT MAX(mtime) FROM code_chunks WHERE project = '$project_sql' AND file_path = '$(eagle_sql_escape "$file")';")

    if [ -n "$stored_mtime" ] && [ "$stored_mtime" = "$current_mtime" ]; then
        skipped_count=$((skipped_count + 1))
        continue
    fi

    echo "$file"
done < "$SOURCE_FILES" > "$NEEDS_INDEX"

needs_count=$(wc -l < "$NEEDS_INDEX" | tr -d ' ')

if [ "$skipped_count" -gt 0 ]; then
    eagle_ok "$skipped_count files unchanged (skipped)"
fi

if [ "$needs_count" -eq 0 ]; then
    eagle_ok "Index is up to date"
    eagle_footer "Nothing to index."
    exit 0
fi

eagle_info "$needs_count files to index"

# ─── Chunk and index files ─────────────────────────────────

echo ""

chunk_count=0
file_count=0

while IFS= read -r file; do
    full_path="$TARGET_DIR/$file"
    ext="${file##*.}"
    ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
    lang=$(ext_to_lang "$ext")
    current_mtime=$(stat -f '%m' "$full_path" 2>/dev/null || stat -c '%Y' "$full_path" 2>/dev/null || echo "0")
    file_sql=$(eagle_sql_escape "$file")
    lang_sql=$(eagle_sql_escape "$lang")

    total_lines=$(wc -l < "$full_path" 2>/dev/null | tr -d ' ')
    [ "$total_lines" -eq 0 ] && continue

    # Build all INSERTs for this file, then run as a single atomic transaction
    txn_sql="BEGIN;
DELETE FROM code_chunks WHERE project = '$project_sql' AND file_path = '$file_sql';"

    start=1
    while [ "$start" -le "$total_lines" ]; do
        end=$((start + CHUNK_SIZE - 1))
        [ "$end" -gt "$total_lines" ] && end="$total_lines"

        content=$(sed -n "${start},${end}p" "$full_path" | eagle_redact)
        content_sql=$(eagle_sql_escape "$content")

        txn_sql+="
INSERT INTO code_chunks (project, file_path, language, start_line, end_line, content, mtime)
VALUES ('$project_sql', '$file_sql', '$lang_sql', $start, $end, '$content_sql', $current_mtime);"

        chunk_count=$((chunk_count + 1))
        start=$((end + 1))
    done

    txn_sql+="
COMMIT;"

    eagle_db_pipe <<< "$txn_sql"

    file_count=$((file_count + 1))

    if [ $((file_count % 10)) -eq 0 ]; then
        printf "  \r  ${ARROW}  Indexed %d / %d files (%d chunks)..." "$file_count" "$needs_count" "$chunk_count"
    fi
done < "$NEEDS_INDEX"

echo ""
eagle_ok "Indexed $file_count files ($chunk_count chunks)"

# ─── Summary ──────────────────────────────────────────────

total_chunks=$(eagle_db "SELECT COUNT(*) FROM code_chunks WHERE project = '$project_sql';")
total_indexed=$(eagle_db "SELECT COUNT(DISTINCT file_path) FROM code_chunks WHERE project = '$project_sql';")

echo ""
eagle_footer "Index complete."
eagle_kv "Project:" "$PROJECT"
eagle_kv "Files indexed:" "$total_indexed"
eagle_kv "Total chunks:" "$total_chunks"
eagle_kv "Chunk size:" "$CHUNK_SIZE lines"
eagle_kv "Database:" "$EAGLE_MEM_DB"
echo ""
