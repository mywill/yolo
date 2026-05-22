#!/usr/bin/env bats
# Test suite for bin/yolo.
#
# Covers:
#   - pure helper functions (expand_volume, podman_supports_keep_id_remap)
#   - CLI flag parsing (--worktree, --no-config, --install-config, --nvidia)
#   - container name normalization
#   - env var passthrough (CLAUDE_CODE_OAUTH_TOKEN, CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS)
#   - fork-specific .yolo/-based image derivation (resolve_image)
#   - claude --name= auto-injection
#   - config file sourcing
#   - multi-harness dispatch (claude/opencode; codex deferred — see SPEC.md §10)
#     and HARNESS precedence
#   - container-path mounts under /home/agent/... regardless of host $HOME
#
# Tests that target the deferred codex harness are kept in this file but
# guarded with `skip "codex harness temporarily disabled — see SPEC.md §10"`.
# Re-enabling codex = grep for that string and delete those lines.

load test_helper/common

setup() {
    setup_yolo_test
}

# Pull a single bash function definition out of a source file so we can call
# it directly. Source defaults to $YOLO_BIN; pass a second arg (e.g.
# $SETUP_YOLO_BIN) to extract from another file. Relies on the house style:
# `name() {` opens the function and a bare `}` closes it.
extract_function() {
    local fn="$1"
    local src="${2:-$YOLO_BIN}"
    awk -v fn="$fn" '
        $0 == fn"() {" { in_fn=1 }
        in_fn { print }
        in_fn && $0 == "}" { exit }
    ' "$src"
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

@test "expand_volume: :: shorthand auto-appends z when missing (SELinux)" {
    eval "$(extract_function expand_volume)"
    HOME=/h run expand_volume "~/data::ro"
    assert_success
    assert_output "/h/data:/h/data:ro,z"
}

@test "expand_volume: :: shorthand preserves explicit Z (mutually exclusive with z)" {
    eval "$(extract_function expand_volume)"
    HOME=/h run expand_volume "~/data::Z"
    assert_success
    assert_output "/h/data:/h/data:Z"
}

@test "expand_volume: :: shorthand auto-appends z to non-ro opts" {
    eval "$(extract_function expand_volume)"
    HOME=/h run expand_volume "~/data::noexec"
    assert_success
    assert_output "/h/data:/h/data:noexec,z"
}

@test "expand_volume: :: shorthand finds z mid-list, no double-append" {
    eval "$(extract_function expand_volume)"
    HOME=/h run expand_volume "~/data::noexec,z,ro"
    assert_success
    assert_output "/h/data:/h/data:noexec,z,ro"
}

@test "expand_volume: :: shorthand with empty opts falls back to bare-path z" {
    eval "$(extract_function expand_volume)"
    HOME=/h run expand_volume "~/data::"
    assert_success
    assert_output "/h/data:/h/data:z"
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
    assert_output --partial "--harness=NAME"
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

@test "--worktree skip (space form) parses without error" {
    run_yolo --worktree skip
    assert_success
    # The literal --worktree token must not leak through to podman/harness.
    ! podman_log_has_arg "--worktree"
}

@test "--worktree bind (space form) parses without error" {
    run_yolo --worktree bind
    assert_success
    ! podman_log_has_arg "--worktree"
}

@test "--worktree bogus (space form) is rejected with an error message" {
    run_yolo --worktree bogus
    assert_failure
    assert_output --partial "Invalid --worktree value"
}

@test "--worktree with no value errors with a useful message" {
    run_yolo --worktree
    assert_failure
    assert_output --partial "--worktree requires a value"
}

@test "--harness opencode (space form) selects the opencode profile" {
    run_yolo --harness opencode
    assert_success
    awk -F'\t' '/^run\t/ {
        for (i=1;i<=NF;i++) if ($i=="opencode") { found=1; exit }
    } END { exit !found }' "$MOCK_PODMAN_LOG"
}

@test "--harness with no value errors with a useful message" {
    run_yolo --harness
    assert_failure
    assert_output --partial "--harness requires a value"
}

@test "--harness immediately followed by another flag errors instead of swallowing it" {
    run_yolo --harness --nvidia
    assert_failure
    assert_output --partial "--harness requires a value"
}

@test "--entrypoint with no value errors with a useful message" {
    run_yolo --entrypoint
    assert_failure
    assert_output --partial "--entrypoint requires a value"
}

@test "--entrypoint immediately followed by another flag errors instead of swallowing it" {
    run_yolo --entrypoint --nvidia
    assert_failure
    assert_output --partial "--entrypoint requires a value"
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
# Default mount layout (claude harness): host source -> /home/agent/... target
# ---------------------------------------------------------------------------

@test "default mode: claude config mounts at /home/agent/.claude" {
    run_yolo
    assert_success
    podman_log_has_arg "$HOME/.claude:/home/agent/.claude:z"
    podman_log_has_arg "CLAUDE_CONFIG_DIR=/home/agent/.claude"
}

@test "default mode: workspace mounts at host \$(pwd) on both sides" {
    run_yolo
    assert_success
    podman_log_has_arg "$WORK:$WORK:z"
    podman_log_has_arg "-w"
    podman_log_has_arg "$WORK"
}

@test "--anonymized-paths is consumed with a deprecation note on stderr" {
    run_yolo --anonymized-paths
    assert_success
    assert_output --partial "--anonymized-paths was removed"
    # The token must not leak through to podman or the harness, and must not
    # revive the old /claude or /workspace container targets.
    ! podman_log_has_arg "--anonymized-paths"
    ! podman_log_has_arg "$HOME/.claude:/claude:z"
    ! podman_log_has_arg "$WORK:/workspace:z"
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

@test "config: YOLO_HARNESS_ARGS are added to the active harness's args" {
    mkdir -p .git/yolo
    cat >.git/yolo/config <<'EOF'
YOLO_HARNESS_ARGS=("--model=claude-foo")
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
YOLO_HARNESS_ARGS=("--model=claude-foo")
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
    podman_log_has_arg "yolo-base"
    [ "$(built_tag_count)" = "0" ]
}

@test "resolve_image: empty .yolo/ -> uses base image, no build" {
    mkdir -p .yolo
    run_yolo
    assert_success
    podman_log_has_arg "yolo-base"
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

@test "resolve_image: only user-setup.sh -> different hash than root-only with same content" {
    # Locks in the per-file delimiter behavior: identical content in
    # root-setup.sh vs user-setup.sh must produce different hashes, because
    # the two run in different Dockerfile stages (root vs claude user).
    mkdir -p .yolo
    echo "echo shared" >.yolo/root-setup.sh
    run_yolo
    assert_success
    root_only_tag="$(first_built_tag)"

    rm -f .yolo/root-setup.sh
    echo "echo shared" >.yolo/user-setup.sh
    : >"$MOCK_PODMAN_LOG"
    : >"$MOCK_PODMAN_BUILT_TAGS"
    export MOCK_PODMAN_EXISTING_IMAGES="yolo-base"

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
    export MOCK_PODMAN_EXISTING_IMAGES="yolo-base"

    run_yolo
    assert_success
    both_tag="$(first_built_tag)"

    [ "$both_tag" != "$root_only_tag" ]

    # And different from user-only too.
    rm -f .yolo/root-setup.sh
    : >"$MOCK_PODMAN_LOG"
    : >"$MOCK_PODMAN_BUILT_TAGS"
    export MOCK_PODMAN_EXISTING_IMAGES="yolo-base"
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
    export MOCK_PODMAN_EXISTING_IMAGES="yolo-base"

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
    export MOCK_PODMAN_EXISTING_IMAGES="yolo-base"

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
    export MOCK_PODMAN_EXISTING_IMAGES="yolo-base $cached_tag"

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
    export MOCK_PODMAN_EXISTING_IMAGES="yolo-base $cached_tag"

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
    assert_output --partial "Base image 'yolo-base' not found"
}

# ---------------------------------------------------------------------------
# select_harness profile dispatch
# ---------------------------------------------------------------------------

@test "select_harness:claude sets claude profile globals" {
    eval "$(extract_function select_harness)"
    HOME=/h select_harness claude
    [ "$HARNESS_CMD" = "claude" ]
    [ "$HARNESS_HOST_DIR" = "/h/.claude" ]
    [ "$HARNESS_CONTAINER_DIR" = "/home/agent/.claude" ]
    [ "$HARNESS_CONFIG_ENV_NAME" = "CLAUDE_CONFIG_DIR" ]
    [ "$HARNESS_INJECT_NAME" = "1" ]
    [ "${HARNESS_DEFAULT_ARGS[0]}" = "--dangerously-skip-permissions" ]
    [[ " ${HARNESS_ENV_PASSTHROUGH[*]} " == *" CLAUDE_CODE_OAUTH_TOKEN "* ]]
    [[ " ${HARNESS_ENV_PASSTHROUGH[*]} " == *" CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS "* ]]
    [ "${#HARNESS_EXTRA_MOUNTS[@]}" -eq 0 ]
}

@test "select_harness:opencode sets opencode profile globals" {
    eval "$(extract_function select_harness)"
    HOME=/h select_harness opencode
    [ "$HARNESS_CMD" = "opencode" ]
    [ "$HARNESS_HOST_DIR" = "/h/.config/opencode" ]
    [ "$HARNESS_CONTAINER_DIR" = "/home/agent/.config/opencode" ]
    [ "$HARNESS_CONFIG_ENV_NAME" = "" ]
    [ "$HARNESS_INJECT_NAME" = "0" ]
    # opencode reads its yolo-mode signal from an env var (forced), not a CLI flag.
    [ "${#HARNESS_DEFAULT_ARGS[@]}" -eq 0 ]
    [[ " ${HARNESS_FORCED_ENV[*]} " == *" OPENCODE_DANGEROUSLY_SKIP_PERMISSIONS=true "* ]]
    # opencode extra mounts: host source -> /home/agent/... container target
    [[ " ${HARNESS_EXTRA_MOUNTS[*]} " == *" /h/.local/share/opencode:/home/agent/.local/share/opencode:z "* ]]
    [[ " ${HARNESS_EXTRA_MOUNTS[*]} " == *" /h/.claude/skills:/home/agent/.claude/skills:ro,z "* ]]
    [[ " ${HARNESS_EXTRA_MOUNTS[*]} " == *" /h/.agents/skills:/home/agent/.agents/skills:ro,z "* ]]
    [[ " ${HARNESS_ENV_PASSTHROUGH[*]} " == *" OPENAI_API_KEY "* ]]
    [[ " ${HARNESS_ENV_PASSTHROUGH[*]} " == *" ANTHROPIC_API_KEY "* ]]
    # Passthrough no longer carries OPENCODE_DANGEROUSLY_SKIP_PERMISSIONS —
    # it's force-set above so the yolo-mode signal doesn't depend on host env.
    [[ " ${HARNESS_ENV_PASSTHROUGH[*]} " != *" OPENCODE_DANGEROUSLY_SKIP_PERMISSIONS "* ]]
}

@test "select_harness:codex sets codex profile globals" {
    skip "codex harness temporarily disabled — see SPEC.md §10"
    eval "$(extract_function select_harness)"
    HOME=/h select_harness codex
    [ "$HARNESS_CMD" = "codex" ]
    [ "$HARNESS_HOST_DIR" = "/h/.codex" ]
    [ "$HARNESS_CONTAINER_DIR" = "/home/agent/.codex" ]
    [ "$HARNESS_CONFIG_ENV_NAME" = "CODEX_HOME" ]
    [ "$HARNESS_INJECT_NAME" = "0" ]
    [ "${HARNESS_DEFAULT_ARGS[0]}" = "--dangerously-bypass-approvals-and-sandbox" ]
    [ "${HARNESS_ENV_PASSTHROUGH[0]}" = "OPENAI_API_KEY" ]
    # codex extra mounts: host source -> /home/agent/... container target
    [[ " ${HARNESS_EXTRA_MOUNTS[*]} " == *" /h/.claude/skills:/home/agent/.claude/skills:ro,z "* ]]
    [[ " ${HARNESS_EXTRA_MOUNTS[*]} " == *" /h/.agents/skills:/home/agent/.agents/skills:ro,z "* ]]
}

@test "--harness=codex errors with 'planned but not yet enabled' (deferred)" {
    run_yolo --harness=codex
    assert_failure
    assert_output --partial "codex harness is planned but not yet enabled"
    assert_output --partial "Use --harness=claude or --harness=opencode"
}

@test "select_harness:unknown name -> error and exit 1" {
    run_yolo --harness=bogus
    assert_failure
    assert_output --partial "Unknown harness 'bogus'"
}

# ---------------------------------------------------------------------------
# --harness end-to-end: command, mounts, env
# ---------------------------------------------------------------------------

@test "--harness=opencode runs opencode as the container command" {
    run_yolo --harness=opencode
    assert_success
    awk -F'\t' '/^run\t/ {
        for (i=1;i<=NF;i++) if ($i=="opencode") { found=1; exit }
    } END { exit !found }' "$MOCK_PODMAN_LOG"
}

@test "--harness=opencode does NOT pass --dangerously-skip-permissions on the CLI" {
    # Current opencode rejects this flag and prints help. The yolo-mode signal
    # is delivered via OPENCODE_DANGEROUSLY_SKIP_PERMISSIONS=true instead.
    run_yolo --harness=opencode
    assert_success
    ! awk -F'\t' '/^run\t/ {
        seen=0
        for (i=1;i<=NF;i++) {
            if ($i=="opencode") seen=1
            if (seen && $i=="--dangerously-skip-permissions") { found=1; exit }
        }
    } END { exit !found }' "$MOCK_PODMAN_LOG"
}

@test "--harness=opencode forces OPENCODE_DANGEROUSLY_SKIP_PERMISSIONS=true" {
    run_yolo --harness=opencode
    assert_success
    awk -F'\t' '/^run\t/ {
        for (i=1;i<NF;i++) if ($i=="-e" && $(i+1)=="OPENCODE_DANGEROUSLY_SKIP_PERMISSIONS=true") { found=1; exit }
    } END { exit !found }' "$MOCK_PODMAN_LOG"
}

@test "--harness=opencode does NOT inject auto --name= into harness args" {
    run_yolo --harness=opencode
    assert_success
    # The podman --name=<container> still appears as a podman flag, but no
    # --name= arg should follow `opencode` in the in-container command.
    ! awk -F'\t' '/^run\t/ {
        seen=0
        for (i=1;i<=NF;i++) {
            if ($i=="opencode") seen=1
            if (seen && $i ~ /^--name=/) { found=1; exit }
        }
    } END { exit !found }' "$MOCK_PODMAN_LOG"
}

