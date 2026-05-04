#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — LLM Provider Abstraction
# Config parsing + unified eagle_llm_call for Ollama/agent CLI/API providers
# ═══════════════════════════════════════════════════════════

EAGLE_CONFIG_FILE="${EAGLE_MEM_DIR}/config.toml"
EAGLE_DEFAULT_OLLAMA_URL="http://localhost:11434"

# ─── Config parsing ────────────────────────────────────────

eagle_config_get() {
    local section="$1"
    local key="$2"
    local default="${3:-}"

    if [ ! -f "$EAGLE_CONFIG_FILE" ]; then
        echo "$default"
        return
    fi

    local value
    value=$(awk -v section="$section" -v key="$key" '
        /^[[:space:]]*\[/ {
            gsub(/[\[\][:space:]]/, "")
            current = $0
        }
        current == section && /^[[:space:]]*[^#\[]/ {
            split($0, parts, "=")
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", parts[1])
            if (parts[1] == key) {
                val = substr($0, index($0, "=") + 1)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
                gsub(/^["'"'"']|["'"'"']$/, "", val)
                print val
                exit
            }
        }
    ' "$EAGLE_CONFIG_FILE")

    if [ -n "$value" ]; then
        echo "$value"
    else
        echo "$default"
    fi
}

eagle_config_set() {
    local section="$1"
    local key="$2"
    local value="$3"

    # Validate section/key are alphanumeric+underscore (safe for grep/sed patterns)
    if [[ ! "$section" =~ ^[A-Za-z0-9_-]+$ ]] || [[ ! "$key" =~ ^[A-Za-z0-9_-]+$ ]]; then
        eagle_log "ERROR" "config_set: invalid section/key: [$section] $key"
        return 1
    fi

    if [ ! -f "$EAGLE_CONFIG_FILE" ]; then
        eagle_config_init
    fi

    # Escape sed metacharacters in value to prevent injection via |, &, \, /
    local safe_value
    safe_value=$(printf '%s' "$value" | sed 's/[|&/\]/\\&/g')

    if grep -q "^\[${section}\]" "$EAGLE_CONFIG_FILE" 2>/dev/null; then
        local tmp_cfg="${EAGLE_CONFIG_FILE}.tmp.$$"
        awk -v sect="[${section}]" -v k="$key" -v v="$safe_value" '
            BEGIN { in_sect=0; replaced=0 }
            /^\[/ {
                if (in_sect && !replaced) {
                    print k" = \""v"\""
                    replaced=1
                }
                in_sect=($0 == sect)
            }
            in_sect && !replaced && $0 ~ "^[[:space:]]*"k"[[:space:]]*=" {
                print k" = \""v"\""; replaced=1; next
            }
            { print }
            END { if (in_sect && !replaced) print k" = \""v"\"" }
        ' "$EAGLE_CONFIG_FILE" > "$tmp_cfg" && mv "$tmp_cfg" "$EAGLE_CONFIG_FILE"
    else
        # printf is safe — no sed interpolation needed for append
        printf '\n[%s]\n%s = "%s"\n' "$section" "$key" "$value" >> "$EAGLE_CONFIG_FILE"
    fi
}

# ─── Ollama detection ──────────────────────────────────────

eagle_detect_ollama() {
    local url="${1:-$EAGLE_DEFAULT_OLLAMA_URL}"
    curl -sf "${url}/api/tags" --connect-timeout 2 --max-time 3 2>/dev/null
}

eagle_ollama_models() {
    local url="${1:-$EAGLE_DEFAULT_OLLAMA_URL}"
    eagle_detect_ollama "$url" | jq -r '.models[].name' 2>/dev/null
}

eagle_ollama_best_model() {
    local models
    models=$(eagle_ollama_models "$1")
    [ -z "$models" ] && return 1

    local preferred="gemma4 gemma3 gemma2 mistral llama3 phi3 deepseek-coder"
    for pref in $preferred; do
        if echo "$models" | grep -qi "$pref"; then
            echo "$models" | grep -i "$pref" | head -1
            return 0
        fi
    done

    echo "$models" | head -1
}

# ─── Config initialization ─────────────────────────────────

eagle_config_init() {
    local ollama_url="$EAGLE_DEFAULT_OLLAMA_URL"
    local provider="none"
    local model=""
    local ollama_model="mistral"

    local ollama_response
    ollama_response=$(eagle_detect_ollama "$ollama_url" || true)
    if [ -n "$ollama_response" ]; then
        provider="ollama"
        model=$(eagle_ollama_best_model "$ollama_url" || true)
        ollama_model="$model"
    elif command -v codex &>/dev/null || command -v claude &>/dev/null; then
        provider="agent_cli"
        model="native"
    elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        provider="anthropic"
        model="claude-haiku-4-5-20251001"
    elif [ -n "${OPENAI_API_KEY:-}" ]; then
        provider="openai"
        model="gpt-4o-mini"
    fi

    # Create config with restrictive permissions from the start (no TOCTOU window)
    (
        umask 077
        mkdir -p "$EAGLE_MEM_DIR"
        cat > "$EAGLE_CONFIG_FILE" << TOML
# Eagle Mem configuration
# Docs: https://github.com/eagleisbatman/eagle-mem

[provider]
# Which LLM provider to use for the curator and analysis features
# Options: "ollama" (free, local), "agent_cli" (Codex/Claude CLI auth), "anthropic", "openai"
type = "$provider"

[ollama]
url = "$ollama_url"
model = "$ollama_model"

[agent_cli]
# Uses the already-installed Codex/Claude CLI instead of direct API keys.
# preferred = "current" uses EAGLE_AGENT_SOURCE when hooks invoke Eagle Mem.
# If run manually with no agent source, it prefers Codex when available.
preferred = "current"
codex_model = ""
claude_model = ""

[orchestration]
# route = "opposite" means Codex coordinates Claude workers and Claude
# coordinates Codex workers by default.
route = "opposite"
auto_worktree = "true"
worktree_root = ""
codex_worker_model = "gpt-5.5"
codex_worker_effort = "xhigh"
claude_worker_model = "claude-opus-4-7"
claude_worker_effort = "xhigh"

[anthropic]
# Uses ANTHROPIC_API_KEY env var for authentication
model = "claude-haiku-4-5-20251001"

[openai]
# Uses OPENAI_API_KEY env var for authentication
model = "gpt-4o-mini"

[curator]
# "auto" = triggers at session start after min_sessions; "manual" = CLI only
schedule = "auto"
min_sessions = 5

[updates]
# Eagle Mem is infrastructure: patch fixes auto-apply by default so stale bugs
# do not keep blocking Claude Code or Codex sessions.
# mode: "auto" applies eligible updates, "notify" only reports them, "off" disables checks.
mode = "auto"
# allow: "patch" auto-applies x.y.Z fixes only; "minor" allows x.Y.z; "major" allows all.
allow = "patch"
channel = "latest"
interval_hours = 24

[token_guard]
# rtk: "off" disables RTK help, "auto" uses RTK when found,
# "enforce" blocks known raw-output shell commands when RTK is unavailable.
rtk = "auto"
# raw_bash: "block" blocks raw Codex shell output when an RTK rewrite exists.
# "allow" keeps RTK advisory only.
raw_bash = "block"

[redaction]
# Additional secret patterns (regex) beyond built-in defaults
# extra_patterns = ["MY_CUSTOM_SECRET_.*"]
TOML
    )
    chmod 700 "$EAGLE_MEM_DIR" 2>/dev/null || true
    eagle_log "INFO" "Config initialized: provider=$provider model=$model"
}

# ─── Unified LLM call ─────────────────────────────────────

eagle_llm_call() {
    local prompt="$1"
    local system_prompt="${2:-You are a helpful assistant that analyzes software development sessions.}"
    local max_tokens="${3:-1024}"

    local provider
    provider=$(eagle_config_get "provider" "type" "none")

    case "$provider" in
        ollama)   _eagle_call_ollama "$prompt" "$system_prompt" "$max_tokens" ;;
        agent_cli) _eagle_call_agent_cli "$prompt" "$system_prompt" "$max_tokens" ;;
        anthropic) _eagle_call_anthropic "$prompt" "$system_prompt" "$max_tokens" ;;
        openai)   _eagle_call_openai "$prompt" "$system_prompt" "$max_tokens" ;;
        none)
            eagle_log "ERROR" "No LLM provider configured. Run: eagle-mem config"
            return 1
            ;;
        *)
            eagle_log "ERROR" "Unknown provider: $provider"
            return 1
            ;;
    esac
}

