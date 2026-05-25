#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="yolo-base"
LEGACY_IMAGE_NAME="con-bomination-claude-code"
DOCKERFILE_DIR="$SCRIPT_DIR/images"

# Default options
BUILD_MODE="auto"
INSTALL_MODE="auto"

# ANSI colors for status messages. Suppressed when stdout isn't a TTY (e.g.
# piped to a file) or when the user sets NO_COLOR per https://no-color.org.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    COLOR_GREEN=$'\033[32m'
    COLOR_YELLOW=$'\033[33m'
    COLOR_BOLD=$'\033[1m'
    COLOR_RESET=$'\033[0m'
else
    COLOR_GREEN=
    COLOR_YELLOW=
    COLOR_BOLD=
    COLOR_RESET=
fi

show_help() {
    cat << EOF
Usage: setup-yolo.sh [OPTIONS]

Setup script for the yolo multi-harness containerized environment.
Builds the prebuilt image '$IMAGE_NAME' with claude and opencode installed
(codex is planned but not yet enabled), and (optionally) installs the
'yolo' launcher to ~/.local/bin.

OPTIONS:
    -h, --help              Show this help message
    --build=MODE            Control image building (default: auto)
                            auto - build only if image doesn't exist
                            yes  - always rebuild the image
                            no   - skip building (error if image missing)
    --install=MODE          Control yolo script installation (default: auto)
                            auto - install if missing or prompt if exists and differs
                            yes  - always install/overwrite without prompting
                            no   - skip installation

    Project-specific dependencies (Rust, Node, Python, etc.) are configured
    via .yolo/ setup scripts in your project directory, not in this base image.
    Templates live at images/examples/ (and are bundled with the skill at
    ~/.claude/skills/yolo/recipes/ when the skill is installed).
    See 'yolo --help' for details.

EXAMPLES:
    # Interactive setup (default)
    ./setup-yolo.sh

    # Rebuild image after Dockerfile changes
    ./setup-yolo.sh --build=yes

    # Rebuild and force install
    ./setup-yolo.sh --build=yes --install=yes

    # Only build image if needed, don't install script
    ./setup-yolo.sh --install=no

    # Build if needed, auto-install intelligently
    ./setup-yolo.sh --build=auto --install=auto

EOF
    exit 0
}

# Returns 0 if the opencode tui.json at $1 exists and disables mouse capture.
# The regex anchors on the "mouse" key boundary so it doesn't cross-match
# other keys whose value happens to be false, or substrings like "mouseover".
opencode_tui_mouse_disabled() {
    local target="$1"
    [ -f "$target" ] && grep -q '"mouse"[[:space:]]*:[[:space:]]*false' "$target" 2>/dev/null
}

# Write the canonical opencode tui.json (mouse capture disabled) to $1.
# Creates parent directories as needed. Single-line printf (rather than a
# heredoc) avoids a bare `}` line inside the function body, which the
# awk-based test function extractor (tests/yolo.bats:29) would mistake for
# the function's closing brace.
write_opencode_tui_config() {
    local target="$1"
    mkdir -p "$(dirname "$target")"
    # shellcheck disable=SC2016  # $schema is a literal JSON key, not bash interpolation
    printf '{\n  "$schema": "https://opencode.ai/tui.json",\n  "mouse": false\n}\n' > "$target"
}

