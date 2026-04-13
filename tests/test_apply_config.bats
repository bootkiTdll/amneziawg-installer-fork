#!/usr/bin/env bats
# Tests for apply_config() modes in awg_common.sh

load test_helper

setup() {
    # Call parent setup
    TEST_DIR=$(mktemp -d)
    export AWG_DIR="$TEST_DIR"
    export CONFIG_FILE="$TEST_DIR/awgsetup_cfg.init"
    export SERVER_CONF_FILE="$TEST_DIR/awg0.conf"
    export KEYS_DIR="$TEST_DIR/keys"
    mkdir -p "$KEYS_DIR"

    # Silent log stubs
    log()       { :; }
    log_warn()  { :; }
    log_error() { :; }
    log_debug() { :; }
    export -f log log_warn log_error log_debug

    # Mock PATH: create stub commands
    MOCK_BIN="$TEST_DIR/mock_bin"
    mkdir -p "$MOCK_BIN"
    export PATH="$MOCK_BIN:$PATH"

    # Stub systemctl
    cat > "$MOCK_BIN/systemctl" << 'STUB'
#!/bin/bash
echo "systemctl $*" >> "${AWG_DIR}/.mock_calls"
exit 0
STUB
    chmod +x "$MOCK_BIN/systemctl"

    # Stub awg-quick
    cat > "$MOCK_BIN/awg-quick" << 'STUB'
#!/bin/bash
echo "awg-quick $*" >> "${AWG_DIR}/.mock_calls"
echo "[Interface]"
echo "PrivateKey = TEST"
exit 0
STUB
    chmod +x "$MOCK_BIN/awg-quick"

    # Stub awg
    cat > "$MOCK_BIN/awg" << 'STUB'
#!/bin/bash
echo "awg $*" >> "${AWG_DIR}/.mock_calls"
exit 0
STUB
    chmod +x "$MOCK_BIN/awg"

    # Stub timeout (pass-through)
    cat > "$MOCK_BIN/timeout" << 'STUB'
#!/bin/bash
shift  # skip timeout value
"$@"
STUB
    chmod +x "$MOCK_BIN/timeout"

    source "$BATS_TEST_DIRNAME/../awg_common.sh"
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "apply_config: AWG_SKIP_APPLY=1 returns 0 without calling anything" {
    export AWG_SKIP_APPLY=1
    run apply_config
    [ "$status" -eq 0 ]
    [ ! -f "$AWG_DIR/.mock_calls" ]
}

@test "apply_config: AWG_APPLY_MODE=restart calls systemctl restart" {
    require_flock
    export AWG_SKIP_APPLY=0
    export AWG_APPLY_MODE=restart
    run apply_config
    [ "$status" -eq 0 ]
    grep -q "systemctl restart awg-quick@awg0" "$AWG_DIR/.mock_calls"
}

@test "apply_config: default mode calls awg-quick strip + awg syncconf" {
    require_flock
    export AWG_SKIP_APPLY=0
    export AWG_APPLY_MODE=syncconf
    run apply_config
    [ "$status" -eq 0 ]
    grep -q "awg-quick strip awg0" "$AWG_DIR/.mock_calls"
    grep -q "awg syncconf" "$AWG_DIR/.mock_calls"
}

@test "apply_config: unknown mode falls through to syncconf" {
    require_flock
    export AWG_SKIP_APPLY=0
    export AWG_APPLY_MODE=invalid_mode
    run apply_config
    [ "$status" -eq 0 ]
    grep -q "awg-quick strip" "$AWG_DIR/.mock_calls"
}
