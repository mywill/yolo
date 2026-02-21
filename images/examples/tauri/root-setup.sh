#!/bin/bash
set -e

apt-get update && apt-get install -y --no-install-recommends \
  build-essential \
  libssl-dev \
  pkg-config \
  libwebkit2gtk-4.1-dev \
  libgtk-3-dev \
  libayatana-appindicator3-dev \
  librsvg2-dev \
  && apt-get clean && rm -rf /var/lib/apt/lists/*
