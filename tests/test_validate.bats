#!/usr/bin/env bats
# Tests for validate_awg_config() in awg_common.sh

load test_helper

@test "validate: complete config passes" {
    create_server_config
    run validate_awg_config
    [ "$status" -eq 0 ]
}

@test "validate: missing Jc fails" {
    create_server_config
    sed -i '/^Jc/d' "$SERVER_CONF_FILE"
    run validate_awg_config
    [ "$status" -eq 1 ]
}

@test "validate: missing S3 fails" {
    create_server_config
    sed -i '/^S3/d' "$SERVER_CONF_FILE"
    run validate_awg_config
    [ "$status" -eq 1 ]
}

@test "validate: missing H4 fails" {
    create_server_config
    sed -i '/^H4/d' "$SERVER_CONF_FILE"
    run validate_awg_config
    [ "$status" -eq 1 ]
}

@test "validate: I1 optional (warn only, still passes)" {
    create_server_config
    # I1 is not in our minimal config — should still pass
    run validate_awg_config
    [ "$status" -eq 0 ]
}

@test "validate: missing file fails" {
    rm -f "$SERVER_CONF_FILE"
    run validate_awg_config
    [ "$status" -eq 1 ]
}
