#!/bin/bash
# Update Claude Code to latest version before starting
claude update </dev/null >/dev/null 2>&1 || true
exec "$@"