@test "--harness=opencode mounts both opencode dirs at /home/agent/..." {
    run_yolo --harness=opencode
    assert_success
    podman_log_has_arg "$HOME/.config/opencode:/home/agent/.config/opencode:z"
    podman_log_has_arg "$HOME/.local/share/opencode:/home/agent/.local/share/opencode:z"
}

@test "--harness=opencode forwards provider API key env vars by name" {
    run_yolo --harness=opencode
    assert_success
    awk -F'\t' '/^run\t/ {
        for (i=1;i<NF;i++) if ($i=="-e" && $(i+1)=="OPENAI_API_KEY") found=1
        for (i=1;i<NF;i++) if ($i=="-e" && $(i+1)=="ANTHROPIC_API_KEY") found2=1
    } END { exit !(found && found2) }' "$MOCK_PODMAN_LOG"
}

@test "--harness=opencode does NOT forward CLAUDE_CODE_OAUTH_TOKEN" {
    run_yolo --harness=opencode
    assert_success
    ! awk -F'\t' '/^run\t/ {
        for (i=1;i<NF;i++) if ($i=="-e" && $(i+1)=="CLAUDE_CODE_OAUTH_TOKEN") { found=1; exit }
    } END { exit !found }' "$MOCK_PODMAN_LOG"
}

