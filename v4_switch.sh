#!/usr/bin/env bash
set -euo pipefail

echo "This script has been merged into fw_update.sh."
echo ""
echo "Run:"
echo "  ./fw_update.sh --switch-v4-can"
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/fw_update.sh" --switch-v4-can
