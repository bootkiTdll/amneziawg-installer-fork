#!/usr/bin/env bats
# Tests for parse_duration() in awg_common.sh

load test_helper

@test "parse_duration: 1h = 3600" {
    run parse_duration "1h"
    [ "$status" -eq 0 ]
    [ "$output" = "3600" ]
}

@test "parse_duration: 12h = 43200" {
    run parse_duration "12h"
    [ "$status" -eq 0 ]
    [ "$output" = "43200" ]
}

@test "parse_duration: 1d = 86400" {
    run parse_duration "1d"
    [ "$status" -eq 0 ]
    [ "$output" = "86400" ]
}

@test "parse_duration: 7d = 604800" {
    run parse_duration "7d"
    [ "$status" -eq 0 ]
    [ "$output" = "604800" ]
}

@test "parse_duration: 4w = 2419200" {
    run parse_duration "4w"
    [ "$status" -eq 0 ]
    [ "$output" = "2419200" ]
}

@test "parse_duration: invalid format returns error" {
    run parse_duration "5x"
    [ "$status" -eq 1 ]
}

@test "parse_duration: empty string returns error" {
    run parse_duration ""
    [ "$status" -eq 1 ]
}

@test "parse_duration: text returns error" {
    run parse_duration "forever"
    [ "$status" -eq 1 ]
}
