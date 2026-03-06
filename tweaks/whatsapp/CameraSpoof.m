#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <CoreImage/CoreImage.h>
#import <objc/runtime.h>
#import <objc/message.h> // Required for objc_msgSend

#include "../../lib/utils/utils.m"

/**
 * CameraSpoof.m - Fixed Compiler Errors
 * Procedural Pink + White Line Pattern
 */

 CVPixelBufferRef loadBufferFromImage(size_t width, size_t height, OSType pixelFormat) {
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
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };

    CVPixelBufferRef pxbuffer = NULL;
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         pixelFormat,
                                         (__bridge CFDictionaryRef)options,
                                         &pxbuffer);
    if (status != kCVReturnSuccess) { CGImageRelease(cgImage); return NULL; }

    // CIContext handles BGRA→YUV (and any other format) conversion automatically
    CIImage *ciImage = [CIImage imageWithCGImage:cgImage];
    CGImageRelease(cgImage);

    // Scale to fill the target rect
    CGFloat scaleX = (CGFloat)width  / ciImage.extent.size.width;
    CGFloat scaleY = (CGFloat)height / ciImage.extent.size.height;
    ciImage = [ciImage imageByApplyingTransform:CGAffineTransformMakeScale(scaleX, scaleY)];

    CIContext *ciCtx = [CIContext contextWithOptions:nil];
    [ciCtx render:ciImage toCVPixelBuffer:pxbuffer];

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
        OSType fmt = incomingPixelBuffer ? CVPixelBufferGetPixelFormatType(incomingPixelBuffer) : kCVPixelFormatType_32BGRA;
        spoofBuffer = loadBufferFromImage(w, h, fmt);
        if (!spoofBuffer) {
            spoofBuffer = createPinkBuffer((int)w, (int)h);
        }
    }

    SEL origSel = sel_registerName("original_captureOutput:didOutputSampleBuffer:fromConnection:");
    void (*msgSendFunc)(id, SEL, id, CMSampleBufferRef, id) = (void (*)(id, SEL, id, CMSampleBufferRef, id))objc_msgSend;

    CMSampleBufferRef fakeBuffer = NULL;
    if (spoofBuffer != NULL) {
        CMSampleTimingInfo timingInfo;
        CMSampleBufferGetSampleTimingInfo(sampleBuffer, 0, &timingInfo);
        CMVideoFormatDescriptionRef formatDesc = NULL;
        CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, spoofBuffer, &formatDesc);
        CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, spoofBuffer, YES, NULL, NULL, formatDesc, &timingInfo, &fakeBuffer);
        if (formatDesc) CFRelease(formatDesc);
    }

    // Fall back to original buffer if spoof buffer creation failed — keeps video timer running
    msgSendFunc(self, origSel, output, fakeBuffer ?: sampleBuffer, connection);
    if (fakeBuffer) CFRelease(fakeBuffer);
}

static CGImageRef loadSpoofCGImage() {
    NSString *dir = [getDocumentsPath() stringByAppendingPathComponent:@"TweakConfigs/CameraSpoof"];
    NSArray *supported = @[@"png", @"PNG", @"jpg", @"JPG", @"jpeg", @"JPEG"];
    for (NSString *ext in supported) {
        for (NSString *file in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil]) {
            if ([file.pathExtension.lowercaseString isEqualToString:ext.lowercaseString]) {
                NSString *imagePath = [dir stringByAppendingPathComponent:file];
                CGDataProviderRef provider = CGDataProviderCreateWithFilename(imagePath.UTF8String);
                if (!provider) return NULL;
                CGImageRef img = [ext.lowercaseString isEqualToString:@"png"]
                    ? CGImageCreateWithPNGDataProvider(provider, NULL, true, kCGRenderingIntentDefault)
                    : CGImageCreateWithJPEGDataProvider(provider, NULL, true, kCGRenderingIntentDefault);
                CGDataProviderRelease(provider);
                return img; // caller must CGImageRelease
            }
        }
    }
    return NULL;
}

static void hookPreviewLayer() {
    Class cls = [AVCaptureVideoPreviewLayer class];

    // Hook initWithSession: to add the overlay sublayer
    SEL initSel = @selector(initWithSession:);
    Method initM = class_getInstanceMethod(cls, initSel);
    if (!initM) return;

    __block IMP initOrig = method_getImplementation(initM);
    method_setImplementation(initM, imp_implementationWithBlock(^AVCaptureVideoPreviewLayer *(AVCaptureVideoPreviewLayer *self, AVCaptureSession *session) {
        AVCaptureVideoPreviewLayer *result = ((AVCaptureVideoPreviewLayer *(*)(id, SEL, id))initOrig)(self, initSel, session);

        CGImageRef cgImage = loadSpoofCGImage();
        if (!cgImage) return result;

        CALayer *overlay = [CALayer layer];
        overlay.name = @"CameraSpoofOverlay";
        overlay.contents = (__bridge id)cgImage;
        overlay.contentsGravity = kCAGravityResizeAspectFill;
        overlay.masksToBounds = YES;
        overlay.frame = result.bounds; // updated in layoutSublayers
        [result addSublayer:overlay];
        CGImageRelease(cgImage);

        return result;
    }));

    // Hook layoutSublayers to keep overlay filling the layer after layout
    SEL layoutSel = @selector(layoutSublayers);
    Method layoutM = class_getInstanceMethod(cls, layoutSel);
    __block IMP layoutOrig = layoutM ? method_getImplementation(layoutM) : NULL;
    IMP newLayoutImp = imp_implementationWithBlock(^(CALayer *self) {
        if (layoutOrig) ((void(*)(id, SEL))layoutOrig)(self, layoutSel);
        for (CALayer *sub in self.sublayers) {
            if ([sub.name isEqualToString:@"CameraSpoofOverlay"]) {
                sub.frame = self.bounds;
            }
        }
    });
    if (layoutM) {
        method_setImplementation(layoutM, newLayoutImp);
    } else {
        class_addMethod(cls, layoutSel, newLayoutImp, "v@:");
    }
}