@test "--harness=codex runs codex with bypass flag" {
    skip "codex harness temporarily disabled — see SPEC.md §10"
    run_yolo --harness=codex
    assert_success
    awk -F'\t' '/^run\t/ {
        for (i=1;i<=NF;i++) if ($i=="codex") found=1
        for (i=1;i<=NF;i++) if ($i=="--dangerously-bypass-approvals-and-sandbox") found2=1
    } END { exit !(found && found2) }' "$MOCK_PODMAN_LOG"
}

@test "--harness=codex mounts ~/.codex at /home/agent/.codex and forwards OPENAI_API_KEY" {
    skip "codex harness temporarily disabled — see SPEC.md §10"
    run_yolo --harness=codex
    assert_success
    podman_log_has_arg "$HOME/.codex:/home/agent/.codex:z"
    awk -F'\t' '/^run\t/ {
        for (i=1;i<NF;i++) if ($i=="-e" && $(i+1)=="OPENAI_API_KEY") { found=1; exit }
    } END { exit !found }' "$MOCK_PODMAN_LOG"
}

@test "--harness=codex does NOT set CLAUDE_CONFIG_DIR" {
    skip "codex harness temporarily disabled — see SPEC.md §10"
    run_yolo --harness=codex
    assert_success
    ! awk -F'\t' '/^run\t/ {
        for (i=1;i<=NF;i++) if ($i ~ /^CLAUDE_CONFIG_DIR=/) { found=1; exit }
    } END { exit !found }' "$MOCK_PODMAN_LOG"
}

