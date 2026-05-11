#!/bin/bash
# Update Claude Code to latest version before starting.
# Capped at 120s; press Ctrl-C to skip immediately.
trap 'echo; echo "Update skipped."' INT
echo "Updating Claude Code... (Ctrl-C to skip)" >&2
timeout --foreground 120 claude update </dev/null >&2 || true
trap - INT
exec "$@"
