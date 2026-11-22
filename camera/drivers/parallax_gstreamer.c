#include "../camera_parallax.h"

#if defined(HAVE_CAMERA_PARALLAX) && defined(HAVE_CAMERA_PARALLAX_GSTREAMER)
#include <errno.h>
#include <glob.h>
#include <poll.h>
#include <sys/eventfd.h>
#include <unistd.h>

#include <gst/gst.h>
#include <rthreads/rthreads.h>

#include "../../verbosity.h"

#define PARALLAX_CAPTURE_WIDTH  320
#define PARALLAX_CAPTURE_HEIGHT 240

static int camera_parallax_wake_fd = -1;

static void camera_parallax_gst_message(camera_parallax_capture_t *capture,
      const GstStructure *message)
{
   const GValue *faces;
   unsigned i, area = 0;
   float x = 0.0f, y = 0.0f, eye_span = 0.0f;

   if (!message || !gst_structure_has_name(message, "facedetect")
         || !(faces = gst_structure_get_value(message, "faces"))
         || !GST_VALUE_HOLDS_LIST(faces))
      return;

   for (i = 0; i < gst_value_list_get_size(faces); i++)
   {
      const GValue *value      = gst_value_list_get_value(faces, i);
      const GstStructure *face = gst_value_get_structure(value);
      unsigned left, top, width, height;
      if (     face
            && gst_structure_get_uint(face, "x", &left)
            && gst_structure_get_uint(face, "y", &top)
            && gst_structure_get_uint(face, "width", &width)
            && gst_structure_get_uint(face, "height", &height)
            && width * height > area)
      {
         unsigned eye_width, eye_height;
         area = width * height;
         x    = (left + width * 0.5f) / PARALLAX_CAPTURE_WIDTH;
         y    = (top + height * 0.5f) / PARALLAX_CAPTURE_HEIGHT;
         eye_span = 0.0f;
         if (     gst_structure_get_uint(face, "eyes->width", &eye_width)
               && gst_structure_get_uint(face, "eyes->height", &eye_height)
               && eye_height && eye_height <= eye_width / 2
               && eye_width >= width / 3 && eye_width <= width)
            eye_span = (float)eye_width / PARALLAX_CAPTURE_WIDTH;
      }
   }
   camera_parallax_publish(capture, x, y,
         (float)area / (PARALLAX_CAPTURE_WIDTH * PARALLAX_CAPTURE_HEIGHT),
         eye_span);
}

