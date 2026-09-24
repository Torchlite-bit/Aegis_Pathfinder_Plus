#!/bin/sh
# Every check that can run without a WoW client.
#
#   sh Tools/run_tests.sh
#
# Run from the repository root. Exits non-zero if anything fails.
set -e

cd "$(dirname "$0")/.."

echo "== static verification =="
python3 Tools/verify.py

echo
echo "== profession source document =="
python3 Tools/convert_professions.py --check

echo
echo "== lua tests =="

lua5.1 Tools/test_professions.lua


echo
echo "All offline checks passed."
echo "Not covered here: anything that needs a running 1.12 client -- whether the"
echo "UI actually looks like the concept, whether textures load, whether the"
echo "bundled fonts render. Those need an in-game pass."
