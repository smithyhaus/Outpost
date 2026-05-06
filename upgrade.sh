#!/usr/bin/env bash
# Pull latest images and restart, preserving data
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/core/compose"
docker compose pull
docker compose up -d
docker compose ps
