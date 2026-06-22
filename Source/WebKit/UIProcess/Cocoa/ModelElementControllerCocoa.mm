/*
 * Copyright (C) 2021 Apple Inc. All rights reserved.
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

// MAVERICKS_BACKPORT: <model> element needs ARKit/RealityKit (10.15+), unsupportable on 10.9;
// provide no-op impls so WebPageProxy's model message handlers link. Feature is inert (the web
// process side reports no model support). The upstream Cocoa bodies drive ASVInlinePreview from
// the AssetViewer private framework, whose inline-preview runtime does not function on 10.9.
// All ModelElementController methods that WebPageProxy references under ENABLE(ARKIT_INLINE_PREVIEW)
// are provided here as no-ops; each completion handler reports a safe failure/empty value.

#import "config.h"
#import "ModelElementController.h"

#import <WebCore/HTMLModelElementCamera.h>
#import <WebCore/LayoutPoint.h>
#import <WebCore/ResourceError.h>
#import <wtf/CompletionHandler.h>
#import <wtf/Expected.h>
#import <wtf/MachSendRight.h>
#import <wtf/MonotonicTime.h>
#import <wtf/Seconds.h>
#import <wtf/URL.h>

#if ENABLE(ARKIT_INLINE_PREVIEW)

namespace WebKit {

void ModelElementController::getCameraForModelElement(ModelIdentifier, CompletionHandler<void(Expected<WebCore::HTMLModelElementCamera, WebCore::ResourceError>)>&& completionHandler)
{
    completionHandler(makeUnexpected(WebCore::ResourceError { WebCore::ResourceError::Type::General }));
}

void ModelElementController::setCameraForModelElement(ModelIdentifier, WebCore::HTMLModelElementCamera, CompletionHandler<void(bool)>&& completionHandler)
{
    completionHandler(false);
}

void ModelElementController::isPlayingAnimationForModelElement(ModelIdentifier, CompletionHandler<void(Expected<bool, WebCore::ResourceError>)>&& completionHandler)
{
    completionHandler(makeUnexpected(WebCore::ResourceError { WebCore::ResourceError::Type::General }));
}

void ModelElementController::setAnimationIsPlayingForModelElement(ModelIdentifier, bool, CompletionHandler<void(bool)>&& completionHandler)
{
    completionHandler(false);
}

void ModelElementController::isLoopingAnimationForModelElement(ModelIdentifier, CompletionHandler<void(Expected<bool, WebCore::ResourceError>)>&& completionHandler)
{
    completionHandler(makeUnexpected(WebCore::ResourceError { WebCore::ResourceError::Type::General }));
}

void ModelElementController::setIsLoopingAnimationForModelElement(ModelIdentifier, bool, CompletionHandler<void(bool)>&& completionHandler)
{
    completionHandler(false);
}

void ModelElementController::animationDurationForModelElement(ModelIdentifier, CompletionHandler<void(Expected<Seconds, WebCore::ResourceError>)>&& completionHandler)
{
    completionHandler(makeUnexpected(WebCore::ResourceError { WebCore::ResourceError::Type::General }));
}

void ModelElementController::animationCurrentTimeForModelElement(ModelIdentifier, CompletionHandler<void(Expected<Seconds, WebCore::ResourceError>)>&& completionHandler)
{
    completionHandler(makeUnexpected(WebCore::ResourceError { WebCore::ResourceError::Type::General }));
}

void ModelElementController::setAnimationCurrentTimeForModelElement(ModelIdentifier, Seconds, CompletionHandler<void(bool)>&& completionHandler)
{
    completionHandler(false);
}

void ModelElementController::hasAudioForModelElement(ModelIdentifier, CompletionHandler<void(Expected<bool, WebCore::ResourceError>)>&& completionHandler)
{
    completionHandler(makeUnexpected(WebCore::ResourceError { WebCore::ResourceError::Type::General }));
}

void ModelElementController::isMutedForModelElement(ModelIdentifier, CompletionHandler<void(Expected<bool, WebCore::ResourceError>)>&& completionHandler)
{
    completionHandler(makeUnexpected(WebCore::ResourceError { WebCore::ResourceError::Type::General }));
}

void ModelElementController::setIsMutedForModelElement(ModelIdentifier, bool, CompletionHandler<void(bool)>&& completionHandler)
{
    completionHandler(false);
}

#if ENABLE(ARKIT_INLINE_PREVIEW_MAC)
// MAVERICKS_BACKPORT: ARKit/RealityKit remote-preview (the Mac inline-preview path) is unsupportable on
// 10.9; provide no-op impls so WebPageProxy's model message handlers link. The feature is inert.
void ModelElementController::modelElementCreateRemotePreview(String, WebCore::FloatSize, CompletionHandler<void(Expected<std::pair<String, uint32_t>, WebCore::ResourceError>)>&& completionHandler)
{
    completionHandler(makeUnexpected(WebCore::ResourceError { WebCore::ResourceError::Type::General }));
}

void ModelElementController::modelElementLoadRemotePreview(String, URL, CompletionHandler<void(std::optional<WebCore::ResourceError>&&)>&& completionHandler)
{
    completionHandler(WebCore::ResourceError { WebCore::ResourceError::Type::General });
}

void ModelElementController::modelElementDestroyRemotePreview(String)
{
}

void ModelElementController::modelElementSizeDidChange(const String&, WebCore::FloatSize, CompletionHandler<void(Expected<MachSendRight, WebCore::ResourceError>)>&& completionHandler)
{
    completionHandler(makeUnexpected(WebCore::ResourceError { WebCore::ResourceError::Type::General }));
}

void ModelElementController::handleMouseDownForModelElement(const String&, const WebCore::LayoutPoint&, MonotonicTime)
{
}

void ModelElementController::handleMouseMoveForModelElement(const String&, const WebCore::LayoutPoint&, MonotonicTime)
{
}

void ModelElementController::handleMouseUpForModelElement(const String&, const WebCore::LayoutPoint&, MonotonicTime)
{
}

void ModelElementController::inlinePreviewUUIDs(CompletionHandler<void(Vector<String>&&)>&& completionHandler)
{
    completionHandler({ });
}
#endif // ENABLE(ARKIT_INLINE_PREVIEW_MAC)

} // namespace WebKit

#endif // ENABLE(ARKIT_INLINE_PREVIEW)
