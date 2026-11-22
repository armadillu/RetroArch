# Camera parallax for overlays

An overlay preset can move its base artwork with the viewer's face. The
game viewport and individual overlay controls keep their positions.
RetroArch processes the camera image locally. If tracking loses the face,
the artwork eases back to its original position.

Enable **Settings → Privacy → Allow Camera** and load an overlay preset
with parallax enabled. The camera runs during gameplay while the
parallax page is active. A core or preview using the camera takes priority.

## Build and launch the Asteroids Deluxe example

Run the build commands from the repository root.

On macOS, install Xcode and its [Metal Toolchain](https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components).
Build the application bundle so macOS can identify it when requesting
camera permission.

```sh
./configure --enable-metal --enable-slang --disable-qt
make -j4 bundle
```

On Linux, install the compiler, pkg-config, OpenGL/GLX and X11 development
headers, and the GStreamer development package. On Debian and Ubuntu, the
GStreamer development package is `libgstreamer1.0-dev`. See
[Camera selection](#camera-selection) for the runtime packages.

```sh
./configure --enable-camera_parallax_gstreamer --enable-opengl \
  --enable-opengl_core --enable-slang --enable-glsl --disable-qt --disable-wayland
make -j4
```

Put these local inputs in place before launching:

- Put your MAME 2003-Plus compatible `astdelux.zip` ROM in
  `tools/asteroids-parallax/local/`.
- The launcher loads the layered preset and five artwork images from
  `tools/asteroids-parallax/`. On Linux, if your distribution omits the
  OpenCV eye-pair cascade, place
  `haarcascade_mcs_eyepair_small.xml` in `tools/asteroids-parallax/local/`
  or set the path as described under [Camera selection](#camera-selection).
- Install the MAME 2003-Plus core. The launcher looks in
  `~/Library/Application Support/RetroArch/cores/` on macOS or
  `${XDG_CONFIG_HOME:-$HOME/.config}/retroarch/cores/` on Linux. Set
  `RETROARCH_CORE` to use a core from a different directory.

On macOS, double-click
`tools/asteroids-parallax/Play Asteroids Deluxe.command`. On Linux, run:

```sh
./tools/asteroids-parallax/launch.sh
```

The macOS launcher uses RetroArch's installed Slang vector-glow preset
when available. The Linux launcher uses `glcore` with Slang support.
Linux uses RetroArch's normal preset selection from the shared
configuration. You can select a shader from **Quick Menu → Shaders**
or set `RETROARCH_SHADER` to a preset path:

```sh
RETROARCH_SHADER="/path/to/my-shader.slangp" ./tools/asteroids-parallax/launch.sh
```

The core's own artwork is disabled so the moving RetroArch backdrop
composites with the vectors.

The launcher reads your usual RetroArch config on every launch, including
its bindings and remap paths. On Linux it looks for
`${XDG_CONFIG_HOME:-$HOME/.config}/retroarch/retroarch.cfg`, then
`~/.retroarch.cfg`. On macOS it looks under
`~/Library/Application Support/RetroArch/config/`, then its parent folder.
Set `RETROARCH_CONFIG` to use a different file:

```sh
RETROARCH_CONFIG="/path/to/retroarch.cfg" ./tools/asteroids-parallax/launch.sh
```

The launcher applies the parallax settings in a temporary session config.
Saving the current configuration in that session targets the temporary
file. Edit bindings in your regular RetroArch install to share them with
future parallax sessions.

Use `RETROARCH_PARALLAX_DATA` for a different local data directory,
`RETROARCH_ROM` for a different ROM path, `RETROARCH_OVERLAY` for a
different overlay preset, or `RETROARCH_BIN` for a different app or
executable. The data directory receives the saves, states, and
`retroarch.log`. Set `RETROARCH_CAMERA_ALLOW=false` for a camera-off
test. Extra launcher arguments go to RetroArch.

### MediaPipe landmark tracking

To use the neural landmark tracker, build RetroArch as above and set up
the optional helper with Python 3.11 or 3.12. The pinned MediaPipe release has
wheels for x86-64 Linux and Intel and Apple Silicon Macs.

```sh
data=tools/asteroids-parallax/local
mkdir -p "$data"
python3 -m venv "$data/landmarks-venv"
"$data/landmarks-venv/bin/python" -m pip install --only-binary=:all: \
  -r tools/asteroids-parallax/requirements-landmarks.txt
curl -fL https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task \
  -o "$data/face_landmarker.task"
RETROARCH_PARALLAX_TRACKER=mediapipe ./tools/asteroids-parallax/launch.sh
```

MediaPipe tracks the face in the camera stream and sends head position
and an estimate of eye spacing to RetroArch. The helper runs locally
during gameplay. Helper errors appear in `landmarks.log` in the data
directory. On Linux, errors also appear in the terminal, and the
launcher prints the end of `retroarch.log` if RetroArch exits with an error.
On macOS, grant camera access if prompted. To select a camera,
set `RETROARCH_CAMERA_DEVICE` to a capture node such as `/dev/video2`
on Linux or a camera index such as `1` on macOS. The default tracker
selection is `native`.

### Check camera startup on Linux

The artwork should be visible before tracking starts. The camera opens
during gameplay while the game window is active. Check the build and
the camera messages from the repository root:

```sh
./retroarch --features | grep 'Camera Parallax'
grep -Ei 'camera parallax|overlay|video driver' tools/asteroids-parallax/local/retroarch.log
```

If RetroArch chooses a different device, specify the camera's capture
node. Use `v4l2-ctl --list-devices` (provided by `v4l-utils` on Debian
and Ubuntu) to find it:

```sh
RETROARCH_CAMERA_DEVICE=/dev/video2 ./tools/asteroids-parallax/launch.sh
```

Install `gstreamer1.0-tools` on Debian or Ubuntu to let the launcher
check for the GStreamer elements before starting the game.

## Preset example

```ini
overlays = 1
overlay0_overlay = "art.png"
overlay0_backdrop = true
overlay0_full_screen = true
overlay0_descs = 0
overlay0_rect = "-0.125,-0.125,1.25,1.25"
overlay0_parallax_x = 0.045
overlay0_parallax_y = 0.03
overlay0_parallax_depth = 0.75
```

Each `overlayN_parallax_x` and `overlayN_parallax_y` sets the maximum
shift along that axis at the starting distance as a fraction of the
overlay's drawing area.
Positive values follow the viewer, negative values reverse the direction,
and zero disables that axis. Values range from -1 to 1 and default to zero.
The oversized rectangle gives the image room to move without exposing
its edges.

With `overlayN_parallax_depth` above zero, the artwork is projected as a
plane behind the screen. The value expresses its depth as a fraction of
the starting viewing distance and ranges from 0 to 1. Sit at your usual
distance when tracking starts. RetroArch uses the first few detections
to calibrate depth at that distance. When both eyes are detected, their
apparent separation estimates relative distance. Depth eases toward the
face-rectangle estimate when the eyes are obscured. Lean closer to see
more of the art through the fixed screen area. A value of zero keeps
the artwork at a constant scale.

Decorative descriptor images can sit in front of the rear artwork at
their own depths. Set `overlayN_descM_parallax_depth` to a value up to the
base artwork's depth on a stationary `nul` descriptor with an image.
An omitted depth keeps the descriptor anchored to the screen.

For a vector game's backdrop, set `overlayN_backdrop = true`. RetroArch
adds the game's shaded light to the art. The game shows the artwork
through its black field, and bright vectors retain their intensity. The
game's shader passes see the game image alone. This composition is
available with the OpenGL, Metal, Vulkan and SDL3 video drivers in SDR.
Overlay Opacity sets the artwork brightness.
Use `overlayN_backdrop_images` to apply the same composition to the first
few images in the page, including the base artwork. It defaults to one.
With Metal, `gl`, or a Slang-enabled `glcore` build in SDR, set
`overlayN_solid_backdrop = true` to composite those images in order
before adding the game's shaded light. An opaque pixel then covers the
earlier artwork at that position. Overlay Opacity still controls the
brightness of the combined artwork.

## Camera selection

- On macOS 10.13 and later, RetroArch uses AVFoundation and Vision. It
  prefers a USB camera when one is available. Set `camera_device` to
  the camera's name or unique ID to select a specific device. Grant camera
  access when macOS prompts.
- On Linux, build with GStreamer development headers installed. The build
  detects them automatically and can require them with
  `./configure --enable-camera_parallax_gstreamer`. At runtime, install
  the GStreamer V4L2 and OpenCV plugins and OpenCV cascade data. On
  Debian and Ubuntu these are provided by `gstreamer1.0-plugins-good`,
  `gstreamer1.0-opencv`, and `opencv-data`. RetroArch prefers a USB camera
  listed under `/dev/v4l/by-id` and falls back to `/dev/video0`. Set
  `camera_device` to a specific V4L2 path to override that choice.
  Eye-based depth uses GStreamer's eye-pair cascade. If your distribution
  omits it from the OpenCV data package, point
  `RETROARCH_CAMERA_EYE_PROFILE` to a local
  [OpenCV eye-pair cascade XML](https://github.com/opencv/opencv_attic/blob/master/opencv/data/haarcascades/haarcascade_mcs_eyepair_small.xml)
  before launching. Face-rectangle depth is available without the eye-pair
  cascade.

Both builds require overlay and thread support.
