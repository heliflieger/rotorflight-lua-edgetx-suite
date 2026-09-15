#!/usr/bin/env bash
# Local dev entrypoint for building a single-locale Radio Install ZIP.
# Usage: ./package.sh [lang] [artifact-version] [extra build_package.py args...]
#   lang              defaults to "en"
#   artifact-version  defaults to "local-test"
# Example: ./package.sh de 0.1.0-20260816

set -euo pipefail
cd "$(dirname "$0")"

case "${1:-}" in
  -h|--help)
    echo "Usage: ./package.sh [lang] [artifact-version] [extra build_package.py args...]"
    echo "  lang              defaults to \"en\""
    echo "  artifact-version  defaults to \"local-test\""
    exit 0
    ;;
esac

LANG_ARG="${1:-en}"
VER_ARG="${2:-local-test}"
if [ "$#" -ge 2 ]; then
  shift 2
elif [ "$#" -ge 1 ]; then
  shift 1
fi

export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8

if command -v python3 >/dev/null 2>&1; then
  PYEXE=python3
else
  PYEXE=python
fi

"$PYEXE" build_package.py --lang "$LANG_ARG" --artifact-version "$VER_ARG" --output-dir "$(pwd)" "$@"
