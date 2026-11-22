#ifndef CAMERA_PARALLAX_H
#define CAMERA_PARALLAX_H

#ifdef HAVE_CONFIG_H
#include "../config.h"
#endif

#if defined(HAVE_THREADS) && defined(HAVE_OVERLAY)
#if defined(__APPLE__) && defined(HAVE_AVF) && defined(__has_include)
#include <TargetConditionals.h>
#if TARGET_OS_OSX && __has_include(<Vision/Vision.h>)
#define HAVE_CAMERA_PARALLAX
#endif
#elif defined(HAVE_CAMERA_PARALLAX_GSTREAMER)
#define HAVE_CAMERA_PARALLAX
#endif
#endif

#ifdef HAVE_CAMERA_PARALLAX
#include <libretro.h>
#include <retro_atomic.h>
#include <retro_miscellaneous.h>

RETRO_BEGIN_DECLS

typedef struct camera_parallax_capture
{
   retro_atomic_int_t requested;
   retro_atomic_int_t running;
   retro_atomic_int_t sample;
   float eye_scale;
   float eye_size;
   char device[NAME_MAX_LENGTH];
} camera_parallax_capture_t;

/* The capture backend owns the session until it clears running. */
bool camera_parallax_backend_start(camera_parallax_capture_t *capture);
void camera_parallax_backend_stop(void);
void camera_parallax_publish(camera_parallax_capture_t *capture,
      float x, float y, float face_area, float eye_span);

/* Main thread only. Positive offsets are viewer-right and down. A
 * face_size of one is the apparent size at the starting distance. */
void camera_parallax_update(bool enable, retro_time_t now,
      float *x, float *y, float *face_size);
void camera_parallax_stop(void);

RETRO_END_DECLS
#endif

#endif
