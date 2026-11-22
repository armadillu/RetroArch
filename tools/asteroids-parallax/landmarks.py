"""Send MediaPipe head measurements to RetroArch over the helper pipe."""

import glob
import math
import os
import struct
import sys
import time

import cv2
import mediapipe as mp


def eye_center(landmarks, outer, inner):
    a, b = landmarks[outer], landmarks[inner]
    return ((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2)


def head_measurement(landmarks, aspect):
    left, right = landmarks[234], landmarks[454]
    forehead, chin = landmarks[10], landmarks[152]
    x = (left.x + right.x) / 2
    y = (forehead.y + chin.y) / 2
    width = math.hypot(right.x - left.x, (right.y - left.y) * aspect)
    height = math.hypot((chin.x - forehead.x) / aspect, chin.y - forehead.y)
    a = eye_center(landmarks, 33, 133)
    b = eye_center(landmarks, 263, 362)
    # MediaPipe expresses landmark z in the same scale as normalized x.
    span = math.hypot(b[0] - a[0], (b[1] - a[1]) * aspect, b[2] - a[2])
    return tuple(max(0.0, min(1.0, value)) for value in (x, y, width * height, span))


def open_camera(device):
    if sys.platform == "linux":
        if not device:
            usb = sorted(glob.glob("/dev/v4l/by-id/usb-*-video-index0"))
            device = usb[0] if usb else "/dev/video0"
        stream = cv2.VideoCapture(device, cv2.CAP_V4L2)
        stream.set(cv2.CAP_PROP_BUFFERSIZE, 1)
    else:
        device = int(device) if device else 0
        stream = cv2.VideoCapture(device, cv2.CAP_AVFOUNDATION)
    if not stream.isOpened():
        raise RuntimeError(f"Could not open camera {device}")
    stream.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
    stream.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
    stream.set(cv2.CAP_PROP_FPS, 30)
    return stream


def track(device, model):
    options = mp.tasks.vision.FaceLandmarkerOptions(
        base_options=mp.tasks.BaseOptions(model_asset_path=model),
        running_mode=mp.tasks.vision.RunningMode.VIDEO,
        num_faces=1,
    )
    with mp.tasks.vision.FaceLandmarker.create_from_options(options) as landmarker:
        stream = open_camera(device)
        try:
            timestamp = 0
            while True:
                ok, frame = stream.read()
                if not ok:
                    raise RuntimeError("Camera stopped delivering frames")
                height, width = frame.shape[:2]
                timestamp = max(timestamp + 1, time.monotonic_ns() // 1_000_000)
                rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
                result = landmarker.detect_for_video(
                    mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb), timestamp
                )
                pose = (0.0, 0.0, 0.0, 0.0)
                if result.face_landmarks:
                    pose = head_measurement(result.face_landmarks[0], height / width)
                os.write(sys.stdout.fileno(), struct.pack("=ffff", *pose))
        finally:
            stream.release()


if __name__ == "__main__":
    try:
        track(sys.argv[1], os.environ["RETROARCH_PARALLAX_LANDMARK_MODEL"])
    except BrokenPipeError:
        pass
    except (OSError, RuntimeError, ValueError) as error:
        sys.exit(str(error))