_eagle_call_ollama() {
    local prompt="$1" system="$2" max_tokens="$3"
    local url model

    url=$(eagle_config_get "ollama" "url" "$EAGLE_DEFAULT_OLLAMA_URL")
    model=$(eagle_config_get "ollama" "model" "mistral")

    local body
    body=$(jq -nc \
        --arg model "$model" \
        --arg system "$system" \
        --arg prompt "$prompt" \
        --argjson tokens "$max_tokens" \
        '{
            model: $model,
            messages: [
                {role: "system", content: $system},
                {role: "user", content: $prompt}
            ],
            stream: false,
            options: {num_predict: $tokens}
        }')

    local response
    response=$(curl -sf "${url}/api/chat" \
        --connect-timeout 5 \
        --max-time 120 \
        -H "Content-Type: application/json" \
        -d "$body" 2>/dev/null)

    if [ $? -ne 0 ] || [ -z "$response" ]; then
        eagle_log "ERROR" "Ollama call failed: model=$model url=$url"
        return 1
    fi

    echo "$response" | jq -r '.message.content // empty'
}

_eagle_agent_cli_target() {
    local preferred
    preferred=$(eagle_config_get "agent_cli" "preferred" "current")

    case "$preferred" in
        codex|openai-codex) echo "codex"; return 0 ;;
        claude|claude-code|cloud-code) echo "claude-code"; return 0 ;;
        auto)
            if [ -n "${EAGLE_AGENT_SOURCE:-${EAGLE_AGENT:-}}" ]; then
                eagle_agent_source
            elif command -v codex &>/dev/null; then
                echo "codex"
            elif command -v claude &>/dev/null; then
                echo "claude-code"
            else
                echo "none"
            fi
            ;;
        current|*)
            if [ -n "${EAGLE_AGENT_SOURCE:-${EAGLE_AGENT:-}}" ]; then
                eagle_agent_source
            elif command -v codex &>/dev/null; then
                echo "codex"
            elif command -v claude &>/dev/null; then
                echo "claude-code"
            else
                echo "none"
            fi
            ;;
    esac
}

