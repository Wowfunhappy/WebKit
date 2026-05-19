/*
 * Copyright (C) 2012-2024 Apple Inc. All rights reserved.
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

#import "EnvironmentUtilities.h"
#import "WKBase.h"
#import "WebProcess.h"
#import "XPCServiceEntryPoint.h"
#import <fcntl.h>
#import <unistd.h>

#if USE(TZONE_MALLOC)
#import <bmalloc/TZoneHeapManager.h>
#endif

#if PLATFORM(IOS_FAMILY)
#import <WebCore/WebCoreThreadSystemInterface.h>
#import <pal/spi/ios/GraphicsServicesSPI.h>
#endif

extern "C" WK_EXPORT void WEBCONTENT_SERVICE_INITIALIZER(xpc_connection_t connection, xpc_object_t initializerMessage);

static void trace(const char *msg) {
    FILE *f = ((FILE*)0);
    if (f) { fprintf(f, "[PID %d] %s\n", getpid(), msg); fclose(f); }
}

void WEBCONTENT_SERVICE_INITIALIZER(xpc_connection_t connection, xpc_object_t initializerMessage)
{
    // 10.9 backport: redirect stderr to per-pid file so WebContent fprintfs are visible.
    {
        char path[128];
        snprintf(path, sizeof(path), "/tmp/wc-stderr-%d.log", getpid());
        int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0666);
        if (fd >= 0) { dup2(fd, 2); close(fd); }
    }
    trace("WEBCONTENT_SERVICE_INITIALIZER entered");

#if USE(TZONE_MALLOC)
    bmalloc::api::TZoneHeapManager::setBucketParams(4);
#endif
    trace("calling initializeMainThread");
    WTF::initializeMainThread();
    trace("initializeMainThread done");

    WebKit::EnvironmentUtilities::removeValuesEndingWith("DYLD_INSERT_LIBRARIES"_s, "/WebProcessShim.dylib"_s);

    trace("calling XPCServiceInitializer<WebProcess>");
    WebKit::XPCServiceInitializer<WebKit::WebProcess, WebKit::XPCServiceInitializerDelegate, true>(connection, initializerMessage);
    trace("XPCServiceInitializer returned");
}
