#include "../camera_parallax.h"

#if defined(HAVE_CAMERA_PARALLAX) && defined(__APPLE__)
#import <AVFoundation/AVFoundation.h>
#import <Vision/Vision.h>
#include <defines/cocoa_defines.h>
#include <dlfcn.h>
#include <math.h>

#include "../../verbosity.h"

API_AVAILABLE(macos(10.13))
@interface RAParallaxCamera : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
{
@public
   camera_parallax_capture_t *capture;
   AVCaptureSession *session;
   AVCaptureVideoDataOutput *output;
   VNDetectFaceLandmarksRequest *request;
   CMTime lastDetection;
}
- (BOOL)startOnQueue:(dispatch_queue_t)queue;
- (void)stop;
@end

static dispatch_queue_t camera_parallax_queue;
static RAParallaxCamera *camera_parallax_session API_AVAILABLE(macos(10.13));

@implementation RAParallaxCamera

static BOOL camera_parallax_eye_center(VNFaceLandmarkRegion2D *eye,
      CGPoint *center) API_AVAILABLE(macos(10.13))
{
   NSUInteger i, count = eye.pointCount;
   const CGPoint *points = eye.normalizedPoints;
   CGPoint lower, upper;

   if (!points || count < 2)
      return NO;
   lower = upper = points[0];
   for (i = 1; i < count; i++)
   {
      lower.x = MIN(lower.x, points[i].x);
      upper.x = MAX(upper.x, points[i].x);
      lower.y = MIN(lower.y, points[i].y);
      upper.y = MAX(upper.y, points[i].y);
   }
   *center = CGPointMake((lower.x + upper.x) * 0.5,
         (lower.y + upper.y) * 0.5);
   return YES;
}

- (BOOL)startOnQueue:(dispatch_queue_t)queue
{
   static void *vision;
   AVCaptureDevice *device = nil;
   AVCaptureDeviceInput *input;
   NSArray<AVCaptureDevice *> *devices;
   NSString *choice = [NSString stringWithUTF8String:capture->device];

   if (!vision)
      vision = dlopen("/System/Library/Frameworks/Vision.framework/Vision",
            RTLD_LAZY | RTLD_LOCAL);
   if (!vision)
      return NO;
   request = [(VNDetectFaceLandmarksRequest *)
         [NSClassFromString(@"VNDetectFaceLandmarksRequest") alloc] init];
   if (!request)
      return NO;

#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 140000
   if (@available(macOS 14.0, *))
      devices = [AVCaptureDeviceDiscoverySession
            discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeExternal,
               AVCaptureDeviceTypeBuiltInWideAngleCamera]
            mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionUnspecified].devices;
   else
#endif
   {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
      devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
#pragma clang diagnostic pop
   }

   for (AVCaptureDevice *candidate in devices)
   {
      if ([candidate.uniqueID isEqualToString:choice]
            || [candidate.localizedName isEqualToString:choice])
      {
         device = candidate;
         break;
      }
      if (!choice.length && candidate.transportType == 'usb ' && !device)
         device = candidate;
   }
   if (!device && !choice.length)
      device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
   if (!device || !(input = [AVCaptureDeviceInput deviceInputWithDevice:device error:NULL]))
      return NO;

   session = [[AVCaptureSession alloc] init];
   output  = [[AVCaptureVideoDataOutput alloc] init];
   if (![session canAddInput:input] || ![session canAddOutput:output])
      return NO;
   [session addInput:input];
   [session addOutput:output];
   if ([session canSetSessionPreset:AVCaptureSessionPreset640x480])
      session.sessionPreset = AVCaptureSessionPreset640x480;
   output.alwaysDiscardsLateVideoFrames = YES;
   lastDetection = kCMTimeInvalid;
   [output setSampleBufferDelegate:self queue:queue];
   [session startRunning];
   return session.running;
}

- (void)stop
{
   [session stopRunning];
   [output setSampleBufferDelegate:nil queue:NULL];
   capture = NULL;
   RARCH_RELEASE_NIL(request);
   RARCH_RELEASE_NIL(output);
   RARCH_RELEASE_NIL(session);
}

