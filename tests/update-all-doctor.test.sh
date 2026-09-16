#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 tests/doctor.test.py
python3 tests/doctor-cli.test.py
