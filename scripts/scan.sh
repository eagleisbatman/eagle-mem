#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — Scan
# Analyzes a project's codebase and generates a brief overview
# Stored in the overviews table, auto-injected at session start
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

eagle_header "Scan"
eagle_info "Scanning ${BOLD}$PROJECT${RESET} at $TARGET_DIR"
echo ""

# ─── Collect files ─────────────────────────────────────────

is_git=false
if git -C "$TARGET_DIR" rev-parse --is-inside-work-tree &>/dev/null; then
    is_git=true
fi

TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

eagle_collect_files "$TARGET_DIR" "$TMPFILE"

total_files=$(wc -l < "$TMPFILE" | tr -d ' ')

if [ "$total_files" -eq 0 ]; then
    eagle_fail "No files found in $TARGET_DIR"
    exit 1
fi

eagle_ok "$total_files files found"

# ─── Language breakdown (bash 3 compatible — no assoc arrays) ──

while IFS= read -r file; do
    ext="${file##*.}"
    [ "$ext" = "$file" ] && continue
    if [ -f "$TARGET_DIR/$file" ]; then
        lines=$(wc -l < "$TARGET_DIR/$file" 2>/dev/null | tr -d ' ')
    else
        lines=0
    fi
    echo "$ext $lines"
done < "$TMPFILE" | awk '
BEGIN {
    m["sh"]="Bash"; m["bash"]="Bash"; m["zsh"]="Bash"
    m["js"]="JavaScript"; m["jsx"]="JavaScript"; m["mjs"]="JavaScript"; m["cjs"]="JavaScript"
    m["ts"]="TypeScript"; m["tsx"]="TypeScript"; m["mts"]="TypeScript"
    m["py"]="Python"; m["rb"]="Ruby"; m["go"]="Go"; m["rs"]="Rust"
    m["java"]="Java"; m["kt"]="Kotlin"; m["kts"]="Kotlin"; m["swift"]="Swift"
    m["c"]="C"; m["h"]="C"; m["cpp"]="C++"; m["cc"]="C++"; m["hpp"]="C++"
    m["cs"]="C#"; m["php"]="PHP"; m["sql"]="SQL"
    m["html"]="HTML"; m["htm"]="HTML"
    m["css"]="CSS"; m["scss"]="CSS"; m["sass"]="CSS"; m["less"]="CSS"
    m["json"]="JSON"; m["yaml"]="YAML"; m["yml"]="YAML"; m["toml"]="TOML"
    m["md"]="Markdown"; m["vue"]="Vue"; m["svelte"]="Svelte"; m["dart"]="Dart"
    m["ex"]="Elixir"; m["exs"]="Elixir"; m["zig"]="Zig"; m["lua"]="Lua"
    m["r"]="R"; m["scala"]="Scala"
}
{
    ext = tolower($1); lines = $2
    if (ext in m) {
        lang = m[ext]
        counts[lang]++
        llines[lang] += lines
    }
}
END {
    total = 0
    for (lang in llines) total += llines[lang]
    printf "TOTAL_LINES=%d\n", total

    n = 0
    for (lang in llines) { order[n++] = lang }
    for (i = 0; i < n-1; i++)
        for (j = i+1; j < n; j++)
            if (llines[order[j]] > llines[order[i]]) {
                tmp = order[i]; order[i] = order[j]; order[j] = tmp
            }

    top = (n < 5) ? n : 5
    for (i = 0; i < top; i++) {
        lang = order[i]
        if (llines[lang] >= 1000)
            printf "LANG=%s (%dk lines, %d files)\n", lang, int(llines[lang]/1000), counts[lang]
        else
            printf "LANG=%s (%d lines, %d files)\n", lang, llines[lang], counts[lang]
    }
}
' > "${TMPFILE}.analysis"

total_lines=$(grep '^TOTAL_LINES=' "${TMPFILE}.analysis" | cut -d= -f2)
top_langs=$(grep '^LANG=' "${TMPFILE}.analysis" | sed 's/^LANG=//' | while read -r line; do printf "%s" "${sep:-}${line}"; sep=", "; done)
rm -f "${TMPFILE}.analysis"

[ -n "$top_langs" ] && eagle_ok "Languages: $top_langs"

# ─── Total lines ───────────────────────────────────────────

total_lines="${total_lines:-0}"

if [ "$total_lines" -ge 1000000 ]; then
    scale="$(( total_lines / 1000000 )).$(( (total_lines % 1000000) / 100000 ))M"
elif [ "$total_lines" -ge 1000 ]; then
    scale="$(( total_lines / 1000 ))k"
else
    scale="$total_lines"
fi

# ─── Framework detection ──────────────────────────────────

frameworks=""

detect_framework() {
    local file="$1" indicator="$2"
    if [ -f "$TARGET_DIR/$file" ]; then
        frameworks="${frameworks:+$frameworks, }$indicator"
        return 0
    fi
    return 1
}

