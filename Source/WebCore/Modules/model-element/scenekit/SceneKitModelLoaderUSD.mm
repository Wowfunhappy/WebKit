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

#import "SceneKitModelLoaderUSD.h"

#import "Model.h"
#import "ResourceError.h"
#import "SceneKitModel.h"
#import "SceneKitModelLoader.h"
#import "SceneKitModelLoaderClient.h"
#import <pal/spi/cocoa/SceneKitSPI.h>
#import <wtf/FileHandle.h>
#import <wtf/darwin/DispatchExtras.h>

// MAVERICKS_BACKPORT: soft-link SCNSceneSource rather than hard-referencing the class. SceneKit.framework is
// present on 10.9, but this port records no LC_LOAD_DYLIB for it (see the SceneKit note in the WebCore overlay),
// so a hard `_OBJC_CLASS_$_SCNSceneSource` reference is unresolved at dyld load time and aborts every WebKit
// client at launch. The <model> element is off on this port, so getSCNSceneSourceClass() is never invoked.
#import <wtf/cocoa/SoftLinking.h>
SOFT_LINK_FRAMEWORK_OPTIONAL(SceneKit)
SOFT_LINK_CLASS_OPTIONAL(SceneKit, SCNSceneSource)

namespace WebCore {

class SceneKitModelLoaderUSD final : public SceneKitModelLoader {
public:
    static Ref<SceneKitModelLoaderUSD> create()
    {
        return adoptRef(*new SceneKitModelLoaderUSD());
    }

    virtual ~SceneKitModelLoaderUSD() = default;
    virtual void NODELETE cancel() final { m_canceled = true; }

    bool NODELETE isCanceled() const { return m_canceled; }

private:
    SceneKitModelLoaderUSD()
        : m_canceled { false }
    {
    }

    bool m_canceled;
};

class SceneKitModelUSD final : public SceneKitModel {
public:
    static Ref<SceneKitModelUSD> create(Ref<Model> modelSource, RetainPtr<SCNScene> scene)
    {
        return adoptRef(*new SceneKitModelUSD(WTF::move(modelSource), WTF::move(scene)));
    }

    virtual ~SceneKitModelUSD() = default;

private:
    SceneKitModelUSD(Ref<Model> modelSource, RetainPtr<SCNScene> scene)
        : m_modelSource { WTF::move(modelSource) }
        , m_scene { WTF::move(scene) }
    {
    }

    // SceneKitModel overrides.
    virtual const Model& NODELETE modelSource() const override
    {
        return m_modelSource.get();
    }

    virtual SCNScene *NODELETE defaultScene() const override
    {
        return m_scene.get();
    }

    virtual NSArray<SCNScene *> *scenes() const override
    {
        return @[ m_scene.get() ];
    }

    Ref<Model> m_modelSource;
    RetainPtr<SCNScene> m_scene;
};

static RetainPtr<NSURL> writeToTemporaryFile(WebCore::Model& modelSource)
{
    // FIXME: DO NOT SHIP!!! We must not write these to disk; we need SceneKit
    // to support reading USD files from its [SCNSceneSource initWithData:options:],
    // initializer but currently that does not work.

    auto [filePath, fileHandle] = FileSystem::openTemporaryFile("ModelFile"_s, ".usdz"_s);
    ASSERT(fileHandle);

    auto byteCount = fileHandle.write(modelSource.data()->makeContiguous()->span());
    ASSERT_UNUSED(byteCount, byteCount == modelSource.data()->size());
    fileHandle = { };

    return adoptNS([[NSURL alloc] initFileURLWithPath:filePath.createNSString().get()]);
}

Ref<SceneKitModelLoader> loadSceneKitModelUsingUSDLoader(Model& modelSource, SceneKitModelLoaderClient& client)
{
    auto loader = SceneKitModelLoaderUSD::create();
    
    dispatch_async(mainDispatchQueueSingleton(), [weakClient = WeakPtr { client }, loader, modelSource = Ref { modelSource }] () mutable {
        // If the client has gone away, there is no reason to do any work.
        auto strongClient = weakClient.get();
        if (!strongClient)
            return;

        // If the caller has canceled the load, there is no reason to do any work.
        if (loader->isCanceled())
            return;

        auto url = writeToTemporaryFile(modelSource.get());

        // MAVERICKS_BACKPORT: allocSCNSceneSourceInstance() is the soft-linked SCNSceneSource (SceneKit is
        // soft-linked here — no LC_LOAD_DYLIB for it on this port; <model> is off, so this never runs).
        auto source = adoptNS([allocSCNSceneSourceInstance() initWithURL:url.get() options:nil]);
        NSError *error = nil;
        RetainPtr scene = [source sceneWithOptions:@{ } error:&error];

        if (error) {
            strongClient->didFailLoading(loader.get(), ResourceError(error));
            [error release];
            return;
        }

        ASSERT(scene);

        strongClient->didFinishLoading(loader.get(), SceneKitModelUSD::create(WTF::move(modelSource), WTF::move(scene)));
    });

    return loader;
}

}

#endif