# Print the opencode TUI mouse-capture status for an existing config file at
# $1. Returns 0 if mouse capture is disabled, 1 otherwise. Caller must
# verify the file exists; the orchestrator below branches on -f first.
report_opencode_tui_status() {
    local target="$1"
    if opencode_tui_mouse_disabled "$target"; then
        echo
        echo "${COLOR_GREEN}✓ opencode TUI: mouse capture already disabled${COLOR_RESET} in $target (copy/paste works)"
        return 0
    fi
    echo
    echo "${COLOR_YELLOW}${COLOR_BOLD}⚠ opencode TUI: mouse capture is ENABLED${COLOR_RESET} in $target"
    echo "  This prevents native terminal copy/paste from inside the container."
    echo "  Fix: add ${COLOR_BOLD}'\"mouse\": false'${COLOR_RESET} to $target"
    return 1
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            ;;
        --build=*)
            BUILD_MODE="${1#*=}"
            if [[ ! "$BUILD_MODE" =~ ^(auto|yes|no)$ ]]; then
                echo "Error: --build must be one of: auto, yes, no"
                exit 1
            fi
            shift
            ;;
        --install=*)
            INSTALL_MODE="${1#*=}"
            if [[ ! "$INSTALL_MODE" =~ ^(auto|yes|no)$ ]]; then
                echo "Error: --install must be one of: auto, yes, no"
                exit 1
            fi
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Run with --help for usage information"
            exit 1
            ;;
    esac
done

echo "🚀 yolo Setup (multi-harness: claude, opencode; codex planned)"
echo "================================================================"
echo

# Handle image building based on BUILD_MODE
IMAGE_EXISTS=false
if podman image exists "$IMAGE_NAME" 2>/dev/null; then
    IMAGE_EXISTS=true
fi

BASE_REBUILT=false
if [ "$BUILD_MODE" = "no" ]; then
    if [ "$IMAGE_EXISTS" = false ]; then
        echo "Error: Image '$IMAGE_NAME' does not exist and --build=no was specified"
        exit 1
    fi
    echo "✓ Skipping build (--build=no specified)"
elif [ "$BUILD_MODE" = "yes" ] || [ "$IMAGE_EXISTS" = false ]; then
    if [ "$BUILD_MODE" = "yes" ]; then
        echo "Rebuilding container image '$IMAGE_NAME'..."
    else
        echo "Building container image '$IMAGE_NAME'..."
    fi
    echo "This may take a few minutes..."
    echo

    TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "UTC")
    podman build --build-arg "TZ=$TZ" -t "$IMAGE_NAME" "$DOCKERFILE_DIR"
    BASE_REBUILT=true

    echo
    echo "✓ Container image built successfully"
else
    # BUILD_MODE=auto and image exists
    echo "✓ Container image '$IMAGE_NAME' already exists"
fi

# One-time cleanup: if the legacy tag from before the multi-harness rename
# still exists, offer to remove it. Don't auto-delete in case the user is
# mid-migration and has projects pinned to the old name.
if podman image exists "$LEGACY_IMAGE_NAME" 2>/dev/null; then
    echo
    echo "Detected legacy image tag '$LEGACY_IMAGE_NAME' (pre-rename)."
    echo "It is no longer used. Remove it?"
    if [ -t 0 ]; then
        read -p "Remove '$LEGACY_IMAGE_NAME'? [y/N] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            podman rmi "$LEGACY_IMAGE_NAME" >/dev/null && echo "✓ Removed '$LEGACY_IMAGE_NAME'"
        fi
    else
        echo "(stdin is not a TTY; skipping removal. Run interactively or 'podman rmi $LEGACY_IMAGE_NAME' to clean up.)"
    fi
fi

# After a base rebuild the base image ID changes, which invalidates every
# derived 'yolo-<hash12>' image built against the old base. Offer to prune
# them so they don't accumulate. Skip yolo-base itself. Only runs when the
# base was actually (re)built this invocation — auto/no-op runs leave the
# derived cache alone.
if [ "$BASE_REBUILT" = true ]; then
    ORPHAN_TAGS=()
    while IFS= read -r _tag; do
        [ -z "$_tag" ] && continue
        [ "$_tag" = "$IMAGE_NAME" ] && continue
        [ "$_tag" = "$IMAGE_NAME:latest" ] && continue
        ORPHAN_TAGS+=("$_tag")
    done < <(podman images --filter "reference=yolo-*" --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | sed 's/:latest$//' | sort -u)
    if [ "${#ORPHAN_TAGS[@]}" -gt 0 ]; then
        echo
        echo "Detected ${#ORPHAN_TAGS[@]} derived yolo-* image(s) built against an older base:"
        for _tag in "${ORPHAN_TAGS[@]}"; do echo "  $_tag"; done
        echo "These are now stale and will be rebuilt automatically on next use. Remove now?"
        if [ -t 0 ]; then
            read -p "Remove orphan derived images? [y/N] " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                for _tag in "${ORPHAN_TAGS[@]}"; do
                    podman rmi "$_tag" >/dev/null 2>&1 && echo "✓ Removed '$_tag'"
                done
            fi
        else
            echo "(stdin is not a TTY; skipping. Run interactively or 'podman rmi <tag>' to clean up.)"
        fi
    fi
