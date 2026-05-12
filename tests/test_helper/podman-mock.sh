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
#   MOCK_PODMAN_VERSION           stdout returned by `podman version --format ...`.
#   MOCK_PODMAN_BUILT_TAGS        if set, each `-t TAG` value passed to
#                                 `podman build` is appended to this file
#                                 (one tag per line).

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
                echo "${MOCK_PODMAN_IMAGE_ID:-sha256:deadbeef}"
                exit 0
                ;;
        esac
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
