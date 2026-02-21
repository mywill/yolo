#!/bin/bash
set -e

apt-get update && apt-get install -y --no-install-recommends \
  build-essential \
  libssl-dev \
  pkg-config \
  && apt-get clean && rm -rf /var/lib/apt/lists/*