@test "--harness=opencode does NOT set CLAUDE_CONFIG_DIR" {
    run_yolo --harness=opencode
    assert_success
    ! awk -F'\t' '/^run\t/ {
        for (i=1;i<=NF;i++) if ($i ~ /^CLAUDE_CONFIG_DIR=/) { found=1; exit }
    } END { exit !found }' "$MOCK_PODMAN_LOG"
}

@test "--harness=opencode does NOT set CODEX_HOME" {
    run_yolo --harness=opencode
    assert_success
    ! awk -F'\t' '/^run\t/ {
        for (i=1;i<=NF;i++) if ($i ~ /^CODEX_HOME=/) { found=1; exit }
    } END { exit !found }' "$MOCK_PODMAN_LOG"
}

@test "claude harness sets CLAUDE_CONFIG_DIR exactly once" {
    run_yolo
    assert_success
    run bash -c 'awk -F"\t" "/^run\t/ { for (i=1;i<=NF;i++) if (\$i ~ /^CLAUDE_CONFIG_DIR=/) print \$i }" "$MOCK_PODMAN_LOG" | wc -l | tr -d " "'
    assert_success
    [ "$output" = "1" ]
}

@test "codex harness sets CODEX_HOME exactly once" {
    skip "codex harness temporarily disabled — see SPEC.md §10"
    run_yolo --harness=codex
    assert_success
    run bash -c 'awk -F"\t" "/^run\t/ { for (i=1;i<=NF;i++) if (\$i ~ /^CODEX_HOME=/) print \$i }" "$MOCK_PODMAN_LOG" | wc -l | tr -d " "'
    assert_success
    [ "$output" = "1" ]
}

@test "every harness forwards YOLO_HARNESS=<name> into the container" {
    # Covers every *active* harness. The codex branch is exercised by the
    # `--harness=codex errors with 'planned...'` test above instead.
    run_yolo
    assert_success
    podman_log_has_arg "YOLO_HARNESS=claude"

    : >"$MOCK_PODMAN_LOG"
    run_yolo --harness=opencode
    assert_success
    podman_log_has_arg "YOLO_HARNESS=opencode"
}

# ---------------------------------------------------------------------------
# HARNESS in config and precedence vs --harness flag
# ---------------------------------------------------------------------------

@test "config: HARNESS=opencode selects opencode" {
    mkdir -p .git/yolo
    cat >.git/yolo/config <<'EOF'
HARNESS="opencode"
EOF
    run_yolo
    assert_success
    awk -F'\t' '/^run\t/ {
        for (i=1;i<=NF;i++) if ($i=="opencode") { found=1; exit }
    } END { exit !found }' "$MOCK_PODMAN_LOG"
}

@test "--harness flag overrides HARNESS in config" {
    # Config picks opencode; CLI flag overrides back to claude.
    mkdir -p .git/yolo
    cat >.git/yolo/config <<'EOF'
HARNESS="opencode"
EOF
    run_yolo --harness=claude
    assert_success
    # claude runs (note `claude` is the basename of the command, picked up
    # as a token in the podman argv).
    awk -F'\t' '/^run\t/ {
        for (i=1;i<=NF;i++) if ($i=="claude") { found=1; exit }
    } END { exit !found }' "$MOCK_PODMAN_LOG"
    # And opencode is NOT used.
    ! awk -F'\t' '/^run\t/ {
        for (i=1;i<=NF;i++) if ($i=="opencode") { found=1; exit }
    } END { exit !found }' "$MOCK_PODMAN_LOG"
}

