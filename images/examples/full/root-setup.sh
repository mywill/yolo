#!/bin/bash
# Replicates the full monolithic image with all system dependencies
set -e

apt-get update && apt-get install -y --no-install-recommends \
  build-essential \
  libssl-dev \
  pkg-config \
  libwebkit2gtk-4.1-dev \
  libgtk-3-dev \
  libayatana-appindicator3-dev \
  librsvg2-dev \
  gstreamer1.0-plugins-bad \
  libx264-dev \
  libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 \
  libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libgbm1 libasound2 \
  && apt-get clean && rm -rf /var/lib/apt/lists/*
