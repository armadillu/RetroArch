#include "../camera_parallax.h"

#ifdef HAVE_CAMERA_PARALLAX
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#ifdef __APPLE__
#include <crt_externs.h>
#else
extern char **environ;
#endif

#include <rthreads/rthreads.h>

#include "../../verbosity.h"

static int camera_landmarks_wake[2] = {-1, -1};

struct camera_landmarks_worker
{
   camera_parallax_capture_t *capture;
   const char *helper;
};

static bool camera_landmarks_pipe(int *fds, bool nonblock)
{
   if (pipe(fds) != 0)
      return false;
   if (     fcntl(fds[0], F_SETFD, FD_CLOEXEC) == 0
         && fcntl(fds[1], F_SETFD, FD_CLOEXEC) == 0
         && (!nonblock || (fcntl(fds[0], F_SETFL, O_NONBLOCK) == 0
               && fcntl(fds[1], F_SETFL, O_NONBLOCK) == 0)))
      return true;
   close(fds[0]);
   close(fds[1]);
   fds[0] = fds[1] = -1;
   return false;
}

static void camera_landmarks_read(camera_parallax_capture_t *capture, int fd)
{
   struct pollfd fds[2];
   float pose[4];
   size_t used = 0;

   fds[0].fd     = camera_landmarks_wake[0];
   fds[0].events = POLLIN;
   fds[1].fd     = fd;
   fds[1].events = POLLIN;
   while (retro_atomic_load_acquire_int(&capture->requested))
   {
      int ready = poll(fds, 2, -1);
      ssize_t bytes;
      if (ready < 0 && errno == EINTR)
         continue;
      if (ready < 0 || fds[0].revents || !(fds[1].revents & POLLIN))
         break;
      bytes = read(fd, (char*)pose + used, sizeof(pose) - used);
      if (bytes < 0 && errno == EINTR)
         continue;
      if (bytes <= 0)
         break;
      used += (size_t)bytes;
      if (used == sizeof(pose))
      {
         if (     pose[0] >= 0.0f && pose[0] <= 1.0f
               && pose[1] >= 0.0f && pose[1] <= 1.0f
               && pose[2] >= 0.0f && pose[2] <= 1.0f
               && pose[3] >= 0.0f && pose[3] <= 1.0f)
            camera_parallax_publish(capture, pose[0], pose[1], pose[2], pose[3]);
         used = 0;
      }
   }
}

static void camera_landmarks_run(void *data)
{
   struct camera_landmarks_worker *worker = (struct camera_landmarks_worker*)data;
   camera_parallax_capture_t *capture    = worker->capture;
   char *args[3];
   posix_spawn_file_actions_t actions;
   pid_t child;
   int fds[2], error;
   char wake;

   /* A stop can arrive after the previous helper has exited. */
   while (read(camera_landmarks_wake[0], &wake, sizeof(wake)) > 0)
      ;
   if (!retro_atomic_load_acquire_int(&capture->requested))
      goto done;
   if (!camera_landmarks_pipe(fds, false))
   {
      RARCH_ERR("[Camera parallax] Could not open the landmark helper pipe.\n");
      goto done;
   }

   args[0] = (char*)worker->helper;
   args[1] = capture->device;
   args[2] = NULL;
   error = posix_spawn_file_actions_init(&actions);
   if (error == 0)
   {
      error = posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO);
      if (error == 0)
         error = posix_spawn(&child, worker->helper, &actions, NULL, args,
#ifdef __APPLE__
               *_NSGetEnviron());
#else
               environ);
#endif
      posix_spawn_file_actions_destroy(&actions);
   }
   close(fds[1]);
   if (error == 0)
   {
      RARCH_LOG("[Camera parallax] Started landmark helper.\n");
      camera_landmarks_read(capture, fds[0]);
      if (retro_atomic_load_acquire_int(&capture->requested))
         RARCH_WARN("[Camera parallax] Landmark helper stopped.\n");
      /* The helper may be blocked in a camera read. Retire it on this worker. */
      kill(child, SIGKILL);
      while (waitpid(child, NULL, 0) < 0 && errno == EINTR)
         ;
   }
   else
      RARCH_ERR("[Camera parallax] Could not start landmark helper: %s.\n",
            strerror(error));
   close(fds[0]);

done:
   free(worker);
   camera_parallax_publish(capture, 0.0f, 0.0f, 0.0f, 0.0f);
   retro_atomic_store_release_int(&capture->running, 0);
}

bool camera_parallax_landmarks_start(camera_parallax_capture_t *capture,
      const char *helper)
{
   sthread_t *thread;
   struct camera_landmarks_worker *worker;
   if (camera_landmarks_wake[0] < 0
         && !camera_landmarks_pipe(camera_landmarks_wake, true))
      return false;
   if (!(worker = (struct camera_landmarks_worker*)malloc(sizeof(*worker))))
      return false;
   worker->capture = capture;
   worker->helper  = helper;
   if (!(thread = sthread_create(camera_landmarks_run, worker)))
   {
      free(worker);
      return false;
   }
   sthread_detach(thread);
   return true;
}

void camera_parallax_landmarks_stop(void)
{
   char wake = 1;
   ssize_t result;
   do
      result = write(camera_landmarks_wake[1], &wake, sizeof(wake));
   while (result < 0 && errno == EINTR);
}
#endif
