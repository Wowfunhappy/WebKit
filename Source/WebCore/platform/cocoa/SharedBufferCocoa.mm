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
    // 10.9: one contiguous NSData segment is sufficient for callers here.
    return @[ makeContiguous()->createNSData().get() ];
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
