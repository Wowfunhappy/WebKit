/*
 * Copyright (C) 2020 Apple Inc. All rights reserved.
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
#import "ClipboardImageReader.h"

#if PLATFORM(MAC)

#import "Document.h"
// MAVERICKS_BACKPORT: readBuffer below decodes and encodes in WebCore, not in ImageIO.
#import "ImageDecoder.h"
#import "ImageUtilities.h"
#import "SharedBuffer.h"
#import <wtf/cocoa/VectorCocoa.h>

namespace WebCore {

void ClipboardImageReader::readBuffer(const String&, const String&, Ref<SharedBuffer>&& buffer)
{
    if (m_mimeType == "image/png"_s) {
        // MAVERICKS_BACKPORT: upstream's version of the lines below, kept commented rather than
        // deleted so the divergence stays visible in place. These are pasteboard bytes becoming a
        // Blob the page reads, and -[NSImage initWithData:] parses them inside ImageIO; the decode
        // and the re-encode both happen in WebCore here.
        // auto image = adoptNS([[NSImage alloc] initWithData:buffer->createNSData().get()]);
        // if (RetainPtr cgImage = [image CGImageForProposedRect:nil context:nil hints:nil]) {
        //     auto representation = adoptNS([[NSBitmapImageRep alloc] initWithCGImage:cgImage.get()]);
        //     RetainPtr<NSData> nsData = [representation representationUsingType:NSBitmapImageFileTypePNG properties:@{ }];
        //     m_result = Blob::create(m_document.get(), makeVector(nsData.get()), m_mimeType);
        // }
        RefPtr decoder = ImageDecoder::create(buffer.get(), m_mimeType, AlphaOption::Premultiplied, GammaAndColorProfileOption::Applied);
        if (!decoder)
            return;

        decoder->setData(buffer.get(), true);
        RetainPtr platformImage = decoder->createFrameImageAtIndex(decoder->primaryFrameIndex());
        if (!platformImage)
            return;

        auto encoded = encodeData(platformImage.get(), m_mimeType);
        if (encoded.isEmpty())
            return;

        m_result = Blob::create(m_document.get(), WTF::move(encoded), m_mimeType);
    }
}

} // namespace WebCore

#endif // PLATFORM(MAC)
