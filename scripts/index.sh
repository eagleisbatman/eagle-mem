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

force=false
args=()

show_help() {
    echo -e "  ${BOLD}eagle-mem index${RESET} — Index source files and wire code graph declarations"
    echo ""
    echo -e "  ${BOLD}Usage:${RESET}"
    echo -e "    eagle-mem index [path]              ${DIM}# incrementally index changed files${RESET}"
    echo -e "    eagle-mem index ${CYAN}--force${RESET} [path]      ${DIM}# rebuild chunks and static code graph edges${RESET}"
    echo ""
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --force|-f) force=true; shift ;;
        --help|-h) show_help ;;
        *) args+=("$1"); shift ;;
    esac
done

TARGET_DIR="${args[0]:-.}"
TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"
PROJECT=$(eagle_project_from_cwd "$TARGET_DIR")

TMPDIR_IDX=""
cleanup_index() {
    local rc=$?
    [ -n "${TMPDIR_IDX:-}" ] && rm -rf "$TMPDIR_IDX" 2>/dev/null || true
    eagle_run_finish "$rc" "$LINENO"
}
eagle_run_start "index" "$PROJECT" "$TARGET_DIR"
trap cleanup_index EXIT

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

sql_literal_expr() {
    awk '
        BEGIN { first = 1 }
        {
            gsub(/\047/, "\047\047")
            if (!first) {
                printf "||char(10)||"
            }
            printf "\047%s\047", $0
            first = 0
        }
        END {
            if (first) {
                printf "\047\047"
            }
        }
    '
}

# ─── Collect files ─────────────────────────────────────────

TMPDIR_IDX=$(mktemp -d)

ALL_FILES="$TMPDIR_IDX/all_files"

eagle_run_step "collect_files"
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

if [ "$force" = true ]; then
    eagle_run_step "force_clear_index_state"
    eagle_info "Force rebuild requested: clearing chunks, declarations, and import edges"
    eagle_graph_clear_index_state "$PROJECT"
fi

while IFS= read -r file; do
    full_path="$TARGET_DIR/$file"
    current_mtime=$(stat -f '%m' "$full_path" 2>/dev/null || stat -c '%Y' "$full_path" 2>/dev/null || echo "0")

    if [ "$force" = true ]; then
        echo "$file"
        continue
    fi

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
eagle_run_step "index_files count=$needs_count"

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
        content_expr=$(printf '%s\n' "$content" | sql_literal_expr)

        txn_sql+="
INSERT INTO code_chunks (project, file_path, language, start_line, end_line, content, mtime)
VALUES ('$project_sql', '$file_sql', '$lang_sql', $start, $end, $content_expr, $current_mtime);"

        chunk_count=$((chunk_count + 1))
        start=$((end + 1))
    done

    txn_sql+="
COMMIT;"

    eagle_db_pipe <<< "$txn_sql"

    # Static syntax relation extraction & graph wiring
    # Wire node & edge static parser
    overview=$(eagle_get_overview "$PROJECT" 2>/dev/null || true)
    eagle_graph_add_node "$PROJECT" "project" "$PROJECT" "$overview" ""
    project_node_id=$(eagle_graph_get_node_id "$PROJECT" "project" "$PROJECT")
    eagle_graph_add_node "$PROJECT" "file" "$file" "" "$full_path"
    file_node_id=$(eagle_graph_get_node_id "$PROJECT" "file" "$file")
    if [ -n "$file_node_id" ]; then
        if [ -n "$project_node_id" ]; then
            eagle_graph_add_edge "$PROJECT" "$project_node_id" "$file_node_id" "contains" 1.0 >/dev/null || true
        fi
        eagle_graph_reset_file_static_edges "$PROJECT" "$file" "$file_node_id"

        # 1. Parse function/class declarations
        # e.g., "def name", "class name", "fn name", "function name", "func name"
        declarations=$(grep -oE '\<(class|struct|function|def|fn|func)[[:space:]]+[A-Za-z0-9_]+' "$full_path" 2>/dev/null | awk '{print $1 ":" $2}' | sort -u || true)
        if [ -n "$declarations" ]; then
            while IFS=':' read -r dtype dname; do
                [ -z "$dname" ] && continue
                decl_node_name=$(eagle_graph_declaration_node_name "$file" "$dname")
                eagle_graph_add_node "$PROJECT" "$dtype" "$decl_node_name" "Declared $dname in $file" "$file"
                decl_node_id=$(eagle_graph_get_node_id "$PROJECT" "$dtype" "$decl_node_name")
                if [ -n "$decl_node_id" ]; then
                    eagle_graph_add_edge "$PROJECT" "$file_node_id" "$decl_node_id" "declares" 1.0
                fi
            done <<< "$declarations"
        fi

        # 2. Parse local relative imports/requires/sources
        # Matches quoted paths starting with ./ or ../ and shell source lines.
        local_imports=$(grep -oE "['\"](\./[^'\"]+|\.\./[^'\"]+)['\"]" "$full_path" 2>/dev/null | tr -d "'\"" || true)
        shell_sources=""
        case "$file" in
            *.sh|*.bash|*.zsh|*.envrc|.envrc)
                shell_sources=$(grep -E "^[[:space:]]*(source[[:space:]]+|\. [^[:space:]])" "$full_path" 2>/dev/null | sed -E "s/^[[:space:]]*(source[[:space:]]+|\. )([^#[:space:]]+).*/\\2/" || true)
                ;;
        esac
        
        all_refs=$(printf "%s\n%s\n" "$local_imports" "$shell_sources" | sort -u)
        if [ -n "$all_refs" ]; then
            while IFS= read -r ref; do
                [ -z "$ref" ] && continue
                # Clean up path variables in shell sources (e.g. $_eagle_db_dir/db-core.sh -> db-core.sh)
                ref_clean=$(echo "$ref" | sed -E 's/.*\///; s/\.sh$//; s/\.js$//; s/\.ts$//')
                [ -z "$ref_clean" ] && continue
                ref_sql=$(eagle_sql_escape "$ref_clean")
                
                # Check if there is a known file node in our graph that matches this basename or path
                matched_file=$(eagle_db "SELECT node_name FROM graph_nodes WHERE project = '$project_sql' AND node_type = 'file' AND (node_name LIKE '%/$ref_sql%' OR node_name = '$ref_sql') LIMIT 1;")
                if [ -n "$matched_file" ]; then
                    target_file_id=$(eagle_graph_get_node_id "$PROJECT" "file" "$matched_file")
                    if [ -n "$target_file_id" ]; then
                        eagle_graph_add_edge "$PROJECT" "$file_node_id" "$target_file_id" "imports" 1.0
                    fi
                fi
            done <<< "$all_refs"
        fi
    fi

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
