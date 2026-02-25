com.kdt.livecontainer.2UW67KF476

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h> // Required for objc_msgSend

/**
 * CameraSpoof.m - Fixed Compiler Errors
 * Procedural Pink + White Line Pattern
 */

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
        spoofBuffer = createPinkBuffer(1280, 720);
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

__attribute__((constructor))
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
