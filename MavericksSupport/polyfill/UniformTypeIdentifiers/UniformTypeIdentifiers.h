#ifndef _UTI_H_
#define _UTI_H_
#import <Foundation/Foundation.h>

// UTType polyfill for macOS 10.9 — interface only.
// Implementation is linked from /tmp/libpolyfill.a (polyfill_nsmenu.o).
@interface UTType : NSObject
@property (nullable, copy, readonly) NSString *identifier;
@property (nullable, copy, readonly) NSString *preferredMIMEType;
@property (nullable, copy, readonly) NSString *preferredFilenameExtension;
+ (nullable instancetype)typeWithIdentifier:(NSString *)identifier;
+ (nullable instancetype)typeWithFilenameExtension:(NSString *)ext;
+ (nullable instancetype)typeWithMIMEType:(NSString *)mimeType;
- (BOOL)conformsToType:(UTType *)type;

// Predefined types — class properties matching the modern UniformTypeIdentifiers API.
@property (class, readonly) UTType *item;
@property (class, readonly) UTType *content;
@property (class, readonly) UTType *compositeContent;
@property (class, readonly) UTType *application;
@property (class, readonly) UTType *applicationBundle;
@property (class, readonly) UTType *text;
@property (class, readonly) UTType *plainText;
@property (class, readonly) UTType *utf8PlainText;
@property (class, readonly) UTType *utf16PlainText;
@property (class, readonly) UTType *rtf;
@property (class, readonly) UTType *html;
@property (class, readonly) UTType *xml;
@property (class, readonly) UTType *sourceCode;
@property (class, readonly) UTType *image;
@property (class, readonly) UTType *jpeg;
@property (class, readonly) UTType *tiff;
@property (class, readonly) UTType *gif;
@property (class, readonly) UTType *png;
@property (class, readonly) UTType *icns;
@property (class, readonly) UTType *bmp;
@property (class, readonly) UTType *ico;
@property (class, readonly) UTType *audio;
@property (class, readonly) UTType *video;
@property (class, readonly) UTType *movie;
@property (class, readonly) UTType *mpeg;
@property (class, readonly) UTType *mpeg4Movie;
@property (class, readonly) UTType *mpeg4Audio;
@property (class, readonly) UTType *mp3;
@property (class, readonly) UTType *quickTimeMovie;
@property (class, readonly) UTType *pdf;
@property (class, readonly) UTType *rtfd;
@property (class, readonly) UTType *flatRTFD;
@property (class, readonly) UTType *data;
@property (class, readonly) UTType *directory;
@property (class, readonly) UTType *folder;
@property (class, readonly) UTType *fileURL;
@property (class, readonly) UTType *url;
@property (class, readonly) UTType *vCard;
@property (class, readonly) UTType *webArchive;
@property (class, readonly) UTType *webP;
@property (class, readonly) UTType *heic;
@property (class, readonly) UTType *svg;
@end

// PasteboardMac.mm and others use bare names like UTTypeWebArchive (without
// the UTType. prefix) — alias them to the class properties.
#define UTTypeWebArchive ([UTType webArchive])
#define UTTypeURL ([UTType url])
#define UTTypeFileURL ([UTType fileURL])
#define UTTypePNG ([UTType png])
#define UTTypeJPEG ([UTType jpeg])
#define UTTypeGIF ([UTType gif])
#define UTTypeTIFF ([UTType tiff])
#define UTTypeBMP ([UTType bmp])
#define UTTypePDF ([UTType pdf])
#define UTTypeRTF ([UTType rtf])
#define UTTypeRTFD ([UTType rtfd])
#define UTTypeFlatRTFD ([UTType flatRTFD])
#define UTTypeText ([UTType text])
#define UTTypePlainText ([UTType plainText])
#define UTTypeUTF8PlainText ([UTType utf8PlainText])
#define UTTypeUTF16PlainText ([UTType utf16PlainText])
#define UTTypeHTML ([UTType html])
#define UTTypeXML ([UTType xml])
#define UTTypeImage ([UTType image])
#define UTTypeMovie ([UTType movie])
#define UTTypeAudio ([UTType audio])
#define UTTypeVideo ([UTType video])
#define UTTypeMP3 ([UTType mp3])
#define UTTypeData ([UTType data])
#define UTTypeFolder ([UTType folder])
#define UTTypeDirectory ([UTType directory])
#define UTTypeContent ([UTType content])
#define UTTypeItem ([UTType item])
#define UTTypeApplication ([UTType application])
#define UTTypeWebP ([UTType webP])
#define UTTypeHEIC ([UTType heic])
#define UTTypeSVG ([UTType svg])
#define UTTypeMPEG4Movie ([UTType mpeg4Movie])
#define UTTypeVCard ([UTType vCard])

#endif
