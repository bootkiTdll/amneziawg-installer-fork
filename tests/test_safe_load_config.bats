#!/usr/bin/env bats
# Tests for safe_load_config() in awg_common.sh

load test_helper

@test "safe_load_config: loads valid config" {
    create_init_config
    safe_load_config "$CONFIG_FILE"
    [ "$AWG_PORT" = "39743" ]
    [ "$AWG_Jc" = "6" ]
    [ "$AWG_S3" = "32" ]
}

@test "safe_load_config: single-quoted values preserved" {
    echo "export AWG_H1='100000-800000'" > "$CONFIG_FILE"
    safe_load_config "$CONFIG_FILE"
    [ "$AWG_H1" = "100000-800000" ]
}

@test "safe_load_config: double-quoted values preserved" {
    echo 'export AWG_H1="100000-800000"' > "$CONFIG_FILE"
    safe_load_config "$CONFIG_FILE"
    [ "$AWG_H1" = "100000-800000" ]
}

@test "safe_load_config: rejects unknown keys" {
    echo "export EVIL_KEY=hacked" > "$CONFIG_FILE"
    safe_load_config "$CONFIG_FILE"
    [ -z "${EVIL_KEY:-}" ]
}

@test "safe_load_config: skips comments" {
    cat > "$CONFIG_FILE" << 'EOF'
# This is a comment
export AWG_PORT=12345
EOF
    safe_load_config "$CONFIG_FILE"
    [ "$AWG_PORT" = "12345" ]
}

@test "safe_load_config: skips blank lines" {
    cat > "$CONFIG_FILE" << 'EOF'

export AWG_PORT=11111

export AWG_Jc=5

EOF
    safe_load_config "$CONFIG_FILE"
    [ "$AWG_PORT" = "11111" ]
    [ "$AWG_Jc" = "5" ]
}

@test "safe_load_config: handles export prefix" {
    echo "export AWG_PORT=22222" > "$CONFIG_FILE"
    safe_load_config "$CONFIG_FILE"
    [ "$AWG_PORT" = "22222" ]
}

@test "safe_load_config: handles bare assignment (no export)" {
    echo "AWG_PORT=33333" > "$CONFIG_FILE"
    safe_load_config "$CONFIG_FILE"
    [ "$AWG_PORT" = "33333" ]
}

@test "safe_load_config: missing file returns 1" {
    run safe_load_config "/nonexistent/file"
    [ "$status" -eq 1 ]
}

@test "safe_load_config: AWG_APPLY_MODE in whitelist" {
    echo "export AWG_APPLY_MODE=restart" > "$CONFIG_FILE"
    safe_load_config "$CONFIG_FILE"
    [ "$AWG_APPLY_MODE" = "restart" ]
}

@test "safe_load_config: unquoted numeric values" {
    echo "export AWG_Jmin=55" > "$CONFIG_FILE"
    safe_load_config "$CONFIG_FILE"
    [ "$AWG_Jmin" = "55" ]
}
