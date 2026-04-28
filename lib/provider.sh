#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# Eagle Mem — LLM Provider Abstraction
# Config parsing + unified eagle_llm_call for Ollama/Anthropic/OpenAI
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
        if grep -q "^[[:space:]]*${key}[[:space:]]*=" "$EAGLE_CONFIG_FILE" 2>/dev/null; then
            sed -i '' "s|^[[:space:]]*${key}[[:space:]]*=.*|${key} = \"${safe_value}\"|" "$EAGLE_CONFIG_FILE"
        else
            sed -i '' "/^\[${section}\]/a\\
${key} = \"${safe_value}\"
" "$EAGLE_CONFIG_FILE"
        fi
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

    local preferred="mistral qwen3-coder gemma4 llama3 phi3 deepseek-coder"
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

    local ollama_response
    ollama_response=$(eagle_detect_ollama "$ollama_url")
    if [ -n "$ollama_response" ]; then
        provider="ollama"
        model=$(eagle_ollama_best_model "$ollama_url")
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
        cat > "$EAGLE_CONFIG_FILE" << TOML
# Eagle Mem configuration
# Docs: https://github.com/eagleisbatman/eagle-mem

[provider]
# Which LLM provider to use for the curator and analysis features
# Options: "ollama" (free, local), "anthropic", "openai"
type = "$provider"

[ollama]
url = "$ollama_url"
model = "${model:-mistral}"

[anthropic]
# Uses ANTHROPIC_API_KEY env var for authentication
model = "claude-haiku-4-5-20251001"

[openai]
# Uses OPENAI_API_KEY env var for authentication
model = "gpt-4o-mini"

[curator]
# "auto" = triggers at session end after min_sessions; "manual" = CLI only
schedule = "manual"
min_sessions = 5

[redaction]
# Additional secret patterns (regex) beyond built-in defaults
# extra_patterns = ["MY_CUSTOM_SECRET_.*"]
TOML
    )
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
    model=$(eagle_config_get "$provider" "model" "unknown")

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
    fi

    echo ""
    echo "Config:   $EAGLE_CONFIG_FILE"
}
