#!/usr/bin/env bash
set -euo pipefail

gh workflow run chromium-linux.yml "$@"
