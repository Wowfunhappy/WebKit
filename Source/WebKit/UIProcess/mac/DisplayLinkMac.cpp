/*
 * Copyright (C) 2018-2022 Apple Inc. All rights reserved.
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

#include "config.h"
#include "DisplayLink.h"

#if HAVE(DISPLAY_LINK)

#include "Logging.h"
#include <wtf/ProcessPrivilege.h>
#include <wtf/text/TextStream.h>

namespace WebKit {

using namespace WebCore;

// MAVERICKS_BACKPORT: the dispatch timer's event handler (runs on a global high-priority queue,
// i.e. off the main thread, which notifyObserversDisplayDidRefresh() asserts).
void DisplayLink::displayLinkTimerFired(void* context)
{
    // MAVERICKS_BACKPORT: dispatch-timer tick drives the refresh notification in place of the CVDisplayLink output callback.
    static_cast<DisplayLink*>(context)->notifyObserversDisplayDidRefresh();
}

void DisplayLink::platformInitialize()
{
    // MAVERICKS_BACKPORT: CVDisplayLink is unusable in this VM. CoreVideo logs
    // "CVCGDisplayLink::setCurrentDisplay didn't find a valid display - falling back to 60Hz"
    // (the VM has no real display to vsync against) and the output callback then fires at well
    // under 1 Hz. Because the WebProcess gates EVERY rendering update on DisplayDidRefresh
    // (m_waitingForBackingStoreSwap), that throttles the entire pipeline — requestAnimationFrame,
    // IntersectionObserver-driven lazy loading, <iframe>/image reveal, and compositing all crawl.
    // Drive notifyObserversDisplayDidRefresh() from a real dispatch timer at the nominal rate
    // instead of the dead hardware vsync. We don't even create a CVDisplayLink (avoids the
    // WindowServer round-trip and the error spam); the VM display is 60Hz.
    m_displayNominalFramesPerSecond = WebCore::FullSpeedFramesPerSecond;

    auto queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0);
    m_timer = adoptOSObject(dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue));
    if (!m_timer) {
        RELEASE_LOG_FAULT(DisplayLink, "DisplayLink: Could not create the refresh timer for display %u", m_displayID);
        return;
    }

    // MAVERICKS_BACKPORT: program the dispatch timer at the nominal refresh interval (replaces
    // CVDisplayLink vsync). First fire is one interval after resume, matching vsync semantics —
    // an immediate fire would race the unsynchronized m_currentUpdate reset in addObserver().
    uint64_t intervalNanos = NSEC_PER_SEC / m_displayNominalFramesPerSecond;
    dispatch_source_set_timer(m_timer.get(), dispatch_time(DISPATCH_TIME_NOW, intervalNanos), intervalNanos, intervalNanos / 10);
    // The DisplayLink owns m_timer and cancels it in platformFinalize before destruction, so the
    // raw `this` context is safe (the handler runs off the main thread, as the assert in
    // notifyObserversDisplayDidRefresh() requires). Use the function-pointer form rather than a
    // block since this is a plain .cpp.
    dispatch_set_context(m_timer.get(), this);
    dispatch_source_set_event_handler_f(m_timer.get(), displayLinkTimerFired);
    // dispatch sources are created suspended; platformStart() resumes.
}

void DisplayLink::platformFinalize()
{
    // MAVERICKS_BACKPORT: tear down the dispatch refresh timer that replaces CVDisplayLink on this port.
    if (m_timer) {
        // Cancel BEFORE resuming: a cancelled source delivers no further events, so the
        // never-started case (timer created suspended, no observer ever added) cannot fire one
        // last tick into notifyObserversDisplayDidRefresh() with the default m_currentUpdate.
        // The resume is still required — releasing a suspended dispatch source aborts.
        dispatch_source_cancel(m_timer.get());
        if (!m_timerRunning) {
            dispatch_resume(m_timer.get());
            m_timerRunning = true;
        }
        m_timer = nullptr;
    }

    // MAVERICKS_BACKPORT: a CVDisplayLink is never created on this port, but stop/release it defensively if one exists.
    if (m_displayLink) {
ALLOW_DEPRECATED_DECLARATIONS_BEGIN
        CVDisplayLinkStop(m_displayLink.get());
ALLOW_DEPRECATED_DECLARATIONS_END
        m_displayLink = nullptr; // MAVERICKS_BACKPORT: defensive CVDisplayLink release (none is created on this port).
    }
}

FramesPerSecond DisplayLink::nominalFramesPerSecondFromDisplayLink(CVDisplayLinkRef displayLink)
{
ALLOW_DEPRECATED_DECLARATIONS_BEGIN
    CVTime refreshPeriod = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(displayLink);
ALLOW_DEPRECATED_DECLARATIONS_END
    if (!refreshPeriod.timeValue)
        return FullSpeedFramesPerSecond;

    FramesPerSecond result = round((double)refreshPeriod.timeScale / (double)refreshPeriod.timeValue);
    return result ?: FullSpeedFramesPerSecond;
}

bool DisplayLink::platformIsRunning() const
{
    // MAVERICKS_BACKPORT: running state tracks the dispatch refresh timer (no CVDisplayLink on this port).
    return m_timerRunning;
}

void DisplayLink::platformStart()
{
    // MAVERICKS_BACKPORT: start = resume the dispatch refresh timer (no CVDisplayLink on this port).
    if (!m_timer || m_timerRunning)
        return;
    dispatch_resume(m_timer.get());
    m_timerRunning = true;
}

void DisplayLink::platformStop()
{
    // MAVERICKS_BACKPORT: stop = suspend the dispatch refresh timer (no CVDisplayLink on this port).
    if (!m_timer || !m_timerRunning)
        return;
    // Safe to call from within the timer's own event handler (the no-observers auto-stop path):
    // dispatch_suspend takes effect after the current handler block returns.
    dispatch_suspend(m_timer.get());
    m_timerRunning = false;
}

CVReturn DisplayLink::displayLinkCallback(CVDisplayLinkRef displayLinkRef, const CVTimeStamp*, const CVTimeStamp*, CVOptionFlags, CVOptionFlags*, void* data)
{
    static_cast<DisplayLink*>(data)->notifyObserversDisplayDidRefresh();
    return kCVReturnSuccess;
}

} // namespace WebKit

#endif // HAVE(DISPLAY_LINK)
