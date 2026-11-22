#!/bin/sh
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo=$(CDPATH= cd -- "$here/../.." && pwd)

fail()
{
   printf '%s\n' "$*" >&2
   exit 1
}

absolute_path()
{
   case $1 in
      /*) printf '%s' "$1" ;;
      *)  printf '%s/%s' "$PWD" "$1" ;;
   esac
}

config_path()
{
   case $2 in
      *'"'*|*'
'*) fail "Unsupported character in path for $1." ;;
   esac
   printf '%s = "%s"\n' "$1" "$2"
}

case $(uname -s) in
   Darwin)
      platform=mac
      support="$HOME/Library/Application Support/RetroArch"
      executable=$(absolute_path "${RETROARCH_BIN:-$repo/RetroArch.app}")
      [ -x "$executable/Contents/MacOS/RetroArch" ] ||
         fail "Build RetroArch.app with 'make bundle' or set RETROARCH_BIN to your RetroArch app."
      driver=metal
      feature_executable="$executable/Contents/MacOS/RetroArch"
      core_extension=dylib
      ;;
   Linux)
      platform=linux
      support="${XDG_CONFIG_HOME:-$HOME/.config}/retroarch"
      executable=$(absolute_path "${RETROARCH_BIN:-$repo/retroarch}")
      [ -x "$executable" ] ||
         fail "Build ./retroarch with 'make' or set RETROARCH_BIN to your Linux build."
      driver=gl
      feature_executable="$executable"
      core_extension=so
      ;;
   *) fail "This launcher supports macOS and Linux." ;;
esac

data=$(absolute_path "${RETROARCH_PARALLAX_DATA:-$here/local}")
rom=$(absolute_path "${RETROARCH_ROM:-$data/astdelux.zip}")
core=$(absolute_path "${RETROARCH_CORE:-$support/cores/mame2003_plus_libretro.$core_extension}")
camera=${RETROARCH_CAMERA_ALLOW:-true}
camera_device=${RETROARCH_CAMERA_DEVICE:-}
tracker=${RETROARCH_PARALLAX_TRACKER:-native}
features=
case $camera in
   true|false) ;;
   *) fail "RETROARCH_CAMERA_ALLOW must be true or false." ;;
esac
case $tracker in
   native|mediapipe) ;;
   *) fail "RETROARCH_PARALLAX_TRACKER must be native or mediapipe." ;;
esac

[ -f "$rom" ] || fail "Asteroids Deluxe ROM missing at $rom. Set RETROARCH_ROM or put your ROM here."
[ -f "$core" ] || fail "MAME 2003-Plus core missing at $core. Set RETROARCH_CORE to its path."
if [ "$camera" = true ] && [ "$tracker" = mediapipe ]; then
   features=$("$feature_executable" --features) ||
      fail "Could not check the features of $feature_executable."
   if ! printf '%s\n' "$features" | grep -q 'Camera Landmarks .*: yes$'; then
      fail "This build cannot start the MediaPipe tracker. Rebuild RetroArch from this checkout."
   fi
   RETROARCH_PARALLAX_LANDMARK_PYTHON=$(absolute_path "${RETROARCH_PARALLAX_LANDMARK_PYTHON:-$data/landmarks-venv/bin/python}")
   RETROARCH_PARALLAX_LANDMARK_MODEL=$(absolute_path "${RETROARCH_PARALLAX_LANDMARK_MODEL:-$data/face_landmarker.task}")
   RETROARCH_PARALLAX_LANDMARK_LOG="$data/landmarks.log"
   RETROARCH_PARALLAX_LANDMARK_HELPER="$here/landmarks.sh"
   [ -x "$RETROARCH_PARALLAX_LANDMARK_PYTHON" ] ||
      fail "Missing MediaPipe Python environment. See docs/overlay-parallax.md."
   [ -r "$RETROARCH_PARALLAX_LANDMARK_MODEL" ] ||
      fail "Missing MediaPipe model at $RETROARCH_PARALLAX_LANDMARK_MODEL."
   export RETROARCH_PARALLAX_LANDMARK_PYTHON RETROARCH_PARALLAX_LANDMARK_MODEL
   export RETROARCH_PARALLAX_LANDMARK_LOG RETROARCH_PARALLAX_LANDMARK_HELPER
fi
if [ "$platform" = linux ] && [ "$camera" = true ]; then
   features=${features:-$("$feature_executable" --features)} ||
      fail "Could not check the features of $executable."
   if ! printf '%s\n' "$features" | grep -q 'Camera Parallax .*: yes$'; then
      fail "Camera tracking is missing from this build. Reconfigure with --enable-camera_parallax_gstreamer and rebuild. See docs/overlay-parallax.md."
   fi
   if [ "$tracker" = native ] && command -v gst-inspect-1.0 >/dev/null 2>&1; then
      for element in v4l2src decodebin videorate videoscale videoconvert facedetect; do
         gst-inspect-1.0 "$element" >/dev/null 2>&1 ||
            fail "Missing GStreamer element: $element. See the Linux runtime packages in docs/overlay-parallax.md."
      done
   fi
   if [ -n "$camera_device" ] &&
         { [ ! -c "$camera_device" ] || [ ! -r "$camera_device" ] || [ ! -w "$camera_device" ]; }; then
      fail "Cannot open camera device $camera_device. Choose an accessible /dev/video* or /dev/v4l/by-id/ device."
   fi
fi
if [ "$platform" = linux ] && [ -z "${RETROARCH_CAMERA_EYE_PROFILE:-}" ] &&
      [ -f "$data/haarcascade_mcs_eyepair_small.xml" ]; then
   export RETROARCH_CAMERA_EYE_PROFILE="$data/haarcascade_mcs_eyepair_small.xml"
fi

mkdir -p "$data/saves" "$data/states" "$data/system"
session=$(mktemp -d "$data/session.XXXXXX")
trap 'rm -rf "$session"' EXIT
trap 'exit 1' HUP INT TERM
overlay=$(absolute_path "${RETROARCH_OVERLAY:-$here/astdelux.cfg}")
[ -f "$overlay" ] || fail "Overlay missing at $overlay."
if [ "$overlay" = "$here/astdelux.cfg" ]; then
   sed -n 's/^overlay[0-9]*\(_desc[0-9]*\)\{0,1\}_overlay = "\([^"]*\)"$/\2/p' "$overlay" |
   while IFS= read -r image; do
      [ -r "$here/$image" ] || fail "Overlay image missing or unreadable at $here/$image."
   done
fi
cp "$here/mame2003-plus.opt" "$session/astdelux.opt"
{
   cat "$here/parallax.cfg"
   printf 'video_driver = "%s"\ncamera_allow = "%s"\n' "$driver" "$camera"
   config_path camera_device "$camera_device"
   config_path input_overlay "$overlay"
   config_path core_options_path "$session/astdelux.opt"
   config_path savefile_directory "$data/saves"
   config_path savestate_directory "$data/states"
   config_path system_directory "$data/system"
   config_path joypad_autoconfig_dir "$support/autoconfig"
} > "$session/retroarch.cfg"

shader=${RETROARCH_SHADER:-}
if [ -n "$shader" ]; then
   shader=$(absolute_path "$shader")
   [ -f "$shader" ] || fail "Shader missing at $shader."
elif [ "$platform" = linux ]; then
   shader="$here/vector.glsl"
else
   stock="$support/shaders/shaders_slang/crt/crt-effects/vector-glow.slangp"
   if [ -f "$stock" ]; then
      case $stock in
         *'"'*|*'
'*) fail "Unsupported character in shader preset path." ;;
      esac
      shader="$session/asteroids-vector.slangp"
      printf '#reference "%s"\nia_R = "0.15"\nia_G = "0.95"\nia_B = "1.00"\n' "$stock" > "$shader"
   fi
fi

if [ -n "$shader" ]; then
   set -- "--set-shader=$shader" "$@"
fi
set -- -v "--log-file=$data/retroarch.log" -c "$session/retroarch.cfg" -L "$core" "$@" "$rom"
if [ "$platform" = mac ]; then
   set -- "$executable" --args "$@"
   if [ "$camera" = true ] && [ "$tracker" = mediapipe ]; then
      set -- --env "RETROARCH_PARALLAX_LANDMARK_PYTHON=$RETROARCH_PARALLAX_LANDMARK_PYTHON" \
         --env "RETROARCH_PARALLAX_LANDMARK_MODEL=$RETROARCH_PARALLAX_LANDMARK_MODEL" \
         --env "RETROARCH_PARALLAX_LANDMARK_LOG=$RETROARCH_PARALLAX_LANDMARK_LOG" \
         --env "RETROARCH_PARALLAX_LANDMARK_HELPER=$RETROARCH_PARALLAX_LANDMARK_HELPER" "$@"
   fi
   open -n -W "$@"
else
   "$executable" "$@"
fi
