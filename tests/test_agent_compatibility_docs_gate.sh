#!/usr/bin/env bash
# Guard against stale agent lifecycle assumptions when editing hook, statusline,
# config-installation, or instruction-file integration code.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DOC_DIR="$ROOT_DIR/docs/agent-compatibility"
FIXTURE_DIR="$ROOT_DIR/tests/fixtures/agent-hooks"

fail() {
    echo "agent compatibility docs gate failed: $*" >&2
    exit 1
}

require_file() {
    local file="$1"
    [ -f "$file" ] || fail "missing required file: ${file#$ROOT_DIR/}"
}

require_contains() {
    local file="$1"
    local pattern="$2"
    local label="$3"
    if ! grep -Eq "$pattern" "$file"; then
        fail "${file#$ROOT_DIR/} does not mention $label"
    fi
}

require_json() {
    local file="$1"
    jq -e . "$file" >/dev/null || fail "invalid JSON fixture: ${file#$ROOT_DIR/}"
}

require_file "$DOC_DIR/README.md"
require_file "$DOC_DIR/claude-code.md"
require_file "$DOC_DIR/codex.md"
require_file "$DOC_DIR/opencode.md"
require_file "$FIXTURE_DIR/claude-user-prompt-submit.json"
require_file "$FIXTURE_DIR/claude-statusline.json"
require_file "$FIXTURE_DIR/codex-user-prompt-submit.json"
require_file "$FIXTURE_DIR/codex-pre-tool-use.json"
require_file "$FIXTURE_DIR/opencode-chat-message.json"
require_file "$FIXTURE_DIR/opencode-tool-execute-before.json"
require_file "$FIXTURE_DIR/opencode-tool-execute-after.json"
require_file "$FIXTURE_DIR/opencode-todo-updated.json"
require_file "$FIXTURE_DIR/opencode-session-compacting.json"

require_json "$FIXTURE_DIR/claude-user-prompt-submit.json"
require_json "$FIXTURE_DIR/claude-statusline.json"
require_json "$FIXTURE_DIR/codex-user-prompt-submit.json"
require_json "$FIXTURE_DIR/codex-pre-tool-use.json"
require_json "$FIXTURE_DIR/opencode-chat-message.json"
require_json "$FIXTURE_DIR/opencode-tool-execute-before.json"
require_json "$FIXTURE_DIR/opencode-tool-execute-after.json"
require_json "$FIXTURE_DIR/opencode-todo-updated.json"
require_json "$FIXTURE_DIR/opencode-session-compacting.json"

require_contains "$DOC_DIR/README.md" "Before modifying" "the required pre-edit workflow"
require_contains "$DOC_DIR/README.md" "official documentation" "official documentation"
require_contains "$DOC_DIR/README.md" "fixture|golden-test" "fixture or golden-test coverage"

require_contains "$DOC_DIR/claude-code.md" "Last verified: [0-9]{4}-[0-9]{2}-[0-9]{2}" "a Last verified date"
require_contains "$DOC_DIR/claude-code.md" "https://code\\.claude\\.com/docs/en/hooks" "Claude Code hooks source"
require_contains "$DOC_DIR/claude-code.md" "https://code\\.claude\\.com/docs/en/statusline" "Claude Code statusline source"
require_contains "$DOC_DIR/claude-code.md" "UserPromptSubmit" "Claude UserPromptSubmit"
require_contains "$DOC_DIR/claude-code.md" "PreCompact" "Claude PreCompact"
require_contains "$DOC_DIR/claude-code.md" "PostCompact" "Claude PostCompact"
require_contains "$DOC_DIR/claude-code.md" "statusLine" "Claude statusLine config"
require_contains "$DOC_DIR/claude-code.md" "tests/fixtures/agent-hooks/claude-statusline\\.json" "Claude statusline fixture"

