#!/usr/bin/env bash
# Shared bats setup for tests/yolo.bats.

PROJECT_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
export PROJECT_ROOT
export YOLO_BIN="${PROJECT_ROOT}/bin/yolo"

load "${PROJECT_ROOT}/tests/test_helper/bats-support/load"
load "${PROJECT_ROOT}/tests/test_helper/bats-assert/load"

# Initialize per-test state: isolated HOME, a git-init'd workspace, a podman
# mock on PATH, and empty log files.
setup_yolo_test() {
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"

    export WORK="$BATS_TEST_TMPDIR/work"
    mkdir -p "$WORK"
    cd "$WORK" || return 1
    git init -q -b main 2>/dev/null || git init -q

    export MOCK_BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$MOCK_BIN"
    install -m 0755 "$PROJECT_ROOT/tests/test_helper/podman-mock.sh" "$MOCK_BIN/podman"
    export PATH="$MOCK_BIN:$PATH"

    export MOCK_PODMAN_LOG="$BATS_TEST_TMPDIR/podman.log"
    export MOCK_PODMAN_BUILT_TAGS="$BATS_TEST_TMPDIR/built-tags.log"
    : >"$MOCK_PODMAN_LOG"
    : >"$MOCK_PODMAN_BUILT_TAGS"

    export MOCK_PODMAN_EXISTING_IMAGES="con-bomination-claude-code"
    export MOCK_PODMAN_IMAGE_ID="sha256:deadbeef00000000000000000000000000000000000000000000000000000000"
    export MOCK_PODMAN_VERSION="4.9.4"

    unset CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS
}

# Run bin/yolo via bats `run` so $status/$output/$lines are populated.
run_yolo() {
    run "$YOLO_BIN" "$@"
}

# Return the last `podman run ...` invocation line (tab-separated args).
last_podman_run_line() {
    grep $'^run\t' "$MOCK_PODMAN_LOG" | tail -1
}

# Return the last `podman build ...` invocation line.
last_podman_build_line() {
    grep $'^build\t' "$MOCK_PODMAN_LOG" | tail -1
}

# True if any logged invocation contains the given exact argument.
podman_log_has_arg() {
    local needle="$1"
    awk -v n="$needle" 'BEGIN{FS="\t"} { for (i=1;i<=NF;i++) if ($i==n) { found=1; exit } } END { exit !found }' "$MOCK_PODMAN_LOG"
}

# Count lines in MOCK_PODMAN_BUILT_TAGS.
built_tag_count() {
    if [ -s "$MOCK_PODMAN_BUILT_TAGS" ]; then
        wc -l <"$MOCK_PODMAN_BUILT_TAGS" | tr -d ' '
    else
        echo 0
    fi
}

# First (only, in our tests) built tag.
first_built_tag() {
    head -1 "$MOCK_PODMAN_BUILT_TAGS"
}