@test "shell env HARNESS=opencode selects opencode (precedence #3)" {
    HARNESS=opencode run_yolo
    assert_success
    awk -F'\t' '/^run\t/ {
        for (i=1;i<=NF;i++) if ($i=="opencode") { found=1; exit }
    } END { exit !found }' "$MOCK_PODMAN_LOG"
}

@test "shell env HARNESS=codex selects codex (precedence #3)" {
    skip "codex harness temporarily disabled — see SPEC.md §10"
    HARNESS=codex run_yolo
    assert_success
    awk -F'\t' '/^run\t/ {
        for (i=1;i<=NF;i++) if ($i=="codex") { found=1; exit }
    } END { exit !found }' "$MOCK_PODMAN_LOG"
}

@test "config HARNESS= overrides shell env HARNESS (precedence #2 > #3)" {
    # Config picks opencode; shell env wants claude. Config must win.
    mkdir -p .git/yolo
    cat >.git/yolo/config <<'EOF'
HARNESS="opencode"
EOF
    HARNESS=claude run_yolo
    assert_success
    # config wins: opencode runs, not claude.
    awk -F'\t' '/^run\t/ {
        for (i=1;i<=NF;i++) if ($i=="opencode") { found=1; exit }
    } END { exit !found }' "$MOCK_PODMAN_LOG"
    # claude binary not run (claude-specific env var won't appear either).
    ! awk -F'\t' '/^run\t/ {
        for (i=1;i<=NF;i++) if ($i ~ /^CLAUDE_CONFIG_DIR=/) { found=1; exit }
    } END { exit !found }' "$MOCK_PODMAN_LOG"
}

# ---------------------------------------------------------------------------
# YOLO_HARNESS_ARGS and YOLO_CLAUDE_ARGS (deprecated) semantics
# ---------------------------------------------------------------------------

@test "config: YOLO_HARNESS_ARGS are passed to opencode" {
    mkdir -p .git/yolo
    cat >.git/yolo/config <<'EOF'
HARNESS="opencode"
YOLO_HARNESS_ARGS=("--model=anthropic/claude-sonnet-4-6")
EOF
    run_yolo
    assert_success
    podman_log_has_arg "--model=anthropic/claude-sonnet-4-6"
}

@test "config: YOLO_CLAUDE_ARGS is deprecated, merged into YOLO_HARNESS_ARGS with warning (claude)" {
    mkdir -p .git/yolo
    cat >.git/yolo/config <<'EOF'
YOLO_CLAUDE_ARGS=("--legacy-flag")
EOF
    run_yolo
    assert_success
    # The value is applied to the harness.
    podman_log_has_arg "--legacy-flag"
    # And the deprecation warning fires.
    assert_output --partial "YOLO_CLAUDE_ARGS is deprecated"
}

@test "config: YOLO_CLAUDE_ARGS now applies for non-claude harnesses too (deprecated alias)" {
    mkdir -p .git/yolo
    cat >.git/yolo/config <<'EOF'
HARNESS="opencode"
YOLO_CLAUDE_ARGS=("--legacy-flag")
EOF
    run_yolo
    assert_success
    # Deprecated alias: contents land on the active harness regardless of name.
    podman_log_has_arg "--legacy-flag"
    assert_output --partial "YOLO_CLAUDE_ARGS is deprecated"
}

@test "config: YOLO_HARNESS_ARGS wins over YOLO_CLAUDE_ARGS on conflict (HARNESS_ARGS prepended last)" {
    mkdir -p .git/yolo
    cat >.git/yolo/config <<'EOF'
YOLO_CLAUDE_ARGS=("--model=legacy")
YOLO_HARNESS_ARGS=("--model=new")
EOF
    run_yolo
    assert_success
    # Both end up in argv; the LAST occurrence on the command line is what
    # the harness sees as the final value. Verify --model=new appears AFTER
    # --model=legacy in the in-container args.
    awk -F'\t' '/^run\t/ {
        seen_claude=0; legacy_idx=0; new_idx=0
        for (i=1;i<=NF;i++) {
            if ($i=="claude") seen_claude=1
            if (seen_claude && $i=="--model=legacy") legacy_idx=i
            if (seen_claude && $i=="--model=new") new_idx=i
        }
        if (legacy_idx > 0 && new_idx > legacy_idx) found=1
    } END { exit !found }' "$MOCK_PODMAN_LOG"
}

@test "config: no warning when YOLO_CLAUDE_ARGS is unset/empty" {
    mkdir -p .git/yolo
    cat >.git/yolo/config <<'EOF'
YOLO_HARNESS_ARGS=("--ok")
EOF
    run_yolo
    assert_success
    refute_output --partial "YOLO_CLAUDE_ARGS is deprecated"
}

# ---------------------------------------------------------------------------
# --entrypoint override bypasses harness profile
# ---------------------------------------------------------------------------

