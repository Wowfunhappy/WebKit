/*
 * Copyright (C) 2017-2025 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "config.h"
#import "WebIconUtilities.h"

#if PLATFORM(COCOA)

#if PLATFORM(IOS_FAMILY)
#import "UIKitSPI.h"
#import <MobileCoreServices/MobileCoreServices.h>
#else
#import <CoreServices/CoreServices.h>
#endif

#import "CocoaImage.h"
#if HAVE(AVFOUNDATION)
#import <AVFoundation/AVFoundation.h>
#endif
#import <CoreGraphics/CoreGraphics.h>
#if HAVE(AVFOUNDATION)
#import <CoreMedia/CoreMedia.h>
#endif
#import <ImageIO/ImageIO.h>
#if __has_include(<UniformTypeIdentifiers/UniformTypeIdentifiers.h>)
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#endif
#import <WebCore/PlatformImage.h>
#import <wtf/MathExtras.h>
#import <wtf/RetainPtr.h>
#import <wtf/Vector.h>
#import <wtf/text/WTFString.h>

#if HAVE(AVFOUNDATION)
#import <pal/cf/CoreMediaSoftLink.h>
#import <pal/cocoa/AVFoundationSoftLink.h>
#endif

namespace WebKit {

static const CGFloat iconSideLength = 100;

static CGRect squareCropRectForSize(CGSize size)
{
    CGFloat smallerSide = std::min(size.width, size.height);
    CGRect cropRect = CGRectMake(0, 0, smallerSide, smallerSide);

    if (size.width < size.height)
        cropRect.origin.y = std::round((size.height - smallerSide) / 2);
    else
        cropRect.origin.x = std::round((size.width - smallerSide) / 2);

    return cropRect;
}

static WebCore::PlatformImagePtr squareImage(CGImageRef image)
{
    if (!image)
        return nil;

    CGSize imageSize = CGSizeMake(CGImageGetWidth(image), CGImageGetHeight(image));
    if (imageSize.width == imageSize.height)
        return image;

    CGRect squareCropRect = squareCropRectForSize(imageSize);
    return adoptCF(CGImageCreateWithImageInRect(image, squareCropRect));
}

static RetainPtr<CocoaImage> thumbnailSizedImageForImage(CGImageRef image)
{
    auto squaredImage = squareImage(image);
    if (!squaredImage)
        return nullptr;

    CGRect destinationRect = CGRectMake(0, 0, iconSideLength, iconSideLength);

    RetainPtr colorSpace = CGImageGetColorSpace(image);
    if (!CGColorSpaceSupportsOutput(colorSpace.get()))
        colorSpace = adoptCF(CGColorSpaceCreateWithName(kCGColorSpaceSRGB));

    auto context = adoptCF(CGBitmapContextCreate(nil, iconSideLength, iconSideLength, 8, 4 * iconSideLength, colorSpace.get(), kCGImageAlphaPremultipliedLast));

    CGContextSetInterpolationQuality(context.get(), kCGInterpolationHigh);
    CGContextDrawImage(context.get(), destinationRect, squaredImage.get());

    auto scaledImage = adoptCF(CGBitmapContextCreateImage(context.get()));

    RetainPtr thumbnailImage = scaledImage.get() ?: squaredImage.get();
#if USE(APPKIT)
    return adoptNS([[NSImage alloc] initWithCGImage:thumbnailImage.get() size:NSZeroSize]);
#else
    return adoptNS([[UIImage alloc] initWithCGImage:thumbnailImage.get()]);
#endif
}

RetainPtr<CocoaImage> fallbackIconForFile(NSURL *file)
{
    ASSERT_ARG(file, [file isFileURL]);

#if PLATFORM(MAC)
ALLOW_DEPRECATED_DECLARATIONS_BEGIN
    return [[NSWorkspace sharedWorkspace] iconForFileType:retainPtr([@"." stringByAppendingString:retainPtr(file.pathExtension).get()]).get()];
ALLOW_DEPRECATED_DECLARATIONS_END
#else
    NSError *error = nil;
    if (![file checkResourceIsReachableAndReturnError:&error])
        return nil;
    UIDocumentInteractionController *interactionController = [UIDocumentInteractionController interactionControllerWithURL:file];
    if (![interactionController.icons count])
        return nil;
    return thumbnailSizedImageForImage(RetainPtr<CGImageRef> { [protect(interactionController.icons[0]) CGImage] });
#endif
}

const CFStringRef kCGImageSourceEnableRestrictedDecoding = CFSTR("kCGImageSourceEnableRestrictedDecoding");

RetainPtr<CocoaImage> iconForImageFile(NSURL *file)
{
    ASSERT_ARG(file, [file isFileURL]);

    NSDictionary *options = @{
        (id)kCGImageSourceCreateThumbnailFromImageIfAbsent: @YES,
        (id)kCGImageSourceThumbnailMaxPixelSize: @(iconSideLength),
        (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (id)kCGImageSourceEnableRestrictedDecoding: @YES
    };
    RetainPtr<CGImageSource> imageSource = adoptCF(CGImageSourceCreateWithURL((CFURLRef)file, 0));
    RetainPtr<CGImageRef> thumbnail = adoptCF(CGImageSourceCreateThumbnailAtIndex(imageSource.get(), 0, (CFDictionaryRef)options));
    if (!thumbnail) {
        LOG_ERROR("Error creating thumbnail image for image: %@", file);
        return fallbackIconForFile(file);
    }

    return thumbnailSizedImageForImage(thumbnail.get());
}

#if HAVE(AVFOUNDATION)
RetainPtr<CocoaImage> iconForVideoFile(NSURL *file)
{
    ASSERT_ARG(file, [file isFileURL]);

    RetainPtr<AVURLAsset> asset = adoptNS([PAL::allocAVURLAssetInstance() initWithURL:file options:nil]);
    RetainPtr<AVAssetImageGenerator> generator = adoptNS([PAL::allocAVAssetImageGeneratorInstance() initWithAsset:asset.get()]);
    [generator setAppliesPreferredTrackTransform:YES];

    NSError *error = nil;
ALLOW_DEPRECATED_DECLARATIONS_BEGIN
    RetainPtr<CGImageRef> imageRef = adoptCF([generator copyCGImageAtTime:PAL::kCMTimeZero actualTime:nil error:&error]);
ALLOW_DEPRECATED_DECLARATIONS_END
    if (!imageRef) {
        LOG_ERROR("Error creating image for video '%@': %@", file, error);
        return fallbackIconForFile(file);
    }

    return thumbnailSizedImageForImage(imageRef.get());
}
#else
RetainPtr<CocoaImage> iconForVideoFile(NSURL *file)
{
    return fallbackIconForFile(file);
}
#endif

RetainPtr<CocoaImage> iconForFiles(const Vector<String>& filenames)
{
    if (!filenames.size())
        return nil;

    // FIXME: We should generate an icon showing multiple files here, if applicable. Currently, if there are multiple
    // files, we only use the first URL to generate an icon.
    RetainPtr file = adoptNS([[NSURL alloc] initFileURLWithPath:filenames[0].createNSString().get() isDirectory:NO]);
    if (!file)
        return nil;

    ASSERT_ARG(file, [file isFileURL]);

    RetainPtr<NSString> fileExtension = file.get().pathExtension;
    if (!fileExtension.get().length)
        return nil;

    // MAVERICKS_BACKPORT: UTType/UniformTypeIdentifiers is macOS 11+ and absent on 10.9, so the legacy
    // CoreServices UTType C API (present at runtime on 10.9) maps the filename extension to a UTI
    // CFStringRef and tests conformance to kUTTypeImage / kUTTypeMovie via UTTypeConformsTo.
    RetainPtr fileUTI = adoptCF(UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, (__bridge CFStringRef)fileExtension.get(), nullptr));
    if (fileUTI && UTTypeConformsTo(fileUTI.get(), kUTTypeImage))
        return iconForImageFile(file.get());

    if (fileUTI && UTTypeConformsTo(fileUTI.get(), kUTTypeMovie))
        return iconForVideoFile(file.get());

    return fallbackIconForFile(file.get());
}

}

#endif
