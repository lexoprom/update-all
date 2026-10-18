#!/usr/bin/env bash
set -euo pipefail
# Tests expect the default manager list regardless of the caller's setup.
unset UPDATE_ALL_GLOBAL_MANAGERS
cd "$(dirname "$0")/.."
python3 tests/doctor.test.py
python3 tests/doctor-cli.test.py
