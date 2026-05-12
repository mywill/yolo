#!/usr/bin/env bats
# Test suite for bin/yolo.
#
# Covers:
#   - pure helper functions (expand_volume, podman_supports_keep_id_remap)
#   - CLI flag parsing (--anonymized-paths, --worktree, --no-config,
#     --install-config, --nvidia)
#   - container name normalization
#   - env var passthrough (CLAUDE_CODE_OAUTH_TOKEN, CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS)
#   - fork-specific .yolo/-based image derivation (resolve_image)
#   - claude --name= auto-injection
#   - config file sourcing

load test_helper/common

setup() {
    setup_yolo_test
}

# Pull a single bash function definition out of bin/yolo so we can call it
# directly. Relies on bin/yolo's house style: `name() {` opens the function
# and a bare `}` closes it.
extract_function() {
    awk -v fn="$1" '
        $0 == fn"() {" { in_fn=1 }
        in_fn { print }
        in_fn && $0 == "}" { exit }
    ' "$YOLO_BIN"
}

# ---------------------------------------------------------------------------
# expand_volume
# ---------------------------------------------------------------------------

@test "expand_volume: bare path gets 1-to-1 mapping with :z" {
    eval "$(extract_function expand_volume)"
    HOME=/h run expand_volume "~/projects"
    assert_success
    assert_output "/h/projects:/h/projects:z"
}

@test "expand_volume: :: shorthand preserves explicit opts" {
    eval "$(extract_function expand_volume)"
    HOME=/h run expand_volume "~/projects::ro,z"
    assert_success
    assert_output "/h/projects:/h/projects:ro,z"
}

@test "expand_volume: host:container partial form gets :z" {
    eval "$(extract_function expand_volume)"
    run expand_volume "/host:/container"
    assert_success
    assert_output "/host:/container:z"
}

@test "expand_volume: host:container:opts full form passes through" {
    eval "$(extract_function expand_volume)"
    run expand_volume "/host:/container:ro,z"
    assert_success
    assert_output "/host:/container:ro,z"
}

# ---------------------------------------------------------------------------
# podman_supports_keep_id_remap (the pure-bash version comparator)
# ---------------------------------------------------------------------------

@test "podman_supports_keep_id_remap: 4.3.0 is supported" {
    eval "$(extract_function podman_supports_keep_id_remap)"
    podman() { echo "4.3.0"; }
    podman_supports_keep_id_remap
}

@test "podman_supports_keep_id_remap: 4.2.9 is rejected" {
    eval "$(extract_function podman_supports_keep_id_remap)"
    podman() { echo "4.2.9"; }
    ! podman_supports_keep_id_remap
}

@test "podman_supports_keep_id_remap: pre-release suffix is stripped (4.9.4-rhel)" {
    eval "$(extract_function podman_supports_keep_id_remap)"
    podman() { echo "4.9.4-rhel"; }
    podman_supports_keep_id_remap
}

@test "podman_supports_keep_id_remap: 5.0.0 is supported" {
    eval "$(extract_function podman_supports_keep_id_remap)"
    podman() { echo "5.0.0"; }
    podman_supports_keep_id_remap
}

@test "podman_supports_keep_id_remap: empty version is rejected" {
    eval "$(extract_function podman_supports_keep_id_remap)"
    podman() { echo ""; }
    ! podman_supports_keep_id_remap
}

@test "podman_supports_keep_id_remap: 3.4.4 (older podman) is rejected" {
    eval "$(extract_function podman_supports_keep_id_remap)"
    podman() { echo "3.4.4"; }
    ! podman_supports_keep_id_remap
}

# ---------------------------------------------------------------------------
# Flag parsing
# ---------------------------------------------------------------------------

@test "--help prints usage and exits 0" {
    run_yolo --help
    assert_success
    assert_output --partial "Usage: yolo"
    assert_output --partial "--anonymized-paths"
}

@test "--worktree=skip parses without error" {
    run_yolo --worktree=skip
    assert_success
}

@test "--worktree=bind parses without error" {
    run_yolo --worktree=bind
    assert_success
}

@test "--worktree=error parses without error" {
    run_yolo --worktree=error
    assert_success
}

@test "--worktree=ask parses without error (non-worktree dir, no prompt fires)" {
    run_yolo --worktree=ask
    assert_success
}