@test "--entrypoint=CMD bypasses harness defaults (no --dangerously-skip-permissions)" {
    run_yolo --entrypoint=bash -- -c "echo hi"
    assert_success
    awk -F'\t' '/^run\t/ {
        for (i=1;i<=NF;i++) if ($i=="bash") found_bash=1
    } END { exit !found_bash }' "$MOCK_PODMAN_LOG"
    ! awk -F'\t' '/^run\t/ {
        seen=0
        for (i=1;i<=NF;i++) {
            if ($i=="bash") seen=1
            if (seen && $i=="--dangerously-skip-permissions") { found=1; exit }
        }
    } END { exit !found }' "$MOCK_PODMAN_LOG"
}

# ---------------------------------------------------------------------------
# Cross-harness skill mounts (host source -> /home/agent/... target, read-only)
# ---------------------------------------------------------------------------

@test "--harness=opencode mounts skills at /home/agent/... read-only" {
    run_yolo --harness=opencode
    assert_success
    podman_log_has_arg "$HOME/.claude/skills:/home/agent/.claude/skills:ro,z"
    podman_log_has_arg "$HOME/.agents/skills:/home/agent/.agents/skills:ro,z"
}

@test "--harness=codex mounts skills at /home/agent/... read-only" {
    skip "codex harness temporarily disabled — see SPEC.md §10"
    run_yolo --harness=codex
    assert_success
    podman_log_has_arg "$HOME/.claude/skills:/home/agent/.claude/skills:ro,z"
    podman_log_has_arg "$HOME/.agents/skills:/home/agent/.agents/skills:ro,z"
}

@test "default claude harness does NOT add the ro skill mounts (full ~/.claude is already mounted rw)" {
    run_yolo
    assert_success
    # Claude already mounts the full ~/.claude rw at /home/agent/.claude,
    # which covers skills. Adding overlapping ro skill mounts would be
    # redundant and confuse podman.
    run podman_log_has_arg "$HOME/.claude/skills:/home/agent/.claude/skills:ro,z"
    assert_failure
}

# ---------------------------------------------------------------------------
# CODEX_HOME env (always at /home/agent/.codex, no anonymized variant)
# ---------------------------------------------------------------------------

@test "--harness=codex sets CODEX_HOME to the container path" {
    skip "codex harness temporarily disabled — see SPEC.md §10"
    run_yolo --harness=codex
    assert_success
    podman_log_has_arg "CODEX_HOME=/home/agent/.codex"
}

# ---------------------------------------------------------------------------
# warn_ambiguous_args heuristic
# ---------------------------------------------------------------------------

@test "warn_ambiguous_args: fires on -v without --" {
    run_yolo -v /tmp:/data
    assert_success
    assert_output --partial "looks like a podman flag"
    assert_output --partial "separate them from harness args with '--'"
}

@test "warn_ambiguous_args: fires on --network=host without --" {
    run_yolo --network=host
    assert_success
    assert_output --partial "looks like a podman flag"
}

@test "warn_ambiguous_args: silent when -- is present" {
    run_yolo -v /tmp:/data -- --resume
    assert_success
    refute_output --partial "looks like a podman flag"
}

@test "warn_ambiguous_args: silent when YOLO_NO_AMBIGUOUS_WARN=1" {
    YOLO_NO_AMBIGUOUS_WARN=1 run_yolo -v /tmp:/data
    assert_success
    refute_output --partial "looks like a podman flag"
}

@test "warn_ambiguous_args: silent on harness-only args like --resume" {
    run_yolo --resume
    assert_success
    refute_output --partial "looks like a podman flag"
}

@test "warn_ambiguous_args: fires on bare -e without --" {
    run_yolo -e FOO=bar
    assert_success
    assert_output --partial "looks like a podman flag"
}

@test "warn_ambiguous_args: fires on --env=value form" {
    run_yolo --env=FOO=bar
    assert_success
    assert_output --partial "looks like a podman flag"
}

@test "warn_ambiguous_args: does NOT fire on --env-file= (not in the matched list)" {
    run_yolo --env-file=./envs
    assert_success
    refute_output --partial "looks like a podman flag"
}

# ---------------------------------------------------------------------------
# Dockerfile invariants — regression guards for bugs that bit us live.
# These grep the source rather than running podman; cheap and CI-portable.
# ---------------------------------------------------------------------------

@test "Dockerfile: opencode install uses installer's --version CLI flag (not the wrong env var name)" {
    # The opencode installer reads \$VERSION, not \$OPENCODE_VERSION, so an
    # env-prefix approach silently no-ops the pin. Use the documented
    # `bash -s -- --version X.Y.Z` form instead.
    grep -q 'bash -s -- --version "\${OPENCODE_VERSION}"' "$PROJECT_ROOT/images/Dockerfile"
}

@test "Dockerfile: opencode install does NOT use the broken VAR=x cmd | bash form" {
    # `OPENCODE_VERSION=x curl ... | bash` only sets the env for curl, not
    # bash. Make sure no one reintroduces it.
    ! grep -E 'OPENCODE_VERSION="?\$\{?OPENCODE_VERSION\}?"? +curl' "$PROJECT_ROOT/images/Dockerfile"
}