require_contains "$DOC_DIR/codex.md" "Last verified: [0-9]{4}-[0-9]{2}-[0-9]{2}" "a Last verified date"
require_contains "$DOC_DIR/codex.md" "https://developers\\.openai\\.com/codex/codex-manual\\.md" "Codex manual source"
require_contains "$DOC_DIR/codex.md" "https://developers\\.openai\\.com/codex/hooks\\.md" "Codex hooks source"
require_contains "$DOC_DIR/codex.md" "AGENTS\\.md" "Codex AGENTS.md behavior"
require_contains "$DOC_DIR/codex.md" "features\\.hooks" "canonical Codex hooks feature flag"
require_contains "$DOC_DIR/codex.md" "deprecated alias" "deprecated Codex hook alias"
require_contains "$DOC_DIR/codex.md" "UserPromptSubmit" "Codex UserPromptSubmit"
require_contains "$DOC_DIR/codex.md" "tests/fixtures/agent-hooks/codex-pre-tool-use\\.json" "Codex PreToolUse fixture"

require_contains "$DOC_DIR/opencode.md" "Last verified: [0-9]{4}-[0-9]{2}-[0-9]{2}" "an OpenCode Last verified date"
require_contains "$DOC_DIR/opencode.md" "https://opencode\\.ai/docs/plugins/" "OpenCode plugins source"
require_contains "$DOC_DIR/opencode.md" "https://opencode\\.ai/docs/config/" "OpenCode config source"
require_contains "$DOC_DIR/opencode.md" "https://opencode\\.ai/config\\.json" "OpenCode config schema source"
require_contains "$DOC_DIR/opencode.md" "~/.config/opencode/plugins/" "OpenCode global local plugin directory"
require_contains "$DOC_DIR/opencode.md" "chat\\.message" "OpenCode chat.message hook"
require_contains "$DOC_DIR/opencode.md" "tool\\.execute\\.before" "OpenCode tool.execute.before hook"
require_contains "$DOC_DIR/opencode.md" "tool\\.execute\\.after" "OpenCode tool.execute.after hook"
require_contains "$DOC_DIR/opencode.md" "todo\\.updated" "OpenCode todo.updated event"
require_contains "$DOC_DIR/opencode.md" "experimental\\.session\\.compacting" "OpenCode compaction hook"
require_contains "$DOC_DIR/opencode.md" "opencode --pure" "OpenCode pure-mode caveat"
require_contains "$DOC_DIR/opencode.md" "tests/fixtures/agent-hooks/opencode-tool-execute-before\\.json" "OpenCode PreToolUse fixture"
require_contains "$DOC_DIR/opencode.md" "tests/test_opencode_plugin_adapter\\.sh" "OpenCode adapter regression test"

if grep -R "features\\.codex_hooks" "$ROOT_DIR/lib" "$ROOT_DIR/scripts" "$ROOT_DIR/hooks" "$ROOT_DIR/bin" >/dev/null 2>&1; then
    fail "implementation still uses deprecated Codex features.codex_hooks instead of features.hooks"
fi

if grep -R "codex_hooks[[:space:]]*=[[:space:]]*true" "$ROOT_DIR/lib" "$ROOT_DIR/scripts" "$ROOT_DIR/hooks" "$ROOT_DIR/bin" >/dev/null 2>&1; then
    fail "implementation still writes deprecated Codex codex_hooks config instead of hooks"
fi

changed_sensitive=$(
    {
        git -C "$ROOT_DIR" diff --name-only HEAD -- 2>/dev/null || true
        git -C "$ROOT_DIR" ls-files --others --exclude-standard 2>/dev/null || true
    } | awk '
        /^(hooks\/.*\.sh|lib\/hooks\.sh|lib\/codex-hooks\.sh|lib\/opencode-hooks\.sh|integrations\/opencode_eagle_mem_plugin\.js|scripts\/install\.sh|scripts\/update\.sh|scripts\/uninstall\.sh|scripts\/doctor\.sh|scripts\/statusline-em\.sh|lib\/common\.sh|AGENTS\.md|CLAUDE\.md)$/ { print }
    ' | sort -u
)

if [ -n "$changed_sensitive" ]; then
    changed_evidence=$(
        {
            git -C "$ROOT_DIR" diff --name-only HEAD -- 2>/dev/null || true
            git -C "$ROOT_DIR" ls-files --others --exclude-standard 2>/dev/null || true
        } | awk '
            /^(docs\/agent-compatibility\/.*\.md|tests\/fixtures\/agent-hooks\/.*\.json|tests\/test_agent_compatibility_docs_gate\.sh)$/ { print }
        ' | sort -u
    )
    [ -n "$changed_evidence" ] || fail "sensitive integration files changed without updated compatibility docs or fixtures: $changed_sensitive"
fi

echo "agent compatibility docs gate passed"