detect_dep() {
    local file="$1" dep="$2" indicator="$3"
    if [ -f "$TARGET_DIR/$file" ] && grep -q "\"$dep\"" "$TARGET_DIR/$file" 2>/dev/null; then
        frameworks="${frameworks:+$frameworks, }$indicator"
        return 0
    fi
    return 1
}

# Node.js ecosystem
if [ -f "$TARGET_DIR/package.json" ]; then
    detect_dep "package.json" "next" "Next.js" || true
    detect_dep "package.json" "react" "React" || true
    detect_dep "package.json" "vue" "Vue" || true
    detect_dep "package.json" "svelte" "Svelte" || true
    detect_dep "package.json" "express" "Express" || true
    detect_dep "package.json" "fastify" "Fastify" || true
    detect_dep "package.json" "hono" "Hono" || true
    detect_dep "package.json" "nestjs" "NestJS" || true
    detect_dep "package.json" "@anthropic-ai/sdk" "Claude SDK" || true
    detect_dep "package.json" "prisma" "Prisma" || true
    detect_dep "package.json" "drizzle-orm" "Drizzle" || true
    detect_dep "package.json" "tailwindcss" "Tailwind" || true
    if [ -z "$frameworks" ]; then
        frameworks="Node.js"
    fi
fi

# Python
detect_framework "requirements.txt" "Python" || true
detect_framework "pyproject.toml" "Python" || true
detect_framework "setup.py" "Python" || true
if [ -f "$TARGET_DIR/requirements.txt" ] || [ -f "$TARGET_DIR/pyproject.toml" ]; then
    grep -ql "django" "$TARGET_DIR"/requirements.txt "$TARGET_DIR"/pyproject.toml 2>/dev/null && frameworks="${frameworks:+$frameworks, }Django"
    grep -ql "flask" "$TARGET_DIR"/requirements.txt "$TARGET_DIR"/pyproject.toml 2>/dev/null && frameworks="${frameworks:+$frameworks, }Flask"
    grep -ql "fastapi" "$TARGET_DIR"/requirements.txt "$TARGET_DIR"/pyproject.toml 2>/dev/null && frameworks="${frameworks:+$frameworks, }FastAPI"
fi

# Other ecosystems
detect_framework "Cargo.toml" "Rust/Cargo" || true
detect_framework "go.mod" "Go" || true
detect_framework "Gemfile" "Ruby" || true
detect_framework "build.gradle" "Gradle" || true
detect_framework "build.gradle.kts" "Gradle (Kotlin)" || true
detect_framework "pom.xml" "Maven" || true
detect_framework "Package.swift" "Swift" || true
detect_framework "pubspec.yaml" "Dart/Flutter" || true
detect_framework "mix.exs" "Elixir/Mix" || true

[ -n "$frameworks" ] && eagle_ok "Frameworks: $frameworks"

# ─── Structure analysis ───────────────────────────────────

top_dirs=""
if [ "$is_git" = true ]; then
    git -C "$TARGET_DIR" ls-files --cached --others --exclude-standard | cut -d/ -f1 | sort -u | while read -r item; do
        if [ -d "$TARGET_DIR/$item" ]; then
            count=$(git -C "$TARGET_DIR" ls-files --cached --others --exclude-standard "$item/" 2>/dev/null | wc -l | tr -d ' ')
            echo "$item/ ($count)"
        fi
    done > "${TMPFILE}.dirs"
else
    find "$TARGET_DIR" -maxdepth 1 -type d -not -name '.*' -not -name 'node_modules' -not -name 'dist' -not -name 'build' -not -name '__pycache__' -not -path "$TARGET_DIR" | sort | while read -r dir; do
        name=$(basename "$dir")
        count=$(find "$dir" -type f 2>/dev/null | wc -l | tr -d ' ')
        echo "$name/ ($count)"
    done > "${TMPFILE}.dirs"
fi
top_dirs=$(head -10 "${TMPFILE}.dirs" | while read -r line; do printf "%s" "${sep:-}${line}"; sep=", "; done)
rm -f "${TMPFILE}.dirs"

[ -n "$top_dirs" ] && eagle_ok "Structure: $top_dirs"

# ─── Entry points ─────────────────────────────────────────

entries=""

for candidate in "bin/"* "src/index."* "src/main."* "src/app."* "index."* "main."* "app."* "server."* "cli."*; do
    match=$(grep "^${candidate}$\|^${candidate}" "$TMPFILE" 2>/dev/null | head -1 || true)
    if [ -n "$match" ]; then
        entries="${entries:+$entries, }$match"
    fi
done

[ -n "$entries" ] && eagle_ok "Entry points: $entries"

# ─── Test detection ───────────────────────────────────────

tests=""
test_count=0