fi

# Opencode TUI config: mouse capture prevents native terminal copy/paste.
# Offer to disable it so users can select-and-copy text from opencode output.
OPENCODE_TUI_DIR="$HOME/.config/opencode"
OPENCODE_TUI_FILE="$OPENCODE_TUI_DIR/tui.json"
if [ -t 0 ]; then
    if [ -f "$OPENCODE_TUI_FILE" ]; then
        report_opencode_tui_status "$OPENCODE_TUI_FILE" || true
    else
        echo
        echo "Would you like to configure opencode for easy copy/paste from inside the container?"
        echo "Opencode's TUI captures mouse events by default, which blocks native terminal"
        echo "selection and copy. Disabling mouse capture lets you use Ctrl+Shift+C to copy."
        echo
        read -p "Create ~/.config/opencode/tui.json with mouse capture disabled? [y/N] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            write_opencode_tui_config "$OPENCODE_TUI_FILE"
            echo "✓ Created $OPENCODE_TUI_FILE with mouse capture disabled"
        fi
    fi
fi

echo
echo "================================"
echo

# Install YOLO script to ~/.local/bin
BIN_DIR="$HOME/.local/bin"
YOLO_SCRIPT="$BIN_DIR/yolo"
SOURCE_SCRIPT="$SCRIPT_DIR/bin/yolo"

# Create directory if it doesn't exist
mkdir -p "$BIN_DIR"

# Determine if we should install based on INSTALL_MODE
SHOULD_INSTALL=false
SCRIPT_EXISTS=false

if [ -f "$YOLO_SCRIPT" ]; then
    SCRIPT_EXISTS=true
fi

if [ "$INSTALL_MODE" = "no" ]; then
    echo "Skipping yolo script installation (--install=no specified)"
elif [ "$INSTALL_MODE" = "yes" ]; then
    # Always install
    SHOULD_INSTALL=true
    if [ "$SCRIPT_EXISTS" = true ]; then
        echo "Overwriting existing yolo script (--install=yes specified)"
    else
        echo "Installing yolo script (--install=yes specified)"
    fi
elif [ "$INSTALL_MODE" = "auto" ]; then
    if [ "$SCRIPT_EXISTS" = false ]; then
        # Script doesn't exist, ask if user wants to install
        echo "Would you like to install the 'yolo' command?"
        echo
        echo "This will create a script at $YOLO_SCRIPT that lets you run:"
        echo "  $ yolo"
        echo
        echo "from any directory to start a coding harness in YOLO mode (auto-approve all actions)."
        echo
        if [ -t 0 ]; then
            read -p "Install yolo command? [y/N] " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                SHOULD_INSTALL=true
            fi
        else
            echo "(stdin is not a TTY; not installing. Re-run with --install=yes to force.)"
        fi
    else
        # Script exists, check if it differs
        if ! cmp -s "$SOURCE_SCRIPT" "$YOLO_SCRIPT"; then
            echo "✓ yolo script already exists at $YOLO_SCRIPT"
            echo "  (but differs from source)"
            echo
            if [ -t 0 ]; then
                read -p "Overwrite existing script? [y/N] " -n 1 -r
                echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    SHOULD_INSTALL=true
                fi
            else
                echo "(stdin is not a TTY; not overwriting. Re-run with --install=yes to force.)"
            fi
        else
            echo "✓ yolo script already exists and is up to date at $YOLO_SCRIPT"
        fi
    fi
fi