_eagle_agent_cli_prompt_file() {
    local prompt="$1" system="$2" max_tokens="$3" file="$4"
    {
        printf 'System instruction:\n%s\n\n' "$system"
        printf 'Task:\n%s\n\n' "$prompt"
        printf 'Output contract:\n'
        printf -- '- Return only the requested curator text.\n'
        printf -- '- Do not use markdown fences unless the task explicitly asks for them.\n'
        printf -- '- Do not edit files, run project commands, or inspect the repository; all needed data is in this prompt.\n'
        printf -- '- Keep the response within roughly %s tokens.\n' "$max_tokens"
    } > "$file"
}

_eagle_call_agent_cli() {
    local prompt="$1" system="$2" max_tokens="$3"
    local target
    target=$(_eagle_agent_cli_target)

    case "$target" in
        codex) _eagle_call_codex_cli "$prompt" "$system" "$max_tokens" ;;
        claude-code) _eagle_call_claude_cli "$prompt" "$system" "$max_tokens" ;;
        *)
            eagle_log "ERROR" "agent_cli provider unavailable: no Codex or Claude CLI found"
            return 1
            ;;
    esac
}

_eagle_call_codex_cli() {
    local prompt="$1" system="$2" max_tokens="$3"
    command -v codex &>/dev/null || {
        eagle_log "ERROR" "agent_cli provider selected Codex, but codex command was not found"
        return 1
    }

    mkdir -p "$EAGLE_MEM_DIR/tmp"
    local prompt_file out_file
    prompt_file=$(mktemp "$EAGLE_MEM_DIR/tmp/codex-provider-prompt.XXXXXX")
    out_file=$(mktemp "$EAGLE_MEM_DIR/tmp/codex-provider-output.XXXXXX")
    _eagle_agent_cli_prompt_file "$prompt" "$system" "$max_tokens" "$prompt_file"

    local model
    model=$(eagle_config_get "agent_cli" "codex_model" "")

    local rc _had_errexit=0
    case "$-" in *e*) _had_errexit=1; set +e ;; esac
    if [ -n "$model" ]; then
        EAGLE_MEM_DISABLE_HOOKS=1 codex exec \
            --ephemeral \
            --skip-git-repo-check \
            --ignore-rules \
            -c features.codex_hooks=false \
            --sandbox read-only \
            --cd "${EAGLE_AGENT_CWD:-$(pwd)}" \
            --model "$model" \
            --output-last-message "$out_file" \
            - < "$prompt_file" >> "$EAGLE_MEM_LOG" 2>&1
        rc=$?
    else
        EAGLE_MEM_DISABLE_HOOKS=1 codex exec \
            --ephemeral \
            --skip-git-repo-check \
            --ignore-rules \
            -c features.codex_hooks=false \
            --sandbox read-only \
            --cd "${EAGLE_AGENT_CWD:-$(pwd)}" \
            --output-last-message "$out_file" \
            - < "$prompt_file" >> "$EAGLE_MEM_LOG" 2>&1
        rc=$?
    fi
    [ "$_had_errexit" -eq 1 ] && set -e

    rm -f "$prompt_file"
    if [ "$rc" -ne 0 ] || [ ! -s "$out_file" ]; then
        rm -f "$out_file"
        eagle_log "ERROR" "Codex agent_cli provider call failed"
        return 1
    fi

    cat "$out_file"
    rm -f "$out_file"
}

