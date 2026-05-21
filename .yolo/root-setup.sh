#!/bin/bash
# Project-specific image additions for the yolo repo itself.
#
# Installs bats so the test suite (tests/yolo.bats) can run inside the
# container. shellcheck is already in the base image. podman isn't needed
# inside the container — tests/test_helper/podman-mock.sh stands in.
#
# Re-runs automatically when this file's contents change (the derived
# image hash includes it).
set -e

apt-get update && apt-get install -y --no-install-recommends \
  bats \
  && apt-get clean && rm -rf /var/lib/apt/lists/*
