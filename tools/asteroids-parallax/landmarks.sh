#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ "$(uname -s)" = Linux ]; then
   : >"$RETROARCH_PARALLAX_LANDMARK_LOG"
else
   exec 2>"$RETROARCH_PARALLAX_LANDMARK_LOG"
fi
exec "$RETROARCH_PARALLAX_LANDMARK_PYTHON" "$here/landmarks.py" "$1"