@test "--worktree=bogus is rejected with an error message" {
    run_yolo --worktree=bogus
    assert_failure
    assert_output --partial "Invalid --worktree value"
}

@test "--no-config skips loading .git/yolo/config" {
    mkdir -p .git/yolo
    cat >.git/yolo/config <<'EOF'
YOLO_PODMAN_VOLUMES=("/should-not-appear:/x")
EOF
    run_yolo --no-config
    assert_success
    refute [ podman_log_has_arg "/should-not-appear:/x:z" ]
    ! podman_log_has_arg "/should-not-appear:/x:z"
}

@test "--install-config creates .git/yolo/config from template" {
    run_yolo --install-config
    assert_success
    assert [ -f .git/yolo/config ]
    grep -q "YOLO Project Configuration" .git/yolo/config
    grep -q "YOLO_PODMAN_VOLUMES" .git/yolo/config
}

@test "--install-config: existing config is shown, not overwritten" {
    mkdir -p .git/yolo
    echo "# my custom config" >.git/yolo/config
    run_yolo --install-config
    assert_success
    assert_output --partial "already exists"
    run cat .git/yolo/config
    assert_output "# my custom config"
}

# ---------------------------------------------------------------------------
# --anonymized-paths
# ---------------------------------------------------------------------------

@test "--anonymized-paths uses /claude and /workspace" {
    run_yolo --anonymized-paths
    assert_success
    podman_log_has_arg "$HOME/.claude:/claude:z"
    podman_log_has_arg "$WORK:/workspace:z"
    podman_log_has_arg "CLAUDE_CONFIG_DIR=/claude"
    podman_log_has_arg "-w"
    podman_log_has_arg "/workspace"
}

@test "default (no --anonymized-paths) preserves host paths" {
    run_yolo
    assert_success
    podman_log_has_arg "$HOME/.claude:$HOME/.claude:z"
    podman_log_has_arg "$WORK:$WORK:z"
    podman_log_has_arg "CLAUDE_CONFIG_DIR=$HOME/.claude"
}

# ---------------------------------------------------------------------------
# --nvidia
# ---------------------------------------------------------------------------

@test "--nvidia adds CDI device and label=disable to podman args" {
    run_yolo --nvidia
    assert_success
    podman_log_has_arg "nvidia.com/gpu=all"
    podman_log_has_arg "label=disable"
}

@test "no --nvidia: no GPU device args" {
    run_yolo
    assert_success
    run podman_log_has_arg "nvidia.com/gpu=all"
    assert_failure
}

# ---------------------------------------------------------------------------
# Container name normalization
# ---------------------------------------------------------------------------

@test "container --name= strips leading dots and underscores" {
    mkdir -p "$WORK/.hidden"
    cd "$WORK/.hidden"
    git init -q -b main 2>/dev/null || git init -q
    run_yolo
    assert_success
    # The --name=... arg passed to podman should never start with . or _
    run bash -c "awk -F'\t' '/^run\t/ { for (i=1;i<=NF;i++) if (\$i ~ /^--name=/) { print \$i; exit } }' \"$MOCK_PODMAN_LOG\""
    assert_success
    [[ "$output" =~ ^--name=[^._] ]]
}

# ---------------------------------------------------------------------------
# Env var passthrough
# ---------------------------------------------------------------------------

@test "CLAUDE_CODE_OAUTH_TOKEN is passed through with -e" {
    export CLAUDE_CODE_OAUTH_TOKEN="sk-test-token"
    run_yolo
    assert_success
    # `-e CLAUDE_CODE_OAUTH_TOKEN` should appear as separate args
    awk -F'\t' '/^run\t/ {
        for (i=1;i<NF;i++) if ($i=="-e" && $(i+1)=="CLAUDE_CODE_OAUTH_TOKEN") { found=1; exit }
    } END { exit !found }' "$MOCK_PODMAN_LOG"
}

@test "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS is passed through with -e" {
    export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS="1"
    run_yolo
    assert_success
    awk -F'\t' '/^run\t/ {
        for (i=1;i<NF;i++) if ($i=="-e" && $(i+1)=="CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS") { found=1; exit }
    } END { exit !found }' "$MOCK_PODMAN_LOG"
}

# ---------------------------------------------------------------------------
# --name auto-injection
# ---------------------------------------------------------------------------