- (void)captureOutput:(AVCaptureOutput *)source
    didOutputSampleBuffer:(CMSampleBufferRef)buffer
           fromConnection:(AVCaptureConnection *)connection
{
   CMTime timestamp = CMSampleBufferGetPresentationTimeStamp(buffer);
   CVPixelBufferRef pixels = CMSampleBufferGetImageBuffer(buffer);
   CGRect best = CGRectZero;
   VNFaceObservation *bestFace = nil;
   float eyeSpan = 0.0f;
   VNImageRequestHandler *handler;

   if (!capture || !pixels || !retro_atomic_load_acquire_int(&capture->requested))
      return;
   if (CMTIME_IS_VALID(lastDetection) && CMTIME_IS_VALID(timestamp)
         && CMTimeCompare(timestamp, lastDetection) >= 0
         && CMTimeCompare(CMTimeSubtract(timestamp, lastDetection), CMTimeMake(1, 36)) < 0)
      return;
   lastDetection = timestamp;

   @autoreleasepool
   {
      /* AVFoundation lends the pixel buffer for this callback. */
      handler = [(VNImageRequestHandler *)
            [NSClassFromString(@"VNImageRequestHandler") alloc]
            initWithCVPixelBuffer:pixels options:@{}];
      if ([handler performRequests:@[request] error:NULL])
         for (VNFaceObservation *face in request.results)
         {
            CGRect rect = face.boundingBox;
            if (rect.size.width * rect.size.height > best.size.width * best.size.height)
            {
               best = rect;
               bestFace = face;
            }
         }
      if (bestFace)
      {
         CGPoint left, right;
         VNFaceLandmarks2D *landmarks = bestFace.landmarks;
         if (camera_parallax_eye_center(landmarks.leftEye, &left)
               && camera_parallax_eye_center(landmarks.rightEye, &right))
         {
            double yawScale = 1.0;
            double dx = (left.x - right.x) * best.size.width;
            double dy = (left.y - right.y) * best.size.height
               * CVPixelBufferGetHeight(pixels) / CVPixelBufferGetWidth(pixels);
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 101400
            if (@available(macOS 10.14, *))
               yawScale = cos(bestFace.yaw.doubleValue);
#endif
            /* At large turns a partly hidden eye is a poor depth cue. */
            if (yawScale >= 0.8)
               eyeSpan = (float)(hypot(dx, dy) / yawScale);
         }
      }
      camera_parallax_publish(capture, CGRectGetMidX(best),
            1.0 - CGRectGetMidY(best), best.size.width * best.size.height,
            eyeSpan);
      RARCH_RELEASE(handler);
   }
}
@end

API_AVAILABLE(macos(10.13))
static void camera_parallax_retire_avf(void)
{
   if (camera_parallax_session)
   {
      camera_parallax_capture_t *capture = camera_parallax_session->capture;
      [camera_parallax_session stop];
      RARCH_RELEASE_NIL(camera_parallax_session);
      retro_atomic_store_release_int(&capture->running, 0);
   }
}

bool camera_parallax_backend_start(camera_parallax_capture_t *capture)
{
   if (@available(macOS 10.13, *))
   {
      if (!camera_parallax_queue)
         camera_parallax_queue = dispatch_queue_create(
               "org.libretro.camera-parallax", DISPATCH_QUEUE_SERIAL);
      if (!camera_parallax_queue)
         return false;

      dispatch_async(camera_parallax_queue, ^{
         @autoreleasepool
         {
            RAParallaxCamera *camera = [[RAParallaxCamera alloc] init];
            camera_parallax_session  = camera;
            camera->capture          = capture;
            if (!retro_atomic_load_acquire_int(&capture->requested))
            {
               camera_parallax_retire_avf();
               return;
            }
            if (@available(macOS 10.14, *))
            {
               AVAuthorizationStatus status =
                     [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
               if (status == AVAuthorizationStatusNotDetermined)
               {
                  [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
                        completionHandler:^(BOOL granted) {
                     dispatch_async(camera_parallax_queue, ^{
                        if (camera != camera_parallax_session)
                           return;
                        if (!granted || !retro_atomic_load_acquire_int(&capture->requested))
                           camera_parallax_retire_avf();
                        else if (![camera startOnQueue:camera_parallax_queue])
                        {
                           RARCH_ERR("[Camera parallax] Could not open camera.\n");
                           camera_parallax_retire_avf();
                        }
                     });
                  }];
                  return;
               }
               if (status != AVAuthorizationStatusAuthorized)
               {
                  RARCH_ERR("[Camera parallax] Camera access denied.\n");
                  camera_parallax_retire_avf();
                  return;
               }
            }
            if (![camera startOnQueue:camera_parallax_queue])
            {
               RARCH_ERR("[Camera parallax] Could not open camera.\n");
               camera_parallax_retire_avf();
            }
         }
      });
      return true;
   }
   return false;
}

void camera_parallax_backend_stop(void)
{
   if (@available(macOS 10.13, *))
      dispatch_async(camera_parallax_queue, ^{
         camera_parallax_retire_avf();
      });
}
#endif
