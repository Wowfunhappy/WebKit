#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#include <unistd.h>

static NSAppleEventDescriptor *documentSpecifier(int32_t identifier)
{
    NSAppleEventDescriptor *specifier = [NSAppleEventDescriptor recordDescriptor];
    [specifier setDescriptor:[NSAppleEventDescriptor descriptorWithTypeCode:cDocument] forKeyword:keyAEDesiredClass];
    [specifier setDescriptor:[NSAppleEventDescriptor nullDescriptor] forKeyword:keyAEContainer];
    [specifier setDescriptor:[NSAppleEventDescriptor descriptorWithEnumCode:formUniqueID] forKeyword:keyAEKeyForm];
    [specifier setDescriptor:[NSAppleEventDescriptor descriptorWithInt32:identifier] forKeyword:keyAEKeyData];
    return [specifier coerceToDescriptorType:typeObjectSpecifier];
}

static void record(NSDictionary *entry)
{
    NSString *path = [[[[NSBundle mainBundle] bundlePath] stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"media-receiver.jsonl"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path])
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
    NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:path];
    [file seekToEndOfFile];
    [file writeData:[NSJSONSerialization dataWithJSONObject:entry options:0 error:NULL]];
    [file writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [file closeFile];
}

@interface MediaHandoffReceiver : NSObject
@property NSString *url;
@property NSTimeInterval opened;
@property NSTimeInterval launched;
@property NSTimeInterval updated;
@property double position;
@property double rate;
@property int32_t identifier;
@property BOOL delayedQuery;
- (void)handleURL:(NSAppleEventDescriptor *)event reply:(NSAppleEventDescriptor *)reply;
- (void)handlePlayer:(NSAppleEventDescriptor *)event reply:(NSAppleEventDescriptor *)reply;
@end
@implementation MediaHandoffReceiver
- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
        self.launched = [NSDate timeIntervalSinceReferenceDate];
        [[NSAppleEventManager sharedAppleEventManager] setEventHandler:self andSelector:@selector(handleURL:reply:) forEventClass:kInternetEventClass andEventID:kAEGetURL];
        for (NSNumber *command in @[@(kAEGetData), @(kAESetData), @(kAEClose)])
            [[NSAppleEventManager sharedAppleEventManager] setEventHandler:self andSelector:@selector(handlePlayer:reply:) forEventClass:kAECoreSuite andEventID:command.unsignedIntValue];
        [[NSAppleEventManager sharedAppleEventManager] setEventHandler:self andSelector:@selector(handlePlayer:reply:) forEventClass:kCoreEventClass andEventID:kAEOpenDocuments];
        for (NSNumber *command in @[@((AEEventID)'play'), @((AEEventID)'paus')])
            [[NSAppleEventManager sharedAppleEventManager] setEventHandler:self andSelector:@selector(handlePlayer:reply:) forEventClass:'test' andEventID:command.unsignedIntValue];
        record(@{ @"pid": @(getpid()), @"ready": @YES });
}
- (void)handleURL:(NSAppleEventDescriptor *)event reply:(NSAppleEventDescriptor *)reply
{
    NSString *url = [[event paramDescriptorForKeyword:keyDirectObject] stringValue];
    record(@{ @"pid": @(getpid()), @"url": url ?: @"" });
}
- (NSDictionary *)control
{
    NSString *parent = [[[NSBundle mainBundle] bundlePath] stringByDeletingLastPathComponent];
    NSData *data = [NSData dataWithContentsOfFile:[parent stringByAppendingPathComponent:@"media-receiver-control.json"]];
    return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : @{};
}
- (void)handlePlayer:(NSAppleEventDescriptor *)event reply:(NSAppleEventDescriptor *)reply
{
    NSDictionary *control = [self control];
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    self.position += self.rate * (now - self.updated);
    self.updated = now;
    if ([control[@"closed"] boolValue])
        self.url = nil;
    AEEventID command = event.eventID;
    NSAppleEventDescriptor *object = [event paramDescriptorForKeyword:keyDirectObject];
    DescType property = [object descriptorForKeyword:keyAEKeyData].typeCodeValue;
    if (command == kAEOpenDocuments) {
        NSAppleEventDescriptor *file = [object descriptorAtIndex:1];
        self.url = [[NSString alloc] initWithData:file.data encoding:NSUTF8StringEncoding];
        self.identifier++;
        self.position = self.rate = 0;
        self.opened = now;
        record(@{ @"open": self.url ?: @"", @"id": @(self.identifier) });
        [reply setParamDescriptor:documentSpecifier(self.identifier) forKeyword:keyDirectObject];
        return;
    }
    if (command == kAEGetData) {
        NSAppleEventDescriptor *value = nil;
        if (property == pID) {
            if (!self.delayedQuery && [control[@"querySleep"] doubleValue] > 0) {
                self.delayedQuery = YES;
                record(@{ @"querySleeping": @YES });
                [NSThread sleepForTimeInterval:[control[@"querySleep"] doubleValue]];
            }
            if (now - self.launched < [control[@"queryAfter"] doubleValue]) {
                record(@{ @"queryNotReady": @YES });
                [reply setParamDescriptor:[NSAppleEventDescriptor descriptorWithInt32:errAEEventNotHandled] forKeyword:keyErrorNumber];
                return;
            }
            value = [NSAppleEventDescriptor listDescriptor];
            if (self.url && ![control[@"omitWindowList"] boolValue])
                [value insertDescriptor:[NSAppleEventDescriptor descriptorWithInt32:self.identifier] atIndex:1];
        } else if (property == 'docu')
            value = self.url && ![control[@"documentMissing"] boolValue] ? documentSpecifier(self.identifier) : [NSAppleEventDescriptor descriptorWithTypeCode:cMissingValue];
        else if (property == 'file') {
            if ([control[@"documentMissing"] boolValue] || [control[@"missingFile"] boolValue] || now - self.opened < [control[@"fileAfter"] doubleValue])
                value = [NSAppleEventDescriptor descriptorWithTypeCode:cMissingValue];
            else if (self.url)
                value = [NSAppleEventDescriptor descriptorWithDescriptorType:typeFileURL data:[self.url dataUsingEncoding:NSUTF8StringEncoding]];
        } else if (property == 'time' || property == 'durn' || property == 'rate') {
            double number = property == 'time' ? self.position : property == 'durn' ? 3600 : self.rate;
            value = [NSAppleEventDescriptor descriptorWithDescriptorType:typeIEEE64BitFloatingPoint bytes:&number length:sizeof(number)];
        }
        if (value)
            [reply setParamDescriptor:value forKeyword:keyDirectObject];
        else
            [reply setParamDescriptor:[NSAppleEventDescriptor descriptorWithInt32:errAENoSuchObject] forKeyword:keyErrorNumber];
        return;
    }
    if (command == kAEClose) {
        record(@{ @"close": self.url ?: @"" });
        self.url = nil;
        return;
    }
    if (now - self.opened < [control[@"readyAfter"] doubleValue]) {
        record(@{ @"notReady": @(command) });
        [reply setParamDescriptor:[NSAppleEventDescriptor descriptorWithInt32:errAEEventNotHandled] forKeyword:keyErrorNumber];
        return;
    }
    if (command == kAESetData) {
        NSAppleEventDescriptor *number = [[event paramDescriptorForKeyword:keyAEData] coerceToDescriptorType:typeIEEE64BitFloatingPoint];
        double value = 0;
        if (AEGetDescData(number.aeDesc, &value, sizeof(value)) != noErr) {
            [reply setParamDescriptor:[NSAppleEventDescriptor descriptorWithInt32:errAEWrongDataType] forKeyword:keyErrorNumber];
            return;
        }
        if (property == 'time') self.position = value;
        if (property == 'rate') self.rate = value;
    } else if (command == 'play')
        self.rate = 1;
    else if (command == 'paus')
        self.rate = 0;
}
@end

int main(void)
{
    @autoreleasepool {
        NSApplication *application = [NSApplication sharedApplication];
        MediaHandoffReceiver *receiver = [MediaHandoffReceiver new];
        receiver.updated = [NSDate timeIntervalSinceReferenceDate];
        application.delegate = (id<NSApplicationDelegate>)receiver;
        [application run];
    }
    return 0;
}