_eagle_call_claude_cli() {
    local prompt="$1" system="$2" max_tokens="$3"
    command -v claude &>/dev/null || {
        eagle_log "ERROR" "agent_cli provider selected Claude Code, but claude command was not found"
        return 1
    }

    mkdir -p "$EAGLE_MEM_DIR/tmp"
    local prompt_file out_file model rc
    prompt_file=$(mktemp "$EAGLE_MEM_DIR/tmp/claude-provider-prompt.XXXXXX")
    out_file=$(mktemp "$EAGLE_MEM_DIR/tmp/claude-provider-output.XXXXXX")
    _eagle_agent_cli_prompt_file "$prompt" "$system" "$max_tokens" "$prompt_file"
    model=$(eagle_config_get "agent_cli" "claude_model" "")

    local _had_errexit=0
    case "$-" in *e*) _had_errexit=1; set +e ;; esac
    if [ -n "$model" ]; then
        EAGLE_MEM_DISABLE_HOOKS=1 CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1 claude -p \
            --no-session-persistence \
            --disable-slash-commands \
            --permission-mode dontAsk \
            --tools "" \
            --output-format text \
            --model "$model" \
            "$(cat "$prompt_file")" > "$out_file" 2>> "$EAGLE_MEM_LOG"
        rc=$?
    else
        EAGLE_MEM_DISABLE_HOOKS=1 CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1 claude -p \
            --no-session-persistence \
            --disable-slash-commands \
            --permission-mode dontAsk \
            --tools "" \
            --output-format text \
            "$(cat "$prompt_file")" > "$out_file" 2>> "$EAGLE_MEM_LOG"
        rc=$?
    fi
    [ "$_had_errexit" -eq 1 ] && set -e

    rm -f "$prompt_file"
    if [ "$rc" -ne 0 ] || [ ! -s "$out_file" ]; then
        rm -f "$out_file"
        eagle_log "ERROR" "Claude agent_cli provider call failed"
        return 1
    fi

    cat "$out_file"
    rm -f "$out_file"
}

_eagle_call_anthropic() {
    local prompt="$1" system="$2" max_tokens="$3"
    local model api_key

    model=$(eagle_config_get "anthropic" "model" "claude-haiku-4-5-20251001")
    api_key="${ANTHROPIC_API_KEY:-}"

    if [ -z "$api_key" ]; then
        eagle_log "ERROR" "ANTHROPIC_API_KEY not set"
        return 1
    fi

    local body
    body=$(jq -nc \
        --arg model "$model" \
        --arg system "$system" \
        --arg prompt "$prompt" \
        --argjson tokens "$max_tokens" \
        '{
            model: $model,
            max_tokens: $tokens,
            system: $system,
            messages: [{role: "user", content: $prompt}]
        }')

    # Pass API key via config stdin to avoid exposing it in process list (ps aux)
    local response
    response=$(curl -sf "https://api.anthropic.com/v1/messages" \
        --connect-timeout 5 \
        --max-time 120 \
        -K <(printf 'header = "x-api-key: %s"' "$api_key") \
        -H "anthropic-version: 2023-06-01" \
        -H "content-type: application/json" \
        -d "$body" 2>/dev/null)

    if [ $? -ne 0 ] || [ -z "$response" ]; then
        eagle_log "ERROR" "Anthropic call failed: model=$model"
        return 1
    fi

    echo "$response" | jq -r '.content[0].text // empty'
}

