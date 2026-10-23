#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Carbon/Carbon.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static NSAppleEventDescriptor* object(DescType type, NSAppleEventDescriptor* container, DescType form, NSAppleEventDescriptor* key)
{
    NSAppleEventDescriptor* value = [NSAppleEventDescriptor recordDescriptor];
    [value setDescriptor:[NSAppleEventDescriptor descriptorWithTypeCode:type] forKeyword:keyAEDesiredClass];
    [value setDescriptor:container ?: [NSAppleEventDescriptor nullDescriptor] forKeyword:keyAEContainer];
    [value setDescriptor:[NSAppleEventDescriptor descriptorWithEnumCode:form] forKeyword:keyAEKeyForm];
    [value setDescriptor:key forKeyword:keyAEKeyData];
    return [value coerceToDescriptorType:typeObjectSpecifier];
}

int main(int argc, char** argv)
{
    if (argc != 3)
        return 2;
    if (!strcmp(argv[1], "--url")) {
        @autoreleasepool {
            NSRunningApplication* application = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.QuickTimePlayerX"].firstObject;
            if (!application) return 3;
            pid_t pid = application.processIdentifier;
            NSAppleEventDescriptor* window = object(cWindow, nil, formUniqueID, [NSAppleEventDescriptor descriptorWithInt32:atoi(argv[2])]);
            NSAppleEventDescriptor* document = object(typeProperty, window, formPropertyID, [NSAppleEventDescriptor descriptorWithTypeCode:'docu']);
            NSAppleEventDescriptor* file = object(typeProperty, document, formPropertyID, [NSAppleEventDescriptor descriptorWithTypeCode:'file']);
            NSAppleEventDescriptor* target = [NSAppleEventDescriptor descriptorWithDescriptorType:typeKernelProcessID bytes:&pid length:sizeof(pid)];
            NSAppleEventDescriptor* event = [NSAppleEventDescriptor appleEventWithEventClass:kAECoreSuite eventID:kAEGetData targetDescriptor:target returnID:kAutoGenerateReturnID transactionID:kAnyTransactionID];
            [event setParamDescriptor:file forKeyword:keyDirectObject];
            AppleEvent reply = { typeNull, NULL };
            OSStatus error = AESendMessage(event.aeDesc, &reply, kAEWaitReply | kAENeverInteract, 60);
            NSAppleEventDescriptor* result = [[NSAppleEventDescriptor alloc] initWithAEDescNoCopy:&reply];
            NSAppleEventDescriptor* url = [result paramDescriptorForKeyword:keyDirectObject];
            if (error || [result paramDescriptorForKeyword:keyErrorNumber].int32Value || url.descriptorType != typeFileURL) return 4;
            fwrite(url.data.bytes, 1, url.data.length, stdout);
            putchar('\n');
            return 0;
        }
    }
    CGWindowID window = (CGWindowID)strtoul(argv[1], NULL, 10);
    unsigned seconds = (unsigned)strtoul(argv[2], NULL, 10);
    unsigned char* previous = NULL;
    size_t previousWidth = 0, previousHeight = 0;
    unsigned changes = 0, comparisons = 0;
    for (unsigned elapsed = 0; elapsed <= seconds; elapsed += 5) {
        @autoreleasepool {
            CGImageRef image = CGWindowListCreateImage(CGRectNull, kCGWindowListOptionIncludingWindow, window, kCGWindowImageBoundsIgnoreFraming);
            if (!image)
                return 3;
            size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
            unsigned char* pixels = calloc(height, width * 4);
            CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
            CGContextRef context = CGBitmapContextCreate(pixels, width, height, 8, width * 4, space, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
            CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
            if (previous && previousWidth == width && previousHeight == height) {
                unsigned long changed = 0, samples = 0;
                double difference = 0;
                for (size_t y = height / 4; y < height * 3 / 4; y += 2) {
                    for (size_t x = width / 4; x < width * 3 / 4; x += 2) {
                        size_t offset = (y * width + x) * 4;
                        unsigned delta = 0;
                        for (unsigned c = 0; c < 3; ++c)
                            delta += abs((int)pixels[offset + c] - previous[offset + c]);
                        changed += delta != 0;
                        difference += delta;
                        ++samples;
                    }
                }
                ++comparisons;
                changes += changed != 0;
                printf("FRAME elapsed=%u changed=%lu/%lu meanDifference=%.6f\n", elapsed, changed, samples, difference / (samples * 3));
            } else
                printf("FRAME baseline elapsed=%u size=%zux%zu\n", elapsed, width, height);
            fflush(stdout);
            free(previous);
            previous = pixels;
            previousWidth = width;
            previousHeight = height;
            CGContextRelease(context);
            CGColorSpaceRelease(space);
            CGImageRelease(image);
        }
        if (elapsed + 5 <= seconds)
            [NSThread sleepForTimeInterval:5];
    }
    free(previous);
    printf("VIDEO comparisons=%u changingIntervals=%u\n", comparisons, changes);
    return comparisons && changes == comparisons ? 0 : 1;
}