@test "Dockerfile: npm global prefix is disjoint from native install tree" {
    skip "codex harness temporarily disabled — see SPEC.md §10"
    # Setting npm prefix = ~/.local makes `claude update` report a phantom
    # duplicate install because its native binary lands inside that tree.
    # Codex's npm prefix must stay outside ~/.local.
    #
    # NOTE: when re-enabling codex (see SPEC.md §10), the install will use
    # `npm install -g --prefix /home/agent/.npm-global` rather than
    # `npm config set prefix`, because the latter writes to ~/.npmrc and
    # breaks nvm. Update this assertion accordingly:
    #
    #   grep -q 'npm install -g --prefix /home/agent/.npm-global' Dockerfile
    #   ! grep -q 'npm config set prefix' Dockerfile
    grep -q 'npm install -g --prefix /home/agent/.npm-global' "$PROJECT_ROOT/images/Dockerfile"
    ! grep -q '^[^#]*npm config set prefix' "$PROJECT_ROOT/images/Dockerfile"
}

@test "Dockerfile: build-time sanity check verifies active harnesses on PATH" {
    # Catches binary-not-on-PATH regressions at build time instead of
    # container exec time. Codex is excluded while deferred; when re-enabled
    # (SPEC.md §10), restore `command -v codex` here.
    grep -q 'command -v claude.*command -v opencode' "$PROJECT_ROOT/images/Dockerfile"
    # And the deferred codex check must NOT be active.
    ! grep -qE '^[[:space:]]*RUN[[:space:]]+command -v claude.*command -v opencode.*command -v codex' "$PROJECT_ROOT/images/Dockerfile"
}

@test "Dockerfile: codex/opencode/claude versions are persisted as ENV (not just ARG)" {
    # ARG values don't survive into the running container, so the entrypoint
    # can't gate runtime updates on the build pin without ENV. CODEX_VERSION
    # is still wired even while the codex install is commented out so
    # re-enabling stays a one-touch change.
    grep -q 'ENV CODEX_VERSION=\$CODEX_VERSION' "$PROJECT_ROOT/images/Dockerfile"
    grep -q 'ENV OPENCODE_VERSION=\$OPENCODE_VERSION' "$PROJECT_ROOT/images/Dockerfile"
}

@test "Dockerfile: codex install block stays commented while deferred" {
    # Regression guard: if anyone re-enables codex, they MUST use
    # `--prefix` (not `npm config set prefix`) to avoid colliding with nvm
    # in .yolo/user-setup.sh. See SPEC.md §10.
    # While deferred:
    #   - no live (non-commented) `npm install -g ... @openai/codex` line
    #   - no live `npm config set prefix` line
    ! grep -qE '^[[:space:]]*RUN[[:space:]]+.*npm install -g.*@openai/codex' "$PROJECT_ROOT/images/Dockerfile"
    ! grep -qE '^[[:space:]]*RUN[[:space:]]+.*npm config set prefix' "$PROJECT_ROOT/images/Dockerfile"
}

# ---------------------------------------------------------------------------
# setup-yolo.sh: opencode TUI mouse-disabled detection
# ---------------------------------------------------------------------------

@test "opencode_tui_mouse_disabled: missing file returns false" {
    eval "$(extract_function opencode_tui_mouse_disabled "$SETUP_YOLO_BIN")"
    run opencode_tui_mouse_disabled "$BATS_TEST_TMPDIR/does-not-exist.json"
    assert_failure
}

@test "opencode_tui_mouse_disabled: file with \"mouse\": false returns true" {
    eval "$(extract_function opencode_tui_mouse_disabled "$SETUP_YOLO_BIN")"
    local f="$BATS_TEST_TMPDIR/tui.json"
    cat > "$f" <<'EOF'
{
  "$schema": "https://opencode.ai/tui.json",
  "mouse": false
}
EOF
    run opencode_tui_mouse_disabled "$f"
    assert_success
}

@test "opencode_tui_mouse_disabled: file with \"mouse\": true returns false" {
    eval "$(extract_function opencode_tui_mouse_disabled "$SETUP_YOLO_BIN")"
    local f="$BATS_TEST_TMPDIR/tui.json"
    echo '{"mouse": true}' > "$f"
    run opencode_tui_mouse_disabled "$f"
    assert_failure
}

@test "opencode_tui_mouse_disabled: unspaced \"mouse\":false still matches" {
    eval "$(extract_function opencode_tui_mouse_disabled "$SETUP_YOLO_BIN")"
    local f="$BATS_TEST_TMPDIR/tui.json"
    echo '{"mouse":false}' > "$f"
    run opencode_tui_mouse_disabled "$f"
    assert_success
}

@test "opencode_tui_mouse_disabled: cross-key false-positive is rejected (regression)" {
    # Previous regex '"mouse".*false' matched this incorrectly because .*
    # spans across "mouse": true and a later "false" on the same line.
    eval "$(extract_function opencode_tui_mouse_disabled "$SETUP_YOLO_BIN")"
    local f="$BATS_TEST_TMPDIR/tui.json"
    echo '{"mouse": true, "border": false}' > "$f"
    run opencode_tui_mouse_disabled "$f"
    assert_failure
}

@test "opencode_tui_mouse_disabled: \"mouseover\" substring is not mistaken for \"mouse\"" {
    eval "$(extract_function opencode_tui_mouse_disabled "$SETUP_YOLO_BIN")"
    local f="$BATS_TEST_TMPDIR/tui.json"
    echo '{"mouseover": false}' > "$f"
    run opencode_tui_mouse_disabled "$f"
    assert_failure
}

