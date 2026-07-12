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

#import "config.h"
#import "ModelElementController.h"
/* MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
#import <wtf/BlockPtr.h>
#import <wtf/SoftLinking.h>

#if ENABLE(ARKIT_INLINE_PREVIEW)
MAVERICKS_BACKPORT */

// MAVERICKS_BACKPORT: reduced include set for the no-op ModelElementController impls (no ASVInlinePreview/AssetViewer, SoftLinking, or SIMD on 10.9).
#import <WebCore/HTMLModelElementCamera.h>
#import <WebCore/LayoutPoint.h>
/* MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
#import <WebCore/LayoutUnit.h>
MAVERICKS_BACKPORT */
#import <WebCore/ResourceError.h>
// MAVERICKS_BACKPORT: wtf includes the no-op impls need (no BlockPtr/SoftLinking/SIMD/QuartzCore on 10.9).
#import <wtf/CompletionHandler.h>
#import <wtf/Expected.h>
#import <wtf/MachSendRight.h>
/* MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
#import <wtf/MainThread.h>
MAVERICKS_BACKPORT */
#import <wtf/MonotonicTime.h>
// MAVERICKS_BACKPORT: Seconds/URL used by the inert no-op signatures below.
#import <wtf/Seconds.h>
#import <wtf/URL.h>

// MAVERICKS_BACKPORT: ARKit/RealityKit inline preview is unsupportable on 10.9; the bodies below are inert no-ops.
#if ENABLE(ARKIT_INLINE_PREVIEW)

