#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
pkill -x MacNotch 2>/dev/null || true
./scripts/bundle.sh
open build/MacNotch.app