@test "--name=<auto> is injected into claude args" {
    run_yolo
    assert_success
    # Pull the args after the image name. The image is always last podman option,
    # followed by 'claude', then args. Check that --name= appears somewhere after 'claude'.
    awk -F'\t' '/^run\t/ {
        seen=0
        for (i=1;i<=NF;i++) {
            if ($i=="claude") seen=1
            if (seen && $i ~ /^--name=/) { found=1; exit }
        }
    } END { exit !found }' "$MOCK_PODMAN_LOG"
}

@test "user-supplied --name after -- appears after the auto --name (so claude takes user value)" {
    run_yolo -- --name=user-supplied
    assert_success
    awk -F'\t' '/^run\t/ {
        seen_claude=0; last_name=""
        for (i=1;i<=NF;i++) {
            if ($i=="claude") seen_claude=1
            if (seen_claude && $i ~ /^--name=/) last_name=$i
        }
        if (last_name=="--name=user-supplied") { found=1 }
    } END { exit !found }' "$MOCK_PODMAN_LOG"
}

# ---------------------------------------------------------------------------
# Config file sourcing
# ---------------------------------------------------------------------------

@test "config: YOLO_PODMAN_VOLUMES are expanded and added as -v" {
    mkdir -p .git/yolo
    cat >.git/yolo/config <<'EOF'
YOLO_PODMAN_VOLUMES=("/data::ro,z")
EOF
    run_yolo
    assert_success
    podman_log_has_arg "/data:/data:ro,z"
}

@test "config: YOLO_PODMAN_OPTIONS are added to podman args" {
    mkdir -p .git/yolo
    cat >.git/yolo/config <<'EOF'
YOLO_PODMAN_OPTIONS=("--network=host")
EOF
    run_yolo
    assert_success
    podman_log_has_arg "--network=host"
}

@test "config: YOLO_CLAUDE_ARGS are added to claude args" {
    mkdir -p .git/yolo
    cat >.git/yolo/config <<'EOF'
YOLO_CLAUDE_ARGS=("--model=claude-foo")
EOF
    run_yolo
    assert_success
    podman_log_has_arg "--model=claude-foo"
}

@test "config: --no-config suppresses all three array categories" {
    mkdir -p .git/yolo
    cat >.git/yolo/config <<'EOF'
YOLO_PODMAN_VOLUMES=("/configvol::ro,z")
YOLO_PODMAN_OPTIONS=("--network=host")
YOLO_CLAUDE_ARGS=("--model=claude-foo")
EOF
    run_yolo --no-config
    assert_success
    run podman_log_has_arg "/configvol:/configvol:ro,z"
    assert_failure
    run podman_log_has_arg "--network=host"
    assert_failure
    run podman_log_has_arg "--model=claude-foo"
    assert_failure
}

# ---------------------------------------------------------------------------
# resolve_image (.yolo/-based derivation)
# ---------------------------------------------------------------------------

@test "resolve_image: no .yolo/ -> uses base image, no build" {
    run_yolo
    assert_success
    podman_log_has_arg "con-bomination-claude-code"
    [ "$(built_tag_count)" = "0" ]
}

@test "resolve_image: empty .yolo/ -> uses base image, no build" {
    mkdir -p .yolo
    run_yolo
    assert_success
    podman_log_has_arg "con-bomination-claude-code"
    [ "$(built_tag_count)" = "0" ]
}

@test "resolve_image: only root-setup.sh -> builds derived image yolo-<hash>" {
    mkdir -p .yolo
    echo "echo root" >.yolo/root-setup.sh
    run_yolo
    assert_success
    [ "$(built_tag_count)" = "1" ]
    tag="$(first_built_tag)"
    [[ "$tag" =~ ^yolo-[0-9a-f]{12}$ ]]
    # Final podman run should use the derived tag, not the base.
    podman_log_has_arg "$tag"
}

@test "resolve_image: user-setup.sh content yields a different hash from root-setup.sh content" {
    # Note: the script's hash input concatenates script contents WITHOUT a
    # per-file delimiter, so identical content in different files would
    # collide. Realistic usage has distinct content; this test asserts that
    # case behaves as expected.
    mkdir -p .yolo
    echo "echo root-side" >.yolo/root-setup.sh
    run_yolo
    assert_success
    root_only_tag="$(first_built_tag)"

    rm -f .yolo/root-setup.sh
    echo "echo user-side" >.yolo/user-setup.sh
    : >"$MOCK_PODMAN_LOG"
    : >"$MOCK_PODMAN_BUILT_TAGS"
    export MOCK_PODMAN_EXISTING_IMAGES="con-bomination-claude-code"

    run_yolo
    assert_success
    user_only_tag="$(first_built_tag)"

    [ "$root_only_tag" != "$user_only_tag" ]
}

