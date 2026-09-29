// LinkPresentation: stubs of the LinkPresentation data-model classes. 10.9 ships no
// LinkPresentation.framework at all, so every class here is registered with WK_POLYFILL_CLASS and the
// dlopen of the framework path is answered with the layer's absent-provider token.
//
// WKShareSheet describes what navigator.share() hands the share picker with these: an LPLinkMetadata
// for a shared URL, and one specialized with an LPFileMetadata for each shared file. They are value
// objects -- properties set by their creator and read back by the picker -- copied and archived whole.
#import "wk_priv_class.h"
#import <Foundation/Foundation.h>

@class NSItemProvider;

WK_PRIV_CLASS(LPSpecializationMetadata) @interface LPSpecializationMetadata : NSObject <NSSecureCoding, NSCopying>
@end

@implementation LPSpecializationMetadata

+ (BOOL)supportsSecureCoding
{
    return YES;
}

- (id)initWithCoder:(NSCoder *)coder
{
    return [super init];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
}

- (id)copyWithZone:(NSZone *)zone
{
    return [[[self class] allocWithZone:zone] init];
}

@end
WK_PRIV_ALIAS(LPSpecializationMetadata);
WK_POLYFILL_CLASS("LinkPresentation", LPSpecializationMetadata);

WK_PRIV_CLASS(LPFileMetadata) @interface LPFileMetadata : LPSpecializationMetadata {
    NSString *_name;
    NSString *_type;
    uint64_t _size;
}
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *type;
@property (nonatomic, assign) uint64_t size;
@end

@implementation LPFileMetadata

+ (BOOL)supportsSecureCoding
{
    return YES;
}

- (id)initWithCoder:(NSCoder *)coder
{
    if (!(self = [super initWithCoder:coder]))
        return nil;
    _name = [[coder decodeObjectOfClass:[NSString class] forKey:@"name"] copy];
    _type = [[coder decodeObjectOfClass:[NSString class] forKey:@"type"] copy];
    _size = (uint64_t)[coder decodeInt64ForKey:@"size"];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    [coder encodeObject:_name forKey:@"name"];
    [coder encodeObject:_type forKey:@"type"];
    [coder encodeInt64:(int64_t)_size forKey:@"size"];
}

- (id)copyWithZone:(NSZone *)zone
{
    LPFileMetadata *copy = [super copyWithZone:zone];
    copy->_name = [_name copy];
    copy->_type = [_type copy];
    copy->_size = _size;
    return copy;
}

- (void)dealloc
{
    [_name release];
    [_type release];
    [super dealloc];
}

- (NSString *)name { return _name; }
- (void)setName:(NSString *)name
{
    NSString *old = _name;
    _name = [name copy];
    [old release];
}

- (NSString *)type { return _type; }
- (void)setType:(NSString *)type
{
    NSString *old = _type;
    _type = [type copy];
    [old release];
}

- (uint64_t)size { return _size; }
- (void)setSize:(uint64_t)size { _size = size; }

@end
WK_PRIV_ALIAS(LPFileMetadata);
WK_POLYFILL_CLASS("LinkPresentation", LPFileMetadata);

// NSItemProvider is not archivable, so an archive carries the URLs, title, specialization and
// incompleteness; a copy shares the artwork providers.
WK_PRIV_CLASS(LPLinkMetadata) @interface LPLinkMetadata : NSObject <NSSecureCoding, NSCopying> {
    NSURL *_originalURL;
    NSURL *_URL;
    NSString *_title;
    NSItemProvider *_iconProvider;
    NSItemProvider *_imageProvider;
    NSItemProvider *_videoProvider;
    NSURL *_remoteVideoURL;
    LPSpecializationMetadata *_specialization;
    BOOL _incomplete;
}
@property (nonatomic, retain) NSURL *originalURL;
@property (nonatomic, retain) NSURL *URL;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, retain) NSItemProvider *iconProvider;
@property (nonatomic, retain) NSItemProvider *imageProvider;
@property (nonatomic, retain) NSItemProvider *videoProvider;
@property (nonatomic, retain) NSURL *remoteVideoURL;
@property (nonatomic, copy) LPSpecializationMetadata *specialization;
- (void)_setIncomplete:(BOOL)incomplete;
@end

