#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h> // Required for objc_msgSend

#include "../../lib/utils/utils.m"

/**
 * CameraSpoof.m - Fixed Compiler Errors
 * Procedural Pink + White Line Pattern
 */

 CVPixelBufferRef loadBufferFromImage(size_t width, size_t height) {
    NSString *dir = [getDocumentsPath() stringByAppendingPathComponent:@"TweakConfigs/CameraSpoof"];
    NSArray *supported = @[@"png", @"PNG", @"jpg", @"JPG", @"jpeg", @"JPEG"];
    NSString *imagePath = nil;
    for (NSString *ext in supported) {
        NSArray *matches = [[NSFileManager defaultManager]
            contentsOfDirectoryAtPath:dir error:nil];
        for (NSString *file in matches) {
            if ([file.pathExtension.lowercaseString isEqualToString:ext.lowercaseString]) {
                imagePath = [dir stringByAppendingPathComponent:file];
                break;
            }
        }
        if (imagePath) break;
    }
    if (!imagePath) {
        os_log(OS_LOG_DEFAULT, "Camera spoof: no image found in %{public}s", dir.UTF8String);
        return NULL;
    }

    CGDataProviderRef provider = CGDataProviderCreateWithFilename(imagePath.UTF8String);
    if (!provider) return NULL;

    NSString *ext = imagePath.pathExtension.lowercaseString;
    CGImageRef cgImage = [ext isEqualToString:@"png"]
        ? CGImageCreateWithPNGDataProvider(provider, NULL, true, kCGRenderingIntentDefault)
        : CGImageCreateWithJPEGDataProvider(provider, NULL, true, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    if (!cgImage) return NULL;

    NSDictionary *options = @{
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES
    };

    CVPixelBufferRef pxbuffer = NULL;
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_32BGRA,
                                         (__bridge CFDictionaryRef)options,
                                         &pxbuffer);
    if (status != kCVReturnSuccess) { CGImageRelease(cgImage); return NULL; }

    CVPixelBufferLockBaseAddress(pxbuffer, 0);
    void *baseAddress = CVPixelBufferGetBaseAddress(pxbuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pxbuffer);

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(baseAddress, width, height, 8, bytesPerRow,
                                                 colorSpace,
                                                 kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    // Draw image scaled to the target dimensions (matching the camera frame)
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), cgImage);
    CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);
    CGImageRelease(cgImage);

    CVPixelBufferUnlockBaseAddress(pxbuffer, 0);
    return pxbuffer;
 }

static CVPixelBufferRef spoofBuffer = NULL;

CVPixelBufferRef createPinkBuffer(int width, int height) {
    CVPixelBufferRef pxbuffer = NULL;
    NSDictionary *options = @{
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES
    };
    
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, 
                                          kCVPixelFormatType_32BGRA, 
                                          (__bridge CFDictionaryRef)options, 
                                          &pxbuffer);
    if (status != kCVReturnSuccess) return NULL;

    CVPixelBufferLockBaseAddress(pxbuffer, 0);
    unsigned char *baseAddress = (unsigned char *)CVPixelBufferGetBaseAddress(pxbuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pxbuffer);

    for (int y = 0; y < height; y++) {
        unsigned char *row = baseAddress + (y * bytesPerRow);
        for (int x = 0; x < width; x++) {
            int offset = x * 4;
            // Draw white line in the middle (approx 10px thick)
            if (y >= (height/2) - 5 && y <= (height/2) + 5) {
                row[offset] = 255; row[offset+1] = 255; row[offset+2] = 255; row[offset+3] = 255;
            } else {
                // Pink (BGRA: B=180, G=105, R=255)
                row[offset] = 180; row[offset+1] = 105; row[offset+2] = 255; row[offset+3] = 255;
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(pxbuffer, 0);
    return pxbuffer;
}

static void swizzled_captureOutput(id self, SEL _cmd, AVCaptureOutput *output, CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection) {
    if (spoofBuffer == NULL) {
        CVPixelBufferRef incomingPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        size_t w = incomingPixelBuffer ? CVPixelBufferGetWidth(incomingPixelBuffer) : 1280;
        size_t h = incomingPixelBuffer ? CVPixelBufferGetHeight(incomingPixelBuffer) : 720;
        spoofBuffer = loadBufferFromImage(w, h);
        if (!spoofBuffer) {
            spoofBuffer = createPinkBuffer((int)w, (int)h);
        }
    }

    if (spoofBuffer != NULL) {
        CMSampleBufferRef fakeBuffer = NULL;
        CMSampleTimingInfo timingInfo;
        CMSampleBufferGetSampleTimingInfo(sampleBuffer, 0, &timingInfo);
        
        CMVideoFormatDescriptionRef formatDesc = NULL;
        CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, spoofBuffer, &formatDesc);
        
        CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, spoofBuffer, YES, NULL, NULL, formatDesc, &timingInfo, &fakeBuffer);
        
        SEL origSel = sel_registerName("original_captureOutput:didOutputSampleBuffer:fromConnection:");
        
        // Explicitly cast objc_msgSend to prevent the "undeclared" or "strict prototype" errors
        void (*msgSendFunc)(id, SEL, id, CMSampleBufferRef, id) = (void (*)(id, SEL, id, CMSampleBufferRef, id))objc_msgSend;
        msgSendFunc(self, origSel, output, fakeBuffer, connection);
        
        if (fakeBuffer) CFRelease(fakeBuffer);
        if (formatDesc) CFRelease(formatDesc);
    }
}

static void init() {
    Method m = class_getInstanceMethod([AVCaptureVideoDataOutput class], @selector(setSampleBufferDelegate:queue:));
    if (!m) return;
    
    __block IMP orig = method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^(AVCaptureVideoDataOutput *self, id delegate, dispatch_queue_t queue) {
        if (delegate) {
            Class cls = [delegate class];
            SEL targetSel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
            SEL origSel = sel_registerName("original_captureOutput:didOutputSampleBuffer:fromConnection:");
            
            if (!class_getInstanceMethod(cls, origSel)) {
                Method origM = class_getInstanceMethod(cls, targetSel);
                if (origM) {
                    class_addMethod(cls, origSel, method_getImplementation(origM), method_getTypeEncoding(origM));
                    method_setImplementation(origM, (IMP)swizzled_captureOutput);
                }
            }
        }
        // Original call
        ((void(*)(id, SEL, id, dispatch_queue_t))orig)(self, @selector(setSampleBufferDelegate:queue:), delegate, queue);
    }));
}

INITIALIZE("CameraSpoof")