static void camera_parallax_gst_worker(void *data)
{
   camera_parallax_capture_t *capture = (camera_parallax_capture_t*)data;
   GstElement *pipeline = NULL, *source = NULL;
   GstBus *bus = NULL;
   GError *error = NULL;
   GPollFD bus_fd;
   struct pollfd fds[2];
   uint64_t wake;
   char *description;
   char *device = NULL;
   const char *eye_profile;
   ssize_t ret;

   /* Clear any stop sent after the previous pipeline had already exited. */
   do
      ret = read(camera_parallax_wake_fd, &wake, sizeof(wake));
   while (ret < 0 && errno == EINTR);
   if (!retro_atomic_load_acquire_int(&capture->requested))
      goto done;
   if (!gst_init_check(NULL, NULL, &error))
      goto done;

   /* Downstream keeps only the newest camera frame when detection is slow. */
   description = g_strdup_printf("v4l2src name=camera ! decodebin ! "
         "queue leaky=downstream max-size-buffers=1 max-size-bytes=0 max-size-time=0 ! "
         "videorate drop-only=true max-rate=30 ! videoscale ! videoconvert ! "
         "video/x-raw,format=RGB,width=%u,height=%u,pixel-aspect-ratio=1/1 ! "
         "facedetect name=detector display=false ! fakesink sync=false",
         PARALLAX_CAPTURE_WIDTH, PARALLAX_CAPTURE_HEIGHT);
   pipeline = gst_parse_launch(description, &error);
   g_free(description);
   if (error || !pipeline)
      goto done;

   source = gst_bin_get_by_name(GST_BIN(pipeline), "camera");
   bus    = gst_element_get_bus(pipeline);
   if (!source || !bus)
      goto done;
   eye_profile = g_getenv("RETROARCH_CAMERA_EYE_PROFILE");
   if (eye_profile && *eye_profile)
   {
      GstElement *detector = gst_bin_get_by_name(GST_BIN(pipeline), "detector");
      if (detector)
      {
         g_object_set(detector, "eyes-profile", eye_profile, NULL);
         gst_object_unref(detector);
      }
   }
   if (*capture->device)
      g_object_set(source, "device", capture->device, NULL);
   else
   {
      glob_t devices = {0};
      if (glob("/dev/v4l/by-id/usb-*-video-index0", 0, NULL, &devices) == 0
            && devices.gl_pathc)
         g_object_set(source, "device", devices.gl_pathv[0], NULL);
      globfree(&devices);
   }

   if (!retro_atomic_load_acquire_int(&capture->requested))
      goto done;
   g_object_get(source, "device", &device, NULL);
   RARCH_LOG("[Camera parallax] Opening %s.\n", device ? device : "V4L2 camera");
   g_free(device);
   if (gst_element_set_state(pipeline, GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE)
   {
      GstMessage *message = gst_bus_pop_filtered(bus, GST_MESSAGE_ERROR);
      if (message)
      {
         gst_message_parse_error(message, &error, NULL);
         gst_message_unref(message);
      }
      else
         RARCH_ERR("[Camera parallax] Could not start the capture pipeline.\n");
      goto done;
   }

   gst_bus_get_pollfd(bus, &bus_fd);
   fds[0].fd     = camera_parallax_wake_fd;
   fds[0].events = POLLIN;
   fds[1].fd     = bus_fd.fd;
   fds[1].events = POLLIN;
   while (retro_atomic_load_acquire_int(&capture->requested))
   {
      GstMessage *message;
      int result = poll(fds, 2, -1);
      if (result < 0 && errno == EINTR)
         continue;
      if (result < 0 || fds[0].revents || !(fds[1].revents & POLLIN))
         break;
      message = gst_bus_pop_filtered(bus,
            GST_MESSAGE_ELEMENT | GST_MESSAGE_ERROR | GST_MESSAGE_EOS
            | GST_MESSAGE_STATE_CHANGED);
      if (message)
      {
         GstMessageType type = GST_MESSAGE_TYPE(message);
         if (type == GST_MESSAGE_ELEMENT)
            camera_parallax_gst_message(capture, gst_message_get_structure(message));
         else if (type == GST_MESSAGE_STATE_CHANGED
               && GST_MESSAGE_SRC(message) == GST_OBJECT(pipeline))
         {
            GstState state;
            gst_message_parse_state_changed(message, NULL, &state, NULL);
            if (state == GST_STATE_PLAYING)
               RARCH_LOG("[Camera parallax] Capture started.\n");
         }
         else if (type == GST_MESSAGE_ERROR)
            gst_message_parse_error(message, &error, NULL);
         else if (type == GST_MESSAGE_EOS)
            RARCH_WARN("[Camera parallax] The camera stream ended.\n");
         gst_message_unref(message);
         if (type == GST_MESSAGE_ERROR || type == GST_MESSAGE_EOS)
            break;
      }
   }

done:
   if (pipeline)
      gst_element_set_state(pipeline, GST_STATE_NULL);
   if (bus)
      gst_object_unref(bus);
   if (source)
      gst_object_unref(source);
   if (pipeline)
      gst_object_unref(pipeline);
   if (error)
   {
      RARCH_ERR("[Camera parallax] %s\n", error->message);
      g_error_free(error);
   }
   camera_parallax_publish(capture, 0.0f, 0.0f, 0.0f, 0.0f);
   retro_atomic_store_release_int(&capture->running, 0);
}

bool camera_parallax_backend_start(camera_parallax_capture_t *capture)
{
   sthread_t *thread;
   if (camera_parallax_wake_fd < 0)
      camera_parallax_wake_fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
   if (camera_parallax_wake_fd < 0
         || !(thread = sthread_create(camera_parallax_gst_worker, capture)))
      return false;
   sthread_detach(thread);
   return true;
}

void camera_parallax_backend_stop(void)
{
   uint64_t wake = 1;
   int result;
   do
      result = (int)write(camera_parallax_wake_fd, &wake, sizeof(wake));
   while (result < 0 && errno == EINTR);
}
#endif