static void hookAVCapturePhotoMethods() {
    Class cls = NSClassFromString(@"AVCapturePhoto");
    if (!cls) return;

    // --- pixelBuffer ---
    {
        SEL sel = @selector(pixelBuffer);
        Method m = class_getInstanceMethod(cls, sel);
        if (m) {
            __block IMP orig = method_getImplementation(m);
            method_setImplementation(m, imp_implementationWithBlock(^CVPixelBufferRef(id self) {
                static const void *kKey = &kKey;
                id cached = objc_getAssociatedObject(self, kKey);
                if (cached) return (__bridge CVPixelBufferRef)cached;
                CVPixelBufferRef original = ((CVPixelBufferRef(*)(id, SEL))orig)(self, sel);
                size_t w = original ? CVPixelBufferGetWidth(original)  : 4032;
                size_t h = original ? CVPixelBufferGetHeight(original) : 3024;
                OSType fmt = original ? CVPixelBufferGetPixelFormatType(original) : kCVPixelFormatType_32BGRA;
                CVPixelBufferRef spoof = loadBufferFromImage(w, h, fmt);
                if (!spoof) return original;
                id holder = CFBridgingRelease(spoof);
                objc_setAssociatedObject(self, kKey, holder, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                return (__bridge CVPixelBufferRef)holder;
            }));
        }
    }

    // --- cgImageRepresentation ---
    {
        SEL sel = @selector(cgImageRepresentation);
        Method m = class_getInstanceMethod(cls, sel);
        if (m) {
            method_setImplementation(m, imp_implementationWithBlock(^CGImageRef(id self) {
                static const void *kKey = &kKey;
                id cached = objc_getAssociatedObject(self, kKey);
                if (cached) return (__bridge CGImageRef)cached;
                CGImageRef img = loadSpoofCGImage();
                if (!img) return NULL;
                id holder = CFBridgingRelease(img);
                objc_setAssociatedObject(self, kKey, holder, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                return (__bridge CGImageRef)holder;
            }));
        }
    }

    // --- fileDataRepresentation (JPEG bytes - what most apps actually use) ---
    {
        SEL sel = @selector(fileDataRepresentation);
        Method m = class_getInstanceMethod(cls, sel);
        if (m) {
            method_setImplementation(m, imp_implementationWithBlock(^NSData *(id self) {
                static const void *kKey = &kKey;
                NSData *cached = objc_getAssociatedObject(self, kKey);
                if (cached) return cached;
                CGImageRef img = loadSpoofCGImage();
                if (!img) return NULL;
                NSMutableData *data = [NSMutableData data];
                CGImageDestinationRef dest = CGImageDestinationCreateWithData(
                    (__bridge CFMutableDataRef)data,
                    (__bridge CFStringRef)@"public.jpeg", 1, NULL);
                if (dest) {
                    CGImageDestinationAddImage(dest, img, NULL);
                    CGImageDestinationFinalize(dest);
                    CFRelease(dest);
                }
                CGImageRelease(img);
                if (!data.length) return NULL;
                objc_setAssociatedObject(self, kKey, data, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                return data;
            }));
        }
    }
}

static void swizzleCaptureDelegate(id delegate) {
    if (!delegate) return;
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

static void init() {
    hookPreviewLayer();
    hookAVCapturePhotoMethods();

    // Hook setSampleBufferDelegate:queue: to catch delegates set after dylib load
    Method m = class_getInstanceMethod([AVCaptureVideoDataOutput class], @selector(setSampleBufferDelegate:queue:));
    if (m) {
        __block IMP orig = method_getImplementation(m);
        method_setImplementation(m, imp_implementationWithBlock(^(AVCaptureVideoDataOutput *self, id delegate, dispatch_queue_t queue) {
            swizzleCaptureDelegate(delegate);
            ((void(*)(id, SEL, id, dispatch_queue_t))orig)(self, @selector(setSampleBufferDelegate:queue:), delegate, queue);
        }));
    }

    // Hook AVCaptureSession startRunning to catch delegates already set before dylib load (e.g. Telegram)
    Method startM = class_getInstanceMethod([AVCaptureSession class], @selector(startRunning));
    if (startM) {
        __block IMP startOrig = method_getImplementation(startM);
        method_setImplementation(startM, imp_implementationWithBlock(^(AVCaptureSession *self) {
            for (AVCaptureOutput *output in self.outputs) {
                if ([output isKindOfClass:[AVCaptureVideoDataOutput class]]) {
                    swizzleCaptureDelegate(((AVCaptureVideoDataOutput *)output).sampleBufferDelegate);
                }
            }
            ((void(*)(id, SEL))startOrig)(self, @selector(startRunning));
        }));
    }
}

INITIALIZE("CameraSpoof")