test_count=$(grep -cE '(^test/|^tests/|^__tests__/|\.test\.|\.spec\.|_test\.)' "$TMPFILE" || true)
if [ "$test_count" -gt 0 ]; then
    tests="$test_count test files"
    if [ -f "$TARGET_DIR/package.json" ]; then
        grep -q "jest" "$TARGET_DIR/package.json" 2>/dev/null && tests="$tests (Jest)"
        grep -q "vitest" "$TARGET_DIR/package.json" 2>/dev/null && tests="$tests (Vitest)"
        grep -q "mocha" "$TARGET_DIR/package.json" 2>/dev/null && tests="$tests (Mocha)"
    fi
    grep -q "pytest" "$TARGET_DIR/requirements.txt" "$TARGET_DIR/pyproject.toml" 2>/dev/null && tests="$tests (pytest)"
    eagle_ok "Tests: $tests"
else
    eagle_dim "Tests: none detected"
fi

# ─── Key config files ─────────────────────────────────────

configs=""
for cfg in .env.example .env.local Dockerfile docker-compose.yml docker-compose.yaml \
           Makefile Justfile railway.json railway.toml vercel.json netlify.toml \
           tsconfig.json .eslintrc* biome.json .prettierrc* tailwind.config.* \
           vite.config.* next.config.* webpack.config.* rollup.config.* \
           CLAUDE.md .cursorrules; do
    match=$(grep "^${cfg}$" "$TMPFILE" 2>/dev/null | head -1 || true)
    if [ -n "$match" ]; then
        configs="${configs:+$configs, }$match"
    fi
done

[ -n "$configs" ] && eagle_ok "Config: $configs"

# ─── Dependency count ─────────────────────────────────────

dep_info=""
if [ -f "$TARGET_DIR/package.json" ]; then
    deps=$(jq '(.dependencies // {}) | length' "$TARGET_DIR/package.json" 2>/dev/null || echo "0")
    dev_deps=$(jq '(.devDependencies // {}) | length' "$TARGET_DIR/package.json" 2>/dev/null || echo "0")
    [ "$deps" -gt 0 ] || [ "$dev_deps" -gt 0 ] && dep_info="npm: ${deps} deps, ${dev_deps} devDeps"
fi

if [ -f "$TARGET_DIR/go.mod" ]; then
    go_deps=$(grep -c "^\t" "$TARGET_DIR/go.mod" 2>/dev/null || echo "0")
    dep_info="${dep_info:+$dep_info; }go: $go_deps modules"
fi

[ -n "$dep_info" ] && eagle_ok "Dependencies: $dep_info"

# ─── Monorepo detection ──────────────────────────────────

monorepo=""
if [ -f "$TARGET_DIR/package.json" ]; then
    if jq -e '.workspaces' "$TARGET_DIR/package.json" &>/dev/null; then
        workspace_count=$(jq '.workspaces | if type == "array" then length elif type == "object" then (.packages // []) | length else 0 end' "$TARGET_DIR/package.json" 2>/dev/null || echo "?")
        monorepo="npm workspaces ($workspace_count patterns)"
    fi
fi

if [ -f "$TARGET_DIR/pnpm-workspace.yaml" ]; then
    monorepo="pnpm workspace"
fi

if [ -f "$TARGET_DIR/lerna.json" ]; then
    monorepo="${monorepo:+$monorepo + }Lerna"
fi

if [ -f "$TARGET_DIR/turbo.json" ]; then
    monorepo="${monorepo:+$monorepo + }Turborepo"
fi

[ -n "$monorepo" ] && eagle_ok "Monorepo: $monorepo"

# ─── Generate overview text ────────────────────────────────

echo ""
eagle_info "Generating overview..."

overview="$PROJECT: "

# Primary language/framework
if [ -n "$frameworks" ]; then
    overview+="$frameworks project"
else
    primary_lang=$(echo "$top_langs" | cut -d'(' -f1 | tr -d ' ')
    overview+="${primary_lang:-unknown} project"
fi

overview+=" ($total_files files, ~${scale} lines)"

[ -n "$monorepo" ] && overview+=". Monorepo: $monorepo"

overview+="."

# Structure
if [ -n "$top_dirs" ]; then
    overview+=" Structure: $top_dirs."
fi

# Entry points
if [ -n "$entries" ]; then
    overview+=" Entry: $entries."
fi

# Tests
if [ "$test_count" -gt 0 ]; then
    overview+=" Tests: $tests."
else
    overview+=" No tests detected."
fi

# Dependencies
if [ -n "$dep_info" ]; then
    overview+=" Dependencies: $dep_info."
fi

# Config highlights
if [ -n "$configs" ]; then
    overview+=" Config: $configs."
fi

# Store in database
eagle_upsert_overview "$PROJECT" "$overview"

eagle_ok "Overview saved for project '$PROJECT'"
echo ""

echo -e "  ${BOLD}Generated overview:${RESET}"
echo ""
echo -e "  ${DIM}$overview${RESET}"
echo ""

eagle_footer "Scan complete."
eagle_kv "Project:" "$PROJECT"
eagle_kv "Files:" "$total_files"
eagle_kv "Lines:" "~$scale"
eagle_kv "Database:" "$EAGLE_MEM_DB"
echo ""