@test "resolve_image: both scripts -> different hash than either alone" {
    mkdir -p .yolo
    echo "echo root" >.yolo/root-setup.sh
    run_yolo
    assert_success
    root_only_tag="$(first_built_tag)"

    echo "echo user" >.yolo/user-setup.sh
    : >"$MOCK_PODMAN_LOG"
    : >"$MOCK_PODMAN_BUILT_TAGS"
    export MOCK_PODMAN_EXISTING_IMAGES="con-bomination-claude-code"

    run_yolo
    assert_success
    both_tag="$(first_built_tag)"

    [ "$both_tag" != "$root_only_tag" ]

    # And different from user-only too.
    rm -f .yolo/root-setup.sh
    : >"$MOCK_PODMAN_LOG"
    : >"$MOCK_PODMAN_BUILT_TAGS"
    export MOCK_PODMAN_EXISTING_IMAGES="con-bomination-claude-code"
    run_yolo
    assert_success
    user_only_tag="$(first_built_tag)"
    [ "$both_tag" != "$user_only_tag" ]
}

@test "resolve_image: same scripts twice -> same hash (determinism)" {
    mkdir -p .yolo
    echo "echo root" >.yolo/root-setup.sh
    echo "echo user" >.yolo/user-setup.sh
    run_yolo
    assert_success
    first_tag="$(first_built_tag)"

    : >"$MOCK_PODMAN_LOG"
    : >"$MOCK_PODMAN_BUILT_TAGS"
    export MOCK_PODMAN_EXISTING_IMAGES="con-bomination-claude-code"

    run_yolo
    assert_success
    second_tag="$(first_built_tag)"

    [ "$first_tag" = "$second_tag" ]
}

@test "resolve_image: changing one byte changes the hash" {
    mkdir -p .yolo
    echo "echo aaa" >.yolo/root-setup.sh
    run_yolo
    assert_success
    tag_a="$(first_built_tag)"

    echo "echo bbb" >.yolo/root-setup.sh
    : >"$MOCK_PODMAN_LOG"
    : >"$MOCK_PODMAN_BUILT_TAGS"
    export MOCK_PODMAN_EXISTING_IMAGES="con-bomination-claude-code"

    run_yolo
    assert_success
    tag_b="$(first_built_tag)"

    [ "$tag_a" != "$tag_b" ]
}

@test "resolve_image: cached image (no --rebuild) -> no build" {
    mkdir -p .yolo
    echo "echo root" >.yolo/root-setup.sh

    # First run: builds and we record the tag.
    run_yolo
    assert_success
    cached_tag="$(first_built_tag)"

    # Second run: pretend the derived image now exists.
    : >"$MOCK_PODMAN_LOG"
    : >"$MOCK_PODMAN_BUILT_TAGS"
    export MOCK_PODMAN_EXISTING_IMAGES="con-bomination-claude-code $cached_tag"

    run_yolo
    assert_success
    [ "$(built_tag_count)" = "0" ]
    # And the cached tag is used.
    podman_log_has_arg "$cached_tag"
}

@test "resolve_image: --rebuild forces build even when image exists" {
    mkdir -p .yolo
    echo "echo root" >.yolo/root-setup.sh

    run_yolo
    assert_success
    cached_tag="$(first_built_tag)"

    : >"$MOCK_PODMAN_LOG"
    : >"$MOCK_PODMAN_BUILT_TAGS"
    export MOCK_PODMAN_EXISTING_IMAGES="con-bomination-claude-code $cached_tag"

    run_yolo --rebuild
    assert_success
    [ "$(built_tag_count)" = "1" ]
    [ "$(first_built_tag)" = "$cached_tag" ]
}

@test "resolve_image: missing base image -> error and exit 1" {
    mkdir -p .yolo
    echo "echo root" >.yolo/root-setup.sh
    export MOCK_PODMAN_EXISTING_IMAGES=""
    run_yolo
    assert_failure
    assert_output --partial "Base image 'con-bomination-claude-code' not found"
}
