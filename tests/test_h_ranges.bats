#!/usr/bin/env bats
# Tests for generate_awg_h_ranges (#38 fix: H1-H4 randomization per install)

load test_helper

@test "generate_awg_h_ranges: returns 4 lines" {
    run generate_awg_h_ranges
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 4 ]
}

@test "generate_awg_h_ranges: each line is low-high format" {
    run generate_awg_h_ranges
    [ "$status" -eq 0 ]
    for line in "${lines[@]}"; do
        [[ "$line" =~ ^[0-9]+-[0-9]+$ ]]
    done
}

@test "generate_awg_h_ranges: each pair has low <= high" {
    run generate_awg_h_ranges
    [ "$status" -eq 0 ]
    for line in "${lines[@]}"; do
        local low="${line%-*}"
        local high="${line#*-}"
        [ "$low" -le "$high" ]
    done
}

@test "generate_awg_h_ranges: each pair width >= 1000" {
    run generate_awg_h_ranges
    [ "$status" -eq 0 ]
    for line in "${lines[@]}"; do
        local low="${line%-*}"
        local high="${line#*-}"
        local width=$(( high - low ))
        [ "$width" -ge 1000 ]
    done
}

@test "generate_awg_h_ranges: 4 ranges are non-overlapping (sorted ascending)" {
    run generate_awg_h_ranges
    [ "$status" -eq 0 ]
    local prev_high=-1
    for line in "${lines[@]}"; do
        local low="${line%-*}"
        local high="${line#*-}"
        [ "$low" -gt "$prev_high" ]
        prev_high="$high"
    done
}

@test "generate_awg_h_ranges: all values within uint32 [0, 2^32-1]" {
    run generate_awg_h_ranges
    [ "$status" -eq 0 ]
    for line in "${lines[@]}"; do
        local low="${line%-*}"
        local high="${line#*-}"
        [ "$low" -ge 0 ]
        [ "$high" -le 4294967295 ]
    done
}

@test "generate_awg_h_ranges: two consecutive runs produce different output (randomization)" {
    local out1 out2
    out1=$(generate_awg_h_ranges)
    out2=$(generate_awg_h_ranges)
    [ "$out1" != "$out2" ]
}

@test "generate_awg_h_ranges: not the old hardcoded values" {
    run generate_awg_h_ranges
    [ "$status" -eq 0 ]
    # The old hardcoded values were: 100000-800000, 1000000-8000000, etc.
    # New randomized output should never match this exact pattern.
    [ "${lines[0]}" != "100000-800000" ]
    [ "${lines[1]}" != "1000000-8000000" ]
    [ "${lines[2]}" != "10000000-80000000" ]
    [ "${lines[3]}" != "100000000-800000000" ]
}

@test "rand_range: uint32 boundary values" {
    run rand_range 0 4294967295
    [ "$status" -eq 0 ]
    [ "$output" -ge 0 ]
    [ "$output" -le 4294967295 ]
}
