#!/usr/bin/env bash
# Standard-library Python checks of the other workflows' fixture contracts.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "$ROOT/tests/workflow-fixture-wiring.py"
