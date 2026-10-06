// Exercise repeated one-shot socket watch removal/reinstallation while bytes remain readable.
#import <Foundation/Foundation.h>
#import <CoreFoundation/CFFileDescriptor.h>
#import <CoreFoundation/CFSocket.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <cstdio>
#include <cstring>

struct ReadinessProbe {
    int descriptor;
    bool useSocket;
    size_t received { 0 };
    bool exact { true };
    CFSocketRef socket { nullptr };
    CFFileDescriptorRef fileDescriptor { nullptr };
    CFRunLoopSourceRef source { nullptr };
    static constexpr size_t length = 8 * 1024 * 1024;

    void disarm()
    {
        if (source) { CFRunLoopSourceInvalidate(source); CFRelease(source); source = nullptr; }
        if (socket) { CFSocketInvalidate(socket); CFRelease(socket); socket = nullptr; }
        if (fileDescriptor) { CFFileDescriptorInvalidate(fileDescriptor); CFRelease(fileDescriptor); fileDescriptor = nullptr; }
    }

    void read()
    {
        unsigned char data[4096];
        ssize_t size = ::read(descriptor, data, sizeof(data));
        if (size <= 0) { exact = false; CFRunLoopStop(CFRunLoopGetMain()); return; }
        for (ssize_t i = 0; i < size; ++i)
            exact &= data[i] == static_cast<unsigned char>(received + i);
        received += size;
        disarm();
        if (received == length) { CFRunLoopStop(CFRunLoopGetMain()); return; }
        CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{ arm(); });
    }

    void arm()
    {
        if (useSocket) {
            CFSocketContext context { 0, this, nullptr, nullptr, nullptr };
            socket = CFSocketCreateWithNative(nullptr, descriptor, kCFSocketReadCallBack, [](CFSocketRef, CFSocketCallBackType, CFDataRef, const void*, void* p) { static_cast<ReadinessProbe*>(p)->read(); }, &context);
            CFSocketSetSocketFlags(socket, CFSocketGetSocketFlags(socket) & ~(kCFSocketCloseOnInvalidate | kCFSocketAutomaticallyReenableReadCallBack));
            source = CFSocketCreateRunLoopSource(nullptr, socket, 0);
            CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
            CFSocketEnableCallBacks(socket, kCFSocketReadCallBack);
        } else {
            CFFileDescriptorContext context { 0, this, nullptr, nullptr, nullptr };
            fileDescriptor = CFFileDescriptorCreate(nullptr, descriptor, false, [](CFFileDescriptorRef, CFOptionFlags, void* p) { static_cast<ReadinessProbe*>(p)->read(); }, &context);
            source = CFFileDescriptorCreateRunLoopSource(nullptr, fileDescriptor, 0);
            CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
            CFFileDescriptorEnableCallBacks(fileDescriptor, kCFFileDescriptorReadCallBack);
        }
    }
};

int main(int argc, char** argv)
{
    if (argc != 2) return 2;
    int sockets[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sockets)) return 2;
    ReadinessProbe probe;
    probe.descriptor = sockets[0];
    probe.useSocket = !strcmp(argv[1], "socket");
    int writer = sockets[1];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        unsigned char body[4096];
        for (size_t i = 0; i < sizeof(body); ++i) body[i] = static_cast<unsigned char>(i);
        size_t written = 0;
        while (written < ReadinessProbe::length) {
            ssize_t size = write(writer, body + written % sizeof(body), sizeof(body) - written % sizeof(body));
            if (size <= 0) return;
            written += size;
        }
    });
    probe.arm();
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 10, false);
    int pending = 0;
    ioctl(sockets[0], FIONREAD, &pending);
    bool passed = probe.received == ReadinessProbe::length && probe.exact;
    printf("%s received=%lu expected=%lu pending=%d exact=%d %s\n", argv[1], probe.received, ReadinessProbe::length, pending, probe.exact, passed ? "PASS" : "FAIL");
    probe.disarm();
    return passed ? 0 : 1;
}
