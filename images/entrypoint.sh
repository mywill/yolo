#!/bin/bash
# Per-harness self-update on container start. Each branch has a 120s timeout
# and an INT trap so Ctrl-C aborts the update cleanly and continues to the
# main command. Update failures are swallowed (|| true) — a failed update
# should never block running the harness. tini (PID 1, set in the
# Dockerfile ENTRYPOINT) reaps any zombies left behind.
#
# For opencode (and codex when re-enabled), the runtime update is skipped
# when the build pin ($OPENCODE_VERSION / $CODEX_VERSION, baked in via
# Dockerfile ENV) is anything other than "latest" — that way
# `--build-arg *_VERSION=x.y.z` isn't silently overwritten by a `@latest`
# reinstall on every start.
#
# stdout is suppressed for the noisy installers; stderr is preserved so
# real failures (e.g., no network) still surface.
#
# $YOLO_HARNESS is set by bin/yolo via `-e YOLO_HARNESS=$HARNESS`. If unset
# (someone ran the image directly without yolo), all branches are skipped.

set -e

trap 'echo "Update skipped." >&2' INT

case "${YOLO_HARNESS:-}" in
    claude)
        timeout --foreground 120 claude update </dev/null || true
        ;;
    # codex)
    #     # Deferred — re-enable alongside the codex install in images/Dockerfile.
    #     # Note: when restored, use `--prefix /home/agent/.npm-global` rather
    #     # than relying on npm config so ~/.npmrc stays empty (see nvm note in
    #     # the Dockerfile).
    #     if [ "${CODEX_VERSION:-latest}" = "latest" ]; then
    #         timeout --foreground 120 npm install -g --prefix /home/agent/.npm-global "@openai/codex@latest" </dev/null >/dev/null || true
    #     fi
    #     ;;
    opencode)
        if [ "${OPENCODE_VERSION:-latest}" = "latest" ]; then
            timeout --foreground 120 bash -c 'curl -fsSL https://opencode.ai/install | bash' </dev/null >/dev/null || true
        fi
        ;;
    pi)
        if [ "${PI_VERSION:-latest}" = "latest" ]; then
            timeout --foreground 120 npm install -g --prefix /home/agent/.npm-global --ignore-scripts "@earendil-works/pi-coding-agent@latest" </dev/null >/dev/null || true
        fi
        ;;
esac

trap - INT
exec "$@"
