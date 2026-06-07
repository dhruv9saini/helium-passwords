#!/usr/bin/env bash
set -euo pipefail

gh workflow run chromium-android.yml "$@"