# ---------------------------------------------------------------------------
# setup-yolo.sh: write_opencode_tui_config
# ---------------------------------------------------------------------------

@test "write_opencode_tui_config: writes file with mouse:false and schema" {
    eval "$(extract_function write_opencode_tui_config "$SETUP_YOLO_BIN")"
    local target="$BATS_TEST_TMPDIR/cfg/opencode/tui.json"
    write_opencode_tui_config "$target"
    [ -f "$target" ]
    grep -q '"mouse": false' "$target"
    grep -q '"\$schema": "https://opencode.ai/tui.json"' "$target"
}

@test "write_opencode_tui_config: creates parent directory if missing" {
    eval "$(extract_function write_opencode_tui_config "$SETUP_YOLO_BIN")"
    local target="$BATS_TEST_TMPDIR/deep/new/path/tui.json"
    write_opencode_tui_config "$target"
    [ -f "$target" ]
}

@test "write_opencode_tui_config: round-trips through opencode_tui_mouse_disabled" {
    eval "$(extract_function write_opencode_tui_config "$SETUP_YOLO_BIN")"
    eval "$(extract_function opencode_tui_mouse_disabled "$SETUP_YOLO_BIN")"
    local target="$BATS_TEST_TMPDIR/tui.json"
    write_opencode_tui_config "$target"
    opencode_tui_mouse_disabled "$target"
}

# ---------------------------------------------------------------------------
# setup-yolo.sh: report_opencode_tui_status
# ---------------------------------------------------------------------------

@test "report_opencode_tui_status: prints visible confirmation when mouse disabled" {
    eval "$(extract_function opencode_tui_mouse_disabled "$SETUP_YOLO_BIN")"
    eval "$(extract_function report_opencode_tui_status "$SETUP_YOLO_BIN")"
    local f="$BATS_TEST_TMPDIR/tui.json"
    echo '{"mouse": false}' > "$f"
    run report_opencode_tui_status "$f"
    assert_success
    assert_output --partial "✓ opencode TUI"
    assert_output --partial "mouse capture already disabled"
    assert_output --partial "$f"
}

@test "report_opencode_tui_status: prints warning when mouse not disabled" {
    eval "$(extract_function opencode_tui_mouse_disabled "$SETUP_YOLO_BIN")"
    eval "$(extract_function report_opencode_tui_status "$SETUP_YOLO_BIN")"
    local f="$BATS_TEST_TMPDIR/tui.json"
    echo '{"mouse": true}' > "$f"
    run report_opencode_tui_status "$f"
    assert_failure
    assert_output --partial "⚠ opencode TUI"
    assert_output --partial "ENABLED"
    assert_output --partial "$f"
}

@test "report_opencode_tui_status: warning message tells user the exact fix" {
    eval "$(extract_function opencode_tui_mouse_disabled "$SETUP_YOLO_BIN")"
    eval "$(extract_function report_opencode_tui_status "$SETUP_YOLO_BIN")"
    local f="$BATS_TEST_TMPDIR/tui.json"
    echo '{}' > "$f"
    run report_opencode_tui_status "$f"
    assert_failure
    assert_output --partial '"mouse": false'
}

@test "report_opencode_tui_status: success wraps ✓ in green when COLOR_GREEN is set" {
    eval "$(extract_function opencode_tui_mouse_disabled "$SETUP_YOLO_BIN")"
    eval "$(extract_function report_opencode_tui_status "$SETUP_YOLO_BIN")"
    local f="$BATS_TEST_TMPDIR/tui.json"
    echo '{"mouse": false}' > "$f"
    COLOR_GREEN=$'\033[32m' COLOR_RESET=$'\033[0m' run report_opencode_tui_status "$f"
    assert_success
    [[ "$output" == *$'\033[32m'*"✓"* ]]
    [[ "$output" == *$'\033[0m'* ]]
}

@test "report_opencode_tui_status: warning wraps ⚠ in yellow+bold when COLOR_YELLOW/BOLD are set" {
    eval "$(extract_function opencode_tui_mouse_disabled "$SETUP_YOLO_BIN")"
    eval "$(extract_function report_opencode_tui_status "$SETUP_YOLO_BIN")"
    local f="$BATS_TEST_TMPDIR/tui.json"
    echo '{"mouse": true}' > "$f"
    COLOR_YELLOW=$'\033[33m' COLOR_BOLD=$'\033[1m' COLOR_RESET=$'\033[0m' \
        run report_opencode_tui_status "$f"
    assert_failure
    [[ "$output" == *$'\033[33m'* ]]
    [[ "$output" == *$'\033[1m'* ]]
    [[ "$output" == *$'\033[0m'* ]]
}

@test "report_opencode_tui_status: no color codes when COLOR_* vars are unset (NO_COLOR / non-TTY)" {
    eval "$(extract_function opencode_tui_mouse_disabled "$SETUP_YOLO_BIN")"
    eval "$(extract_function report_opencode_tui_status "$SETUP_YOLO_BIN")"
    local f="$BATS_TEST_TMPDIR/tui.json"
    echo '{"mouse": true}' > "$f"
    # Color vars deliberately unset; the function should emit plain text.
    run report_opencode_tui_status "$f"
    assert_failure
    refute_output --partial $'\033['
    assert_output --partial "⚠ opencode TUI"
}