# Install yolo agent skill into both standard skill paths so every harness
# can discover it: claude reads ~/.claude/skills, opencode reads both,
# codex (when re-enabled) reads ~/.agents/skills. Same content, two install
# locations, so the harness profiles' read-only bind mounts make the skill
# visible regardless of which harness is launched.
SHOULD_INSTALL_SKILL=false
SKILL_SOURCE_DIR="$SCRIPT_DIR/skills/yolo"
SKILL_DEST_DIRS=(
    "$HOME/.claude/skills/yolo"
    "$HOME/.agents/skills/yolo"
)

if [ -d "$SKILL_SOURCE_DIR" ]; then
    if [ "$INSTALL_MODE" = "no" ]; then
        echo "Skipping yolo skill installation (--install=no specified)"
    elif [ "$INSTALL_MODE" = "yes" ]; then
        SHOULD_INSTALL_SKILL=true
        echo "Installing yolo skill (--install=yes specified)"
    elif [ "$INSTALL_MODE" = "auto" ]; then
        echo
        echo "Would you like to install the yolo agent skill?"
        echo
        echo "Helps agents in any of the bundled harnesses (claude, opencode; codex planned)"
        echo "work with yolo more effectively:"
        echo "  - install yolo / add .yolo/ to a project / edit .git/yolo/config"
        echo "  - diagnose failures (missing image, git push over SSH, GPU, etc.)"
        echo
        echo "It will be installed to:"
        for d in "${SKILL_DEST_DIRS[@]}"; do echo "  $d/"; done
        echo
        if [ -t 0 ]; then
            read -p "Install yolo skill? [y/N] " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                SHOULD_INSTALL_SKILL=true
            fi
        else
            echo "(stdin is not a TTY; not installing skill. Re-run with --install=yes to force.)"
        fi
    fi
fi

if [ "$SHOULD_INSTALL_SKILL" = true ]; then
    for SKILL_DEST_DIR in "${SKILL_DEST_DIRS[@]}"; do
        mkdir -p "$(dirname "$SKILL_DEST_DIR")"
        rm -rf "$SKILL_DEST_DIR"
        cp -r "$SKILL_SOURCE_DIR" "$SKILL_DEST_DIR"
        # Bundle .yolo/ recipe templates with the skill so agents can read them
        # without needing the yolo repo on disk. Canonical source: images/examples/.
        if [ -d "$SCRIPT_DIR/images/examples" ]; then
            cp -r "$SCRIPT_DIR/images/examples" "$SKILL_DEST_DIR/recipes"
        fi
        echo "✓ Installed skill: yolo -> $SKILL_DEST_DIR"
    done
    echo
fi

