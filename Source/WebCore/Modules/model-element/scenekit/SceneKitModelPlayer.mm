/*
 * Copyright (C) 2021-2023 Apple Inc. All rights reserved.
 * Copyright (C) 2025 Samuel Weinig <sam@webkit.org>
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "config.h"

#if HAVE(SCENEKIT)

#import "SceneKitModelPlayer.h"

#import "GraphicsLayer.h"
#import "ModelPlayerGraphicsLayerConfiguration.h"
// MAVERICKS_BACKPORT: SceneKitModel.h / SceneKitModelLoader.h are pure C++ interface headers
// (no SceneKit/Metal import); including them only completes the RefPtr<SceneKitModel> /
// RefPtr<SceneKitModelLoader> member types so this TU can generate their destructors. Neither
// loadSceneKitModel() nor SceneKitModel is ever instantiated, so no 10.11+ framework is touched.
#import "SceneKitModel.h"
#import "SceneKitModelLoader.h"
// MAVERICKS_BACKPORT: no <pal/spi/cocoa/SceneKitSPI.h> / <wtf/cocoa/VectorCocoa.h> imports — the SceneKit
// SPI is absent on 10.9 and the VectorCocoa makeVectorElement helper is unused once the scene path is inert.

// MAVERICKS_BACKPORT: SceneKit + SCNMetalLayer require Metal (10.11+) and the SceneKit
// model-loading SPI, all absent on macOS 10.9. We keep SceneKitModelPlayer::create
// linkable (it returns a non-null Ref) but make it inert: the constructor never allocates
// an SCNMetalLayer or a SceneKit scene, no model is ever loaded, and every ModelPlayer /
// SceneKitModelLoaderClient override is a safe no-op. Nothing in this translation unit
// touches SceneKit, Metal, or the SceneKitModelLoader pipeline at runtime.

namespace WebCore {

Ref<SceneKitModelPlayer> SceneKitModelPlayer::create(ModelPlayerClient& client)
{
    return adoptRef(*new SceneKitModelPlayer(client));
}

SceneKitModelPlayer::SceneKitModelPlayer(ModelPlayerClient& client)
    : m_client { client }
    // MAVERICKS_BACKPORT: no m_layer { [[SCNMetalLayer alloc] init] } initializer — Metal is 10.11+; m_layer stays null.
    , m_id { ModelPlayerIdentifier::generate() }
{
    // MAVERICKS_BACKPORT: do NOT create an SCNMetalLayer here (Metal, 10.11+); leave m_layer null.
}

SceneKitModelPlayer::~SceneKitModelPlayer()
{
    // MAVERICKS_BACKPORT: no loader is ever started, so there is nothing to cancel.
}

// MARK: - ModelPlayer overrides.

ModelPlayerIdentifier SceneKitModelPlayer::identifier() const
{
    return m_id;
}

// MAVERICKS_BACKPORT: params unnamed — SceneKit model loading is unavailable on 10.9, so load() is a no-op.
void SceneKitModelPlayer::load(Model&, LayoutSize)
{
    // MAVERICKS_BACKPORT: SceneKit model loading is unavailable on 10.9; no-op.
}

void SceneKitModelPlayer::sizeDidChange(LayoutSize)
{
}

// MAVERICKS_BACKPORT: params unnamed — m_layer is null (no SCNMetalLayer), so nothing is attached.
void SceneKitModelPlayer::configureGraphicsLayer(GraphicsLayer&, ModelPlayerGraphicsLayerConfiguration&&)
{
    // MAVERICKS_BACKPORT: m_layer is null (no SCNMetalLayer); nothing to attach to the GraphicsLayer.
}

void SceneKitModelPlayer::enterFullscreen()
{
}

void SceneKitModelPlayer::handleMouseDown(const LayoutPoint&, MonotonicTime)
{
}

void SceneKitModelPlayer::handleMouseMove(const LayoutPoint&, MonotonicTime)
{
}

void SceneKitModelPlayer::handleMouseUp(const LayoutPoint&, MonotonicTime)
{
}

void SceneKitModelPlayer::getCamera(CompletionHandler<void(std::optional<HTMLModelElementCamera>&&)>&&)
{
}

void SceneKitModelPlayer::setCamera(HTMLModelElementCamera, CompletionHandler<void(bool success)>&&)
{
}

void SceneKitModelPlayer::isPlayingAnimation(CompletionHandler<void(std::optional<bool>&&)>&&)
{
}

void SceneKitModelPlayer::setAnimationIsPlaying(bool, CompletionHandler<void(bool success)>&&)
{
}

void SceneKitModelPlayer::isLoopingAnimation(CompletionHandler<void(std::optional<bool>&&)>&&)
{
}

void SceneKitModelPlayer::setIsLoopingAnimation(bool, CompletionHandler<void(bool success)>&&)
{
}

void SceneKitModelPlayer::animationDuration(CompletionHandler<void(std::optional<Seconds>&&)>&&)
{
}

void SceneKitModelPlayer::animationCurrentTime(CompletionHandler<void(std::optional<Seconds>&&)>&&)
{
}

void SceneKitModelPlayer::setAnimationCurrentTime(Seconds, CompletionHandler<void(bool success)>&&)
{
}

void SceneKitModelPlayer::hasAudio(CompletionHandler<void(std::optional<bool>&&)>&&)
{
}

void SceneKitModelPlayer::isMuted(CompletionHandler<void(std::optional<bool>&&)>&&)
{
}

void SceneKitModelPlayer::setIsMuted(bool, CompletionHandler<void(bool success)>&&)
{
}

ModelPlayerAccessibilityChildren SceneKitModelPlayer::accessibilityChildren()
{
    // MAVERICKS_BACKPORT: no SceneKit scene exists; return no accessibility children.
    return { };
}

// MARK: - SceneKitModelLoaderClient overrides.

// MAVERICKS_BACKPORT: params unnamed — no loader is ever started, so this callback is unreachable/inert.
void SceneKitModelPlayer::didFinishLoading(SceneKitModelLoader&, Ref<SceneKitModel>)
{
    // MAVERICKS_BACKPORT: no loader is ever started; this is unreachable. Keep it inert.
}

void SceneKitModelPlayer::didFailLoading(SceneKitModelLoader&, const ResourceError&)
{
    // MAVERICKS_BACKPORT: no loader is ever started; this is unreachable. Keep it inert.
}

void SceneKitModelPlayer::updateScene()
{
    // MAVERICKS_BACKPORT: no SCNMetalLayer / SceneKit scene to update.
}

} // namespace WebCore

#endif