_eagle_call_openai() {
    local prompt="$1" system="$2" max_tokens="$3"
    local model api_key

    model=$(eagle_config_get "openai" "model" "gpt-4o-mini")
    api_key="${OPENAI_API_KEY:-}"

    if [ -z "$api_key" ]; then
        eagle_log "ERROR" "OPENAI_API_KEY not set"
        return 1
    fi

    local body
    body=$(jq -nc \
        --arg model "$model" \
        --arg system "$system" \
        --arg prompt "$prompt" \
        --argjson tokens "$max_tokens" \
        '{
            model: $model,
            max_tokens: $tokens,
            messages: [
                {role: "system", content: $system},
                {role: "user", content: $prompt}
            ]
        }')

    # Pass API key via config stdin to avoid exposing it in process list (ps aux)
    local response
    response=$(curl -sf "https://api.openai.com/v1/chat/completions" \
        --connect-timeout 5 \
        --max-time 120 \
        -K <(printf 'header = "Authorization: Bearer %s"' "$api_key") \
        -H "content-type: application/json" \
        -d "$body" 2>/dev/null)

    if [ $? -ne 0 ] || [ -z "$response" ]; then
        eagle_log "ERROR" "OpenAI call failed: model=$model"
        return 1
    fi

    echo "$response" | jq -r '.choices[0].message.content // empty'
}

# ─── Config CLI helpers ────────────────────────────────────

eagle_show_config() {
    if [ ! -f "$EAGLE_CONFIG_FILE" ]; then
        echo "No config file found. Run: eagle-mem config init"
        return 1
    fi

    local provider model
    provider=$(eagle_config_get "provider" "type" "none")
    if [ "$provider" = "agent_cli" ]; then
        model=$(_eagle_agent_cli_target)
    else
        model=$(eagle_config_get "$provider" "model" "unknown")
    fi

    echo "Provider: $provider"
    echo "Model:    $model"

    if [ "$provider" = "ollama" ]; then
        local url
        url=$(eagle_config_get "ollama" "url" "$EAGLE_DEFAULT_OLLAMA_URL")
        echo "URL:      $url"
        local running
        running=$(eagle_detect_ollama "$url")
        if [ -n "$running" ]; then
            echo "Status:   running"
            echo "Models:   $(eagle_ollama_models "$url" | tr '\n' ', ' | sed 's/,$//')"
        else
            echo "Status:   not running"
        fi
    elif [ "$provider" = "agent_cli" ]; then
        echo "Preferred: $(eagle_config_get "agent_cli" "preferred" "current")"
        echo "Codex:     $(command -v codex 2>/dev/null || echo "not found")"
        echo "Claude:    $(command -v claude 2>/dev/null || echo "not found")"
    fi

    echo ""
    echo "Orchestration:"
    echo "  Route:      $(eagle_config_get "orchestration" "route" "opposite")"
    echo "  Worktrees:  $(eagle_config_get "orchestration" "auto_worktree" "true")"
    echo "  Codex:      $(eagle_config_get "orchestration" "codex_worker_model" "gpt-5.5") / $(eagle_config_get "orchestration" "codex_worker_effort" "xhigh")"
    echo "  Claude:     $(eagle_config_get "orchestration" "claude_worker_model" "claude-opus-4-7") / $(eagle_config_get "orchestration" "claude_worker_effort" "xhigh")"

    echo ""
    echo "Updates:"
    echo "  Mode:       $(eagle_config_get "updates" "mode" "auto")"
    echo "  Allow:      $(eagle_config_get "updates" "allow" "patch")"
    echo "  Channel:    $(eagle_config_get "updates" "channel" "latest")"
    echo "  Interval:   $(eagle_config_get "updates" "interval_hours" "24")h"

    echo ""
    echo "Token guard:"
    echo "  RTK mode:  $(eagle_config_get "token_guard" "rtk" "auto")"
    echo "  Raw bash:  $(eagle_config_get "token_guard" "raw_bash" "block")"
    echo "  RTK bin:   $(command -v rtk 2>/dev/null || echo "not found")"

    echo ""
    echo "Config:   $EAGLE_CONFIG_FILE"
}
