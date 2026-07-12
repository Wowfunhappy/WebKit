// MAVERICKS_BACKPORT: minimal Cocoa SharedBuffer overloads.
// SharedBuffer::create(NSData*), createCFData, createNSData are declared as
// WEBCORE_EXPORT but the upstream implementations live in a code path that
// doesn't build cleanly here. Without these, callers bind to the return-zero
// weak fallback stub, which yields a CFData/NSData with a corrupted class
// pointer (xorl-zeros only the low 32 bits of the 8-byte pointer return).
// CG / ImageIO / CoreText then crash deep inside objc_msgSend when sending
// `retain` / `bytes` to that bogus object.

#import "config.h"
#import "SharedBuffer.h"

// MAVERICKS_BACKPORT: CoreFoundation/CoreMedia are the only dependencies of this minimal reimplementation.
#import <CoreFoundation/CoreFoundation.h>
#import <pal/cf/CoreMediaSoftLink.h>

// MAVERICKS_BACKPORT: minimal Cocoa SharedBuffer reimplementation (see file header) lives in this namespace.
namespace WebCore {

// MAVERICKS_BACKPORT: minimal Cocoa overload replacing the return-zero fallback stub (see file header).
Ref<SharedBuffer> SharedBuffer::create(NSData* data)
{
    return SharedBuffer::create(reinterpret_cast<CFDataRef>(data));
}

// MAVERICKS_BACKPORT: CFData-based segment iteration replacing the upstream NSData enumerateByteRanges path.
void SharedBuffer::DataSegment::iterate(CFDataRef data, NOESCAPE const Function<void(std::span<const uint8_t>)>& apply) const
{
    // MAVERICKS_BACKPORT: simple, single-region iteration. CFDataGetBytePtr returns a contiguous pointer
    // to the data, and CFDataGetLength returns its size. This is sufficient for the
    // CFData instances created from NSData on 10.9.
    if (!data)
        return;
    // MAVERICKS_BACKPORT: read the contiguous CFData region directly on 10.9.
    CFIndex length = CFDataGetLength(data);
    const UInt8* bytes = CFDataGetBytePtr(data);
    if (!bytes || length <= 0)
        return;
    apply(std::span<const uint8_t> { bytes, static_cast<size_t>(length) });
}

// MAVERICKS_BACKPORT: minimal Cocoa overload replacing the return-zero fallback stub (see file header).
RetainPtr<CFDataRef> SharedBuffer::createCFData() const
{
    auto contig = span();
    return adoptCF(CFDataCreate(kCFAllocatorDefault, contig.data(), contig.size()));
}

// MAVERICKS_BACKPORT: minimal Cocoa overload replacing the return-zero fallback stub (see file header).
RetainPtr<NSData> SharedBuffer::createNSData() const
{
    return (__bridge_transfer NSData *)createCFData().leakRef();
}

// MAVERICKS_BACKPORT: by-reference NSData segment wrapping (see comment below) replacing the upstream copy-per-segment path.
RetainPtr<NSArray> FragmentedSharedBuffer::createNSDataArray() const
{
    // MAVERICKS_BACKPORT: wrap each existing segment's bytes BY REFERENCE (no copy), keeping the segment
    // alive for the NSData's lifetime via the deallocator block.
    //
    // The previous implementation returned `makeContiguous()->createNSData()`, i.e. a fresh contiguous
    // *copy of the entire buffer* on every call. The AVFoundation media loader calls this on each
    // received network chunk of a continuously-growing buffer (see
    // WebCoreAVFResourceLoader::newDataStoredInSharedBuffer), so that copied O(n^2) bytes and -- because
    // AVFoundation's -[AVAssetResourceLoadingDataRequest respondWithData:] retains what it is handed --
    // accumulated gigabytes of ~1MB CFData copies for a streamed/looping <video> (e.g. the many
    // auto-playing previews on a news front page rendered full-height inside a Web Clip). Wrapping the
    // segments by reference both removes the per-call copy and lets the data be released normally.
    RetainPtr<NSMutableArray> array = adoptNS([[NSMutableArray alloc] initWithCapacity:m_segments.size()]);
    for (auto& entry : m_segments) {
        RefPtr<const DataSegment> protectedSegment = entry.segment.ptr();
        auto bytes = protectedSegment->span();
        if (bytes.empty())
            continue;
        RetainPtr<NSData> data = adoptNS([[NSData alloc] initWithBytesNoCopy:const_cast<uint8_t*>(bytes.data())
            length:bytes.size()
            deallocator:^(void*, NSUInteger) { (void)protectedSegment; /* keeps the segment alive */ }]);
        [array addObject:data.get()];
    }
    return array;
}

RetainPtr<CMBlockBufferRef> FragmentedSharedBuffer::createCMBlockBuffer() const
{
// MAVERICKS_BACKPORT: wrap the buffer's bytes in a CMBlockBuffer (used by toCMSampleBuffer to build
// CMSampleBuffers for the MSE pipeline). The block buffer owns a copy of the data, so its lifetime is
// independent of this SharedBuffer. CMBlockBuffer* are CoreMedia (10.7+), available on 10.9.
    // MAVERICKS_BACKPORT: contiguous-copy CMBlockBuffer (see comment above) replacing the upstream segment-wrapping path.
    auto contiguousBuffer = makeContiguous();
    auto contiguous = contiguousBuffer->span();
    if (contiguous.empty())
        return nullptr;
    CMBlockBufferRef blockBuffer = nullptr;
    if (PAL::CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, nullptr, contiguous.size(), kCFAllocatorDefault, nullptr, 0, contiguous.size(), kCMBlockBufferAssureMemoryNowFlag, &blockBuffer) != noErr || !blockBuffer)
        return nullptr;
    if (PAL::CMBlockBufferReplaceDataBytes(contiguous.data(), blockBuffer, 0, contiguous.size()) != noErr) {
        CFRelease(blockBuffer);
        return nullptr;
/* MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
    auto blockBuffer = adoptCF(rawBlockBuffer);

    if (isEmpty())
        return blockBuffer;

    for (auto& segment : m_segments) {
        if (!segment.segment->size())
            continue;
        auto partialBuffer = segmentToCMBlockBuffer(segment.segment);
        if (!partialBuffer)
            return nullptr;
        if (PAL::CMBlockBufferAppendBufferReference(rawBlockBuffer, partialBuffer.get(), 0, 0, 0) != kCMBlockBufferNoErr)
            return nullptr;
MAVERICKS_BACKPORT */
    }
    // MAVERICKS_BACKPORT: CMBlockBuffer built from a contiguous copy (see comment above) for 10.9.
    return adoptCF(blockBuffer);
}

// MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
// RetainPtr<NSArray> FragmentedSharedBuffer::createNSDataArray() const
// {
//     return createNSArray(segments(), [] (auto& segment) {
//         return segment.segment->createNSData();
//     });
// (end MAVERICKS_BACKPORT restored block)
}
/* MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport

RetainPtr<NSData> DataSegment::createNSData() const
{
    return adoptNS([[WebCoreSharedBufferData alloc] initWithDataSegment:*this position:0 size:size()]);
}

void DataSegment::iterate(CFDataRef data, NOESCAPE const Function<void(std::span<const uint8_t>)>& apply) const
{
    [(__bridge NSData *)data enumerateByteRangesUsingBlock:^(const void *bytes, NSRange byteRange, BOOL *) {
        apply(unsafeMakeSpan(static_cast<const uint8_t*>(bytes), byteRange.length));
    }];
}

RetainPtr<NSData> SharedBufferDataView::createNSData() const
{
    return adoptNS([[WebCoreSharedBufferData alloc] initWithDataSegment:m_segment.get() position:m_positionWithinSegment size:size()]);
}

} // namespace WebCore
MAVERICKS_BACKPORT */
