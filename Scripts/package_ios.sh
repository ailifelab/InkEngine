#!/bin/zsh
# One Release IPA; temporary archives and app copies are removed after export.
set -euo pipefail
exec python3 "${0:A:h}/ipa.py" build "$@"