namespace WebKit {

// MAVERICKS_BACKPORT: no-op camera getter (no ASVInlinePreview on 10.9); report general failure.
void ModelElementController::getCameraForModelElement(ModelIdentifier, CompletionHandler<void(Expected<WebCore::HTMLModelElementCamera, WebCore::ResourceError>)>&& completionHandler)
{
    completionHandler(makeUnexpected(WebCore::ResourceError { WebCore::ResourceError::Type::General }));
}

// MAVERICKS_BACKPORT: no-op camera setter (no ASVInlinePreview on 10.9); report failure.
void ModelElementController::setCameraForModelElement(ModelIdentifier, WebCore::HTMLModelElementCamera, CompletionHandler<void(bool)>&& completionHandler)
{
    completionHandler(false);
}

// MAVERICKS_BACKPORT: no-op animation-playing query (inline preview inert on 10.9); report general failure.
void ModelElementController::isPlayingAnimationForModelElement(ModelIdentifier, CompletionHandler<void(Expected<bool, WebCore::ResourceError>)>&& completionHandler)
{
    completionHandler(makeUnexpected(WebCore::ResourceError { WebCore::ResourceError::Type::General }));
}

// MAVERICKS_BACKPORT: no-op set-animation-playing (inline preview inert on 10.9); report failure.
void ModelElementController::setAnimationIsPlayingForModelElement(ModelIdentifier, bool, CompletionHandler<void(bool)>&& completionHandler)
{
    completionHandler(false);
}

// MAVERICKS_BACKPORT: no-op animation-looping query (inline preview inert on 10.9); report general failure.
void ModelElementController::isLoopingAnimationForModelElement(ModelIdentifier, CompletionHandler<void(Expected<bool, WebCore::ResourceError>)>&& completionHandler)
{
    completionHandler(makeUnexpected(WebCore::ResourceError { WebCore::ResourceError::Type::General }));
}

// MAVERICKS_BACKPORT: no-op set-animation-looping (inline preview inert on 10.9); report failure.
void ModelElementController::setIsLoopingAnimationForModelElement(ModelIdentifier, bool, CompletionHandler<void(bool)>&& completionHandler)
{
    completionHandler(false);
}

// MAVERICKS_BACKPORT: no-op animation-duration query (inline preview inert on 10.9); report general failure.
void ModelElementController::animationDurationForModelElement(ModelIdentifier, CompletionHandler<void(Expected<Seconds, WebCore::ResourceError>)>&& completionHandler)
{
    completionHandler(makeUnexpected(WebCore::ResourceError { WebCore::ResourceError::Type::General }));
}

// MAVERICKS_BACKPORT: no-op animation-current-time query (inline preview inert on 10.9); report general failure.
void ModelElementController::animationCurrentTimeForModelElement(ModelIdentifier, CompletionHandler<void(Expected<Seconds, WebCore::ResourceError>)>&& completionHandler)
{
    completionHandler(makeUnexpected(WebCore::ResourceError { WebCore::ResourceError::Type::General }));
}
/* MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
#endif // ENABLE(ARKIT_INLINE_PREVIEW_MAC)

#if ENABLE(ARKIT_INLINE_PREVIEW)
MAVERICKS_BACKPORT */

// MAVERICKS_BACKPORT: no-op set-animation-current-time (inline preview inert on 10.9); report failure.
void ModelElementController::setAnimationCurrentTimeForModelElement(ModelIdentifier, Seconds, CompletionHandler<void(bool)>&& completionHandler)
{
    completionHandler(false);
}

// MAVERICKS_BACKPORT: no-op has-audio query (inline preview inert on 10.9); report general failure.
void ModelElementController::hasAudioForModelElement(ModelIdentifier, CompletionHandler<void(Expected<bool, WebCore::ResourceError>)>&& completionHandler)
{
    completionHandler(makeUnexpected(WebCore::ResourceError { WebCore::ResourceError::Type::General }));
}

// MAVERICKS_BACKPORT: no-op is-muted query (inline preview inert on 10.9); report general failure.
void ModelElementController::isMutedForModelElement(ModelIdentifier, CompletionHandler<void(Expected<bool, WebCore::ResourceError>)>&& completionHandler)
{
    completionHandler(makeUnexpected(WebCore::ResourceError { WebCore::ResourceError::Type::General }));
}

// MAVERICKS_BACKPORT: no-op set-is-muted (inline preview inert on 10.9); report failure.
void ModelElementController::setIsMutedForModelElement(ModelIdentifier, bool, CompletionHandler<void(bool)>&& completionHandler)
{
    completionHandler(false);
}

#if ENABLE(ARKIT_INLINE_PREVIEW_MAC)
// MAVERICKS_BACKPORT: ARKit/RealityKit remote-preview (the Mac inline-preview path) is unsupportable on
// 10.9; provide no-op impls so WebPageProxy's model message handlers link. The feature is inert.
void ModelElementController::modelElementCreateRemotePreview(String, WebCore::FloatSize, CompletionHandler<void(Expected<std::pair<String, uint32_t>, WebCore::ResourceError>)>&& completionHandler)
{
    // MAVERICKS_BACKPORT: no-op remote-preview create (no AssetViewer remote connection on 10.9); report general failure.
    completionHandler(makeUnexpected(WebCore::ResourceError { WebCore::ResourceError::Type::General }));
}

// MAVERICKS_BACKPORT: no-op remote-preview load (no AssetViewer remote connection on 10.9); report general failure.
void ModelElementController::modelElementLoadRemotePreview(String, URL, CompletionHandler<void(std::optional<WebCore::ResourceError>&&)>&& completionHandler)
{
    completionHandler(WebCore::ResourceError { WebCore::ResourceError::Type::General });
}

// MAVERICKS_BACKPORT: no-op remote-preview destroy (no AssetViewer remote connection on 10.9).
void ModelElementController::modelElementDestroyRemotePreview(String)
{
/* MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
    RetainPtr preview = previewForModelIdentifier(modelIdentifier);
    if (!previewHasAnimationSupport(preview.get())) {
        completionHandler(false);
        return;
    }

#if ENABLE(ARKIT_INLINE_PREVIEW_ANIMATIONS_CONTROL)
    preview.get().isLooping = isLooping;
    completionHandler(true);
#else
    ASSERT_NOT_REACHED();
#endif
MAVERICKS_BACKPORT */
}

// MAVERICKS_BACKPORT: no-op size-change (no AssetViewer remote connection on 10.9); report general failure.
void ModelElementController::modelElementSizeDidChange(const String&, WebCore::FloatSize, CompletionHandler<void(Expected<MachSendRight, WebCore::ResourceError>)>&& completionHandler)
{
    completionHandler(makeUnexpected(WebCore::ResourceError { WebCore::ResourceError::Type::General }));
}

// MAVERICKS_BACKPORT: no-op mouse-down forwarding (inline preview inert on 10.9).
void ModelElementController::handleMouseDownForModelElement(const String&, const WebCore::LayoutPoint&, MonotonicTime)
{
/* MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
    RetainPtr preview = previewForModelIdentifier(modelIdentifier);
    if (!previewHasAnimationSupport(preview.get())) {
        completionHandler(makeUnexpected(WebCore::ResourceError { WebCore::ResourceError::Type::General }));
        return;
    }

#if ENABLE(ARKIT_INLINE_PREVIEW_ANIMATIONS_CONTROL)
    completionHandler(Seconds([preview currentTime]));
#else
    ASSERT_NOT_REACHED();
#endif
MAVERICKS_BACKPORT */
}

// MAVERICKS_BACKPORT: no-op mouse-move forwarding (inline preview inert on 10.9).
void ModelElementController::handleMouseMoveForModelElement(const String&, const WebCore::LayoutPoint&, MonotonicTime)
{
/* MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
    RetainPtr preview = previewForModelIdentifier(modelIdentifier);
    if (!previewHasAnimationSupport(preview.get())) {
        completionHandler(false);
        return;
    }

#if ENABLE(ARKIT_INLINE_PREVIEW_ANIMATIONS_CONTROL)
    preview.get().currentTime = currentTime.seconds();
    completionHandler(true);
#else
    ASSERT_NOT_REACHED();
#endif
MAVERICKS_BACKPORT */
}

// MAVERICKS_BACKPORT: no-op mouse-up forwarding (inline preview inert on 10.9).
void ModelElementController::handleMouseUpForModelElement(const String&, const WebCore::LayoutPoint&, MonotonicTime)
{
/* MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
#if ENABLE(ARKIT_INLINE_PREVIEW_AUDIO_CONTROL)
    return [preview respondsToSelector:@selector(hasAudio)];
#else
    return false;
#endif
MAVERICKS_BACKPORT */
}

// MAVERICKS_BACKPORT: no-op preview-UUID enumeration (no inline previews exist on 10.9); report empty.
void ModelElementController::inlinePreviewUUIDs(CompletionHandler<void(Vector<String>&&)>&& completionHandler)
{
    completionHandler({ });
}
// MAVERICKS_BACKPORT: end of the inert no-op Mac inline-preview impls (ARKit/RealityKit absent on 10.9).
#endif // ENABLE(ARKIT_INLINE_PREVIEW_MAC)

} // namespace WebKit

#endif // ENABLE(ARKIT_INLINE_PREVIEW)
