// 10.9 backport: minimal Cocoa SharedBuffer overloads.
// SharedBuffer::create(NSData*), createCFData, createNSData are declared as
// WEBCORE_EXPORT but the upstream implementations live in a code path that
// doesn't build cleanly here. Without these, callers bind to the return-zero
// weak fallback stub, which yields a CFData/NSData with a corrupted class
// pointer (xorl-zeros only the low 32 bits of the 8-byte pointer return).
// CG / ImageIO / CoreText then crash deep inside objc_msgSend when sending
// `retain` / `bytes` to that bogus object.

#import "config.h"
#import "SharedBuffer.h"

#import <CoreFoundation/CoreFoundation.h>
#import <pal/cf/CoreMediaSoftLink.h>

namespace WebCore {

Ref<SharedBuffer> SharedBuffer::create(NSData* data)
{
    return SharedBuffer::create(reinterpret_cast<CFDataRef>(data));
}

void SharedBuffer::DataSegment::iterate(CFDataRef data, NOESCAPE const Function<void(std::span<const uint8_t>)>& apply) const
{
    // Simple, single-region iteration. CFDataGetBytePtr returns a contiguous pointer
    // to the data, and CFDataGetLength returns its size. This is sufficient for the
    // CFData instances created from NSData on 10.9.
    if (!data)
        return;
    CFIndex length = CFDataGetLength(data);
    const UInt8* bytes = CFDataGetBytePtr(data);
    if (!bytes || length <= 0)
        return;
    apply(std::span<const uint8_t> { bytes, static_cast<size_t>(length) });
}

RetainPtr<CFDataRef> SharedBuffer::createCFData() const
{
    auto contig = span();
    return adoptCF(CFDataCreate(kCFAllocatorDefault, contig.data(), contig.size()));
}

RetainPtr<NSData> SharedBuffer::createNSData() const
{
    return (__bridge_transfer NSData *)createCFData().leakRef();
}

RetainPtr<NSArray> FragmentedSharedBuffer::createNSDataArray() const
{
    // Wrap each existing segment's bytes BY REFERENCE (no copy), keeping the segment alive for the
    // NSData's lifetime via the deallocator block.
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

// Wrap the buffer's bytes in a CMBlockBuffer (used by toCMSampleBuffer to build CMSampleBuffers for
// the MSE pipeline). The block buffer owns a copy of the data, so its lifetime is independent of this
// SharedBuffer. CMBlockBuffer* are CoreMedia (10.7+), available on 10.9.
RetainPtr<CMBlockBufferRef> FragmentedSharedBuffer::createCMBlockBuffer() const
{
    auto contiguousBuffer = makeContiguous();
    auto contiguous = contiguousBuffer->span();
    if (contiguous.empty())
        return nullptr;
    CMBlockBufferRef blockBuffer = nullptr;
    if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, nullptr, contiguous.size(), kCFAllocatorDefault, nullptr, 0, contiguous.size(), kCMBlockBufferAssureMemoryNowFlag, &blockBuffer) != noErr || !blockBuffer)
        return nullptr;
    if (CMBlockBufferReplaceDataBytes(contiguous.data(), blockBuffer, 0, contiguous.size()) != noErr) {
        CFRelease(blockBuffer);
        return nullptr;
    }
    return adoptCF(blockBuffer);
}

}
