#!/usr/bin/env bash
# 复现 _read_env_field 的实际行为
TEST_DIR=$(mktemp -d)
ENV="$TEST_DIR/.env"

# case A: .env 里没有 TG_USER_SESSION 行
printf "TG_API_ID=111\nTG_API_HASH=hash\n" > "$ENV"

_read_env_field() {
    local existing="$1"
    local key="$2"
    local raw=""
    if [[ -f "$existing" ]]; then
        raw="$(grep "^${key}=" "$existing" | cut -d= -f2- || true)"
    fi
    if [[ "$key" == "TG_USER_SESSION" ]]; then
        SESSION_PLACEHOLDERS=("replace_with_your_string_session" "your_string_session" "REPLACE_ME")
        raw=$(for p in "${SESSION_PLACEHOLDERS[@]}"; do
            if [[ "$raw" == "$p" ]]; then
                printf ""
                return 0
            fi
        done
        printf "%s" "$raw")
    fi
    printf "%s\n%s" "$raw" "$([[ -n "$raw" ]] && echo 1 || echo 0)"
}

echo "=== Case A: no TG_USER_SESSION line ==="
_e="$(_read_env_field "$ENV" TG_USER_SESSION)"
echo "_e raw=[$_e]"
cur="${_e%%$'\n'*}"
echo "cur=[$cur]"
if [[ -n "$cur" ]]; then
    echo "BRANCH: configured (1) 重新生成"
else
    echo "BRANCH: not configured (1) 现在生成"
fi

# case B: TG_USER_SESSION= (空值)
printf "TG_API_ID=111\nTG_USER_SESSION=\n" > "$ENV"
echo ""
echo "=== Case B: TG_USER_SESSION= (empty value) ==="
_e="$(_read_env_field "$ENV" TG_USER_SESSION)"
echo "_e raw=[$_e]"
cur="${_e%%$'\n'*}"
echo "cur=[$cur]"
if [[ -n "$cur" ]]; then
    echo "BRANCH: configured (1) 重新生成"
else
    echo "BRANCH: not configured (1) 现在生成"
fi

# case C: TG_USER_SESSION=replace_with_your_string_session (placeholder)
printf "TG_API_ID=111\nTG_USER_SESSION=replace_with_your_string_session\n" > "$ENV"
echo ""
echo "=== Case C: placeholder ==="
_e="$(_read_env_field "$ENV" TG_USER_SESSION)"
echo "_e raw=[$_e]"
cur="${_e%%$'\n'*}"
echo "cur=[$cur]"
if [[ -n "$cur" ]]; then
    echo "BRANCH: configured (1) 重新生成"
else
    echo "BRANCH: not configured (1) 现在生成"
fi

# case D: TG_USER_SESSION=1BVts... (实际 session)
printf "TG_API_ID=111\nTG_USER_SESSION=1BVtsOKEabc\n" > "$ENV"
echo ""
echo "=== Case D: real session ==="
_e="$(_read_env_field "$ENV" TG_USER_SESSION)"
echo "_e raw=[$_e]"
cur="${_e%%$'\n'*}"
echo "cur=[$cur]"
if [[ -n "$cur" ]]; then
    echo "BRANCH: configured (1) 重新生成"
else
    echo "BRANCH: not configured (1) 现在生成"
fi

rm -rf "$TEST_DIR"