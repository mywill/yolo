#!/usr/bin/env bash
# Response-aware podman mock used by tests/yolo.bats.
#
# Every invocation is appended as a single tab-separated line to
# $MOCK_PODMAN_LOG. Behavior is controlled by these env vars:
#
#   MOCK_PODMAN_EXISTING_IMAGES   space-separated list of image refs
#                                 that `podman image exists` should report as
#                                 present (exit 0). Anything else exits 1.
#   MOCK_PODMAN_IMAGE_ID          stdout returned by
#                                 `podman image inspect ... --format '{{.Id}}'`.
#   MOCK_PODMAN_IMAGE_CREATED     stdout returned by
#                                 `podman image inspect <tag> --format '{{.Created}}'`.
#   MOCK_PODMAN_VERSION           stdout returned by `podman version --format ...`.
#   MOCK_PODMAN_BUILT_TAGS        if set, each `-t TAG` value passed to
#                                 `podman build` is appended to this file
#                                 (one tag per line).
#   MOCK_PODMAN_IMAGES            newline-separated list of `repository:tag` entries
#                                 returned by `podman images --filter reference=...`
#                                 and `podman images --filter dangling=true -q`.
#   MOCK_PODMAN_PS_CONTAINERS     newline-separated list of container IDs
#                                 returned by `podman ps -a --filter ... -q`.

set -u

if [ -n "${MOCK_PODMAN_LOG:-}" ]; then
    {
        sep=""
        for arg in "$@"; do
            printf '%s%s' "$sep" "$arg"
            sep=$'\t'
        done
        printf '\n'
    } >>"$MOCK_PODMAN_LOG"
fi

case "${1:-}" in
    image)
        case "${2:-}" in
            exists)
                img="${3:-}"
                for existing in ${MOCK_PODMAN_EXISTING_IMAGES:-}; do
                    [ "$existing" = "$img" ] && exit 0
                done
                exit 1
                ;;
            inspect)
                # --format '{{.Id}}' or '{{.Created}}'
                fmt=""
                idx=3
                while [ $idx -le $# ]; do
                    if [ "${!idx}" = "--format" ]; then
                        n=$((idx + 1))
                        fmt="${!n}"
                        break
                    fi
                    idx=$((idx + 1))
                done
                case "$fmt" in
                    *{{.Created}}*)
                        echo "${MOCK_PODMAN_IMAGE_CREATED:-2025-06-01T00:00:00Z}"
                        ;;
                    *)
                        echo "${MOCK_PODMAN_IMAGE_ID:-sha256:deadbeef}"
                        ;;
                esac
                exit 0
                ;;
        esac
        ;;
    images)
        # Respond with the mock image list when filters are used
        if [ -n "${MOCK_PODMAN_IMAGES:-}" ]; then
            echo "$MOCK_PODMAN_IMAGES"
        fi
        exit 0
        ;;
    ps)
        if [ -n "${MOCK_PODMAN_PS_CONTAINERS:-}" ]; then
            echo "$MOCK_PODMAN_PS_CONTAINERS"
        fi
        exit 0
        ;;
    rm|rmi)
        exit 0
        ;;
    version)
        echo "${MOCK_PODMAN_VERSION:-4.9.4}"
        exit 0
        ;;
    build)
        shift
        tag=""
        while [ $# -gt 0 ]; do
            case "$1" in
                -t)
                    tag="${2:-}"
                    shift
                    [ $# -gt 0 ] && shift
                    ;;
                -t=*)
                    tag="${1#-t=}"
                    shift
                    ;;
                *)
                    shift
                    ;;
            esac
        done
        if [ -n "$tag" ] && [ -n "${MOCK_PODMAN_BUILT_TAGS:-}" ]; then
            echo "$tag" >>"$MOCK_PODMAN_BUILT_TAGS"
        fi
        exit 0
        ;;
    run)
        exit 0
        ;;
esac

exit 0