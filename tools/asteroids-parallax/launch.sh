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
      core_extension=dylib
      ;;
   Linux)
      platform=linux
      support="${XDG_CONFIG_HOME:-$HOME/.config}/retroarch"
      executable=$(absolute_path "${RETROARCH_BIN:-$repo/retroarch}")
      [ -x "$executable" ] ||
         fail "Build ./retroarch with 'make' or set RETROARCH_BIN to your Linux build."
      driver=gl
      core_extension=so
      ;;
   *) fail "This launcher supports macOS and Linux." ;;
esac

data=$(absolute_path "${RETROARCH_PARALLAX_DATA:-$here/local}")
rom=$(absolute_path "${RETROARCH_ROM:-$data/astdelux.zip}")
core=$(absolute_path "${RETROARCH_CORE:-$support/cores/mame2003_plus_libretro.$core_extension}")
camera=${RETROARCH_CAMERA_ALLOW:-true}
case $camera in
   true|false) ;;
   *) fail "RETROARCH_CAMERA_ALLOW must be true or false." ;;
esac

[ -f "$rom" ] || fail "Asteroids Deluxe ROM missing at $rom. Set RETROARCH_ROM or put your ROM here."
[ -f "$core" ] || fail "MAME 2003-Plus core missing at $core. Set RETROARCH_CORE to its path."
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
cp "$here/mame2003-plus.opt" "$session/astdelux.opt"
{
   cat "$here/parallax.cfg"
   printf 'video_driver = "%s"\ncamera_allow = "%s"\n' "$driver" "$camera"
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
   open -n -W "$executable" --args "$@"
else
   "$executable" "$@"
fi
