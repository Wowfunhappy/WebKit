/*
 * Copyright (C) 2011 Google, Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY GOOGLE INC. ``AS IS'' AND ANY
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

#include "config.h"
#include "FrameDestructionObserver.h"

#include "LocalFrame.h"

namespace WebCore {

FrameDestructionObserver::FrameDestructionObserver(LocalFrame* frame)
    : m_frame(nullptr)
{
    observeFrame(frame);
}

FrameDestructionObserver::~FrameDestructionObserver()
{
    observeFrame(nullptr);
}

void FrameDestructionObserver::observeFrame(LocalFrame* frame)
{
    if (m_frame)
        m_frame->removeDestructionObserver(*this);

    m_frame = frame;

    if (m_frame)
        m_frame->addDestructionObserver(*this);
}

void FrameDestructionObserver::frameDestroyed()
{
    m_frame = nullptr;
}

// MAVERICKS_BACKPORT: out-of-line definition. frame() is declared non-inline in the header (the inline
// keyword was removed to avoid -Wundefined-inline under the new SDK). Its only definition used to be the
// `inline` one in FrameDestructionObserverInlines.h, which emits NO out-of-line symbol — so callers that
// include only FrameDestructionObserver.h (e.g. JSWindowProxy.cpp's cross-tab window-proxy check) crashed
// at runtime with a dyld lazy-bind failure (Symbol not found: WebCore::FrameDestructionObserver::frame()).
LocalFrame* FrameDestructionObserver::frame() const
{
    return m_frame.get();
}

void FrameDestructionObserver::willDetachPage()
{
    // Subclasses should override this function to handle this notification.
}

}
