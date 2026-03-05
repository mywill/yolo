#!/bin/bash
# Update Claude Code to latest version before starting
claude update 2>/dev/null || true
exec "$@"