if [ "$SHOULD_INSTALL" = false ]; then
    echo
    echo "Setup complete! Container image '$IMAGE_NAME' is ready."
    echo "It includes: claude, opencode. (codex is planned but not yet enabled.)"
    echo
    echo "Run claude manually:"
    echo "  podman run -it --rm --userns=keep-id:uid=1000,gid=1000 \\"
    echo "    -v \"\$HOME/.claude:/home/agent/.claude:z\" \\"
    echo "    -v \"\$HOME/.gitconfig:/tmp/.gitconfig:ro,z\" \\"
    echo "    -v \"\$(pwd):\$(pwd):z\" \\"
    echo "    -w \"\$(pwd)\" \\"
    echo "    -e CLAUDE_CONFIG_DIR=/home/agent/.claude \\"
    echo "    -e GIT_CONFIG_GLOBAL=/tmp/.gitconfig \\"
    echo "    -e CLAUDE_CODE_OAUTH_TOKEN \\"
    echo "    -e CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS \\"
    echo "    -e YOLO_HARNESS=claude \\"
    echo "    $IMAGE_NAME \\"
    echo "    claude --dangerously-skip-permissions"
    echo
    echo "Run opencode manually:"
    echo "  podman run -it --rm --userns=keep-id:uid=1000,gid=1000 \\"
    echo "    -v \"\$HOME/.config/opencode:/home/agent/.config/opencode:z\" \\"
    echo "    -v \"\$HOME/.local/share/opencode:/home/agent/.local/share/opencode:z\" \\"
    echo "    -v \"\$HOME/.claude:/home/agent/.claude:ro,z\" \\"
    echo "    -v \"\$HOME/.agents/skills:/home/agent/.agents/skills:ro,z\" \\"
    echo "    -v \"\$HOME/.gitconfig:/tmp/.gitconfig:ro,z\" \\"
    echo "    -v \"\$(pwd):\$(pwd):z\" \\"
    echo "    -w \"\$(pwd)\" \\"
    echo "    -e GIT_CONFIG_GLOBAL=/tmp/.gitconfig \\"
    echo "    -e OPENAI_API_KEY \\"
    echo "    -e ANTHROPIC_API_KEY \\"
    echo "    -e OPENROUTER_API_KEY \\"
    echo "    -e GROQ_API_KEY \\"
    echo "    -e GEMINI_API_KEY \\"
    echo "    -e OPENCODE_DANGEROUSLY_SKIP_PERMISSIONS=true \\"
    echo "    -e YOLO_HARNESS=opencode \\"
    echo "    $IMAGE_NAME \\"
    echo "    opencode"
    echo
    echo "Note: --userns=keep-id:uid=1000,gid=1000 requires podman >= 4.3."
    echo "On older podman use --user=\"\$(id -u):\$(id -g)\" --userns=keep-id instead"
    echo "(file ownership only works correctly if your host UID is 1000)."
    echo
    echo "The yolo launcher does all of this for you:"
    echo "  yolo                        # claude (default)"
    echo "  yolo --harness=opencode"
    echo "  # yolo --harness=codex     # planned, not yet enabled"
    exit 0
fi

# Install yolo script
if [ "$SHOULD_INSTALL" = true ]; then
    echo
    echo "Installing yolo script to $YOLO_SCRIPT..."

    cp "$SOURCE_SCRIPT" "$YOLO_SCRIPT"
    chmod +x "$YOLO_SCRIPT"

    echo "✓ yolo script installed to $YOLO_SCRIPT"
    echo
fi

# Check if ~/.local/bin is in PATH (only if we installed)
if [ "$SHOULD_INSTALL" = true ]; then
    if [[ ":$PATH:" == *":$BIN_DIR:"* ]]; then
        echo "✓ $BIN_DIR is already in your PATH"
    else
        echo "⚠️  $BIN_DIR is not in your PATH"
        echo "   Add this line to your shell config (~/.bashrc or ~/.zshrc):"
        echo "   export PATH=\"\$HOME/.local/bin:\$PATH\""
        echo
    fi

    echo "================================"
    echo "🎉 Setup complete!"
    echo "================================"
    echo
    echo "To start using yolo:"
    echo "  1. Make sure ~/.local/bin is in your PATH (restart shell if needed)"
    echo "  2. Navigate to any project directory"
    echo "  3. Run one of:"
    echo "       yolo                       # claude (default harness)"
    echo "       yolo --harness=opencode"
    echo "       # yolo --harness=codex    # planned, not yet enabled"
    echo
    echo "Pass extra podman options before -- and harness arguments after:"
    echo "  yolo -v /host:/container --env FOO=bar -- \"help with this code\""
    echo "  yolo -v /data:/data --                # extra mounts only"
    echo "  yolo -- \"process files\"               # harness args only"
    echo
    echo "For NVIDIA GPU access (requires nvidia-container-toolkit on host):"
    echo "  yolo --nvidia"
    echo
    echo "Run 'yolo --help' for all available options."
    echo
    echo "PROJECT CONFIGURATION:"
    echo "  Config is auto-created on first run, or use:"
    echo "    yolo --install-config"
    echo "  Then edit with:"
    echo "    vi .git/yolo/config"
    echo "  Set HARNESS= to pin a per-project default harness."
    echo
    echo "The container starts the chosen harness in YOLO mode with full"
    echo "permissions in the current directory; credentials and git access"
    echo "are configured via bind mounts."
    echo
fi
