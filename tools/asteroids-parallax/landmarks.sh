#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$RETROARCH_PARALLAX_LANDMARK_PYTHON" "$here/landmarks.py" "$1" 2>"$RETROARCH_PARALLAX_LANDMARK_LOG"