@implementation LPLinkMetadata

+ (BOOL)supportsSecureCoding
{
    return YES;
}

- (id)initWithCoder:(NSCoder *)coder
{
    if (!(self = [super init]))
        return nil;
    _originalURL = [[coder decodeObjectOfClass:[NSURL class] forKey:@"originalURL"] retain];
    _URL = [[coder decodeObjectOfClass:[NSURL class] forKey:@"URL"] retain];
    _title = [[coder decodeObjectOfClass:[NSString class] forKey:@"title"] copy];
    _remoteVideoURL = [[coder decodeObjectOfClass:[NSURL class] forKey:@"remoteVideoURL"] retain];
    _specialization = [[coder decodeObjectOfClass:[LPSpecializationMetadata class] forKey:@"specialization"] retain];
    _incomplete = [coder decodeBoolForKey:@"incomplete"];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_originalURL forKey:@"originalURL"];
    [coder encodeObject:_URL forKey:@"URL"];
    [coder encodeObject:_title forKey:@"title"];
    [coder encodeObject:_remoteVideoURL forKey:@"remoteVideoURL"];
    [coder encodeObject:_specialization forKey:@"specialization"];
    [coder encodeBool:_incomplete forKey:@"incomplete"];
}

- (id)copyWithZone:(NSZone *)zone
{
    LPLinkMetadata *copy = [[[self class] allocWithZone:zone] init];
    copy->_originalURL = [_originalURL retain];
    copy->_URL = [_URL retain];
    copy->_title = [_title copy];
    copy->_iconProvider = [_iconProvider retain];
    copy->_imageProvider = [_imageProvider retain];
    copy->_videoProvider = [_videoProvider retain];
    copy->_remoteVideoURL = [_remoteVideoURL retain];
    copy->_specialization = [_specialization copy];
    copy->_incomplete = _incomplete;
    return copy;
}

- (void)dealloc
{
    [_originalURL release];
    [_URL release];
    [_title release];
    [_iconProvider release];
    [_imageProvider release];
    [_videoProvider release];
    [_remoteVideoURL release];
    [_specialization release];
    [super dealloc];
}

#define WK_RETAIN_SETTER(ivar, value) do { id old = ivar; ivar = [value retain]; [old release]; } while (0)
#define WK_COPY_SETTER(ivar, value) do { id old = ivar; ivar = [value copy]; [old release]; } while (0)

- (NSURL *)originalURL { return _originalURL; }
- (void)setOriginalURL:(NSURL *)originalURL { WK_RETAIN_SETTER(_originalURL, originalURL); }
- (NSURL *)URL { return _URL; }
- (void)setURL:(NSURL *)URL { WK_RETAIN_SETTER(_URL, URL); }
- (NSString *)title { return _title; }
- (void)setTitle:(NSString *)title { WK_COPY_SETTER(_title, title); }
- (NSItemProvider *)iconProvider { return _iconProvider; }
- (void)setIconProvider:(NSItemProvider *)iconProvider { WK_RETAIN_SETTER(_iconProvider, iconProvider); }
- (NSItemProvider *)imageProvider { return _imageProvider; }
- (void)setImageProvider:(NSItemProvider *)imageProvider { WK_RETAIN_SETTER(_imageProvider, imageProvider); }
- (NSItemProvider *)videoProvider { return _videoProvider; }
- (void)setVideoProvider:(NSItemProvider *)videoProvider { WK_RETAIN_SETTER(_videoProvider, videoProvider); }
- (NSURL *)remoteVideoURL { return _remoteVideoURL; }
- (void)setRemoteVideoURL:(NSURL *)remoteVideoURL { WK_RETAIN_SETTER(_remoteVideoURL, remoteVideoURL); }
- (LPSpecializationMetadata *)specialization { return _specialization; }
- (void)setSpecialization:(LPSpecializationMetadata *)specialization { WK_COPY_SETTER(_specialization, specialization); }
- (void)_setIncomplete:(BOOL)incomplete { _incomplete = incomplete; }

#undef WK_RETAIN_SETTER
#undef WK_COPY_SETTER

@end
WK_PRIV_ALIAS(LPLinkMetadata);
WK_POLYFILL_CLASS("LinkPresentation", LPLinkMetadata);
