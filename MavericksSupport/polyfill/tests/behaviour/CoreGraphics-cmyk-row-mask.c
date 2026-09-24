// Native CMYK partial-row coverage with normal profiled JPEG fixtures.
#include <stdio.h>
#include <jpeglib.h>
#include <png.h>
#include <CoreGraphics/CoreGraphics.h>
#include <assert.h>
#include <stdlib.h>
#include <IOSurface/IOSurface.h>
CGContextRef CGIOSurfaceContextCreate(IOSurfaceRef, size_t, size_t, size_t, size_t, CGColorSpaceRef, CGBitmapInfo);
enum { kSide = 4 };
static IOSurfaceRef createSurface(void)
{
    int side = kSide, bytesPerRow = kSide * 4, bytesPerElement = 4;
    unsigned format = 'BGRA';
    CFMutableDictionaryRef properties = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFNumberRef numbers[] = {
        CFNumberCreate(NULL, kCFNumberIntType, &side), CFNumberCreate(NULL, kCFNumberIntType, &side),
        CFNumberCreate(NULL, kCFNumberIntType, &bytesPerRow), CFNumberCreate(NULL, kCFNumberIntType, &bytesPerElement),
        CFNumberCreate(NULL, kCFNumberIntType, &format),
    };
    const void *keys[] = { kIOSurfaceWidth, kIOSurfaceHeight, kIOSurfaceBytesPerRow, kIOSurfaceBytesPerElement, kIOSurfacePixelFormat };
    for (size_t i = 0; i < sizeof keys / sizeof *keys; i++) {
        CFDictionarySetValue(properties, keys[i], numbers[i]);
        CFRelease(numbers[i]);
    }
    IOSurfaceRef surface = IOSurfaceCreate(properties);
    CFRelease(properties);
    return surface;
}







static CGColorSpaceRef pngProfile(const char* path)
{
    FILE* input=fopen(path,"rb");assert(input);
    png_structp png=png_create_read_struct(PNG_LIBPNG_VER_STRING,NULL,NULL,NULL);
    png_infop info=png_create_info_struct(png);assert(png&&info);
    assert(!setjmp(png_jmpbuf(png)));
    png_init_io(png,input);png_read_info(png,info);
    char* name;unsigned char* bytes;png_uint_32 length;int compression;
    assert(png_get_iCCP(png,info,&name,&compression,&bytes,&length));
    CFDataRef data=CFDataCreate(NULL,bytes,length);
    CGColorSpaceRef space=CGColorSpaceCreateWithICCProfile(data);assert(space);
    CFRelease(data);png_destroy_read_struct(&png,&info,NULL);fclose(input);
    return space;
}
extern CGPatternRef CGPatternCreateWithImage2(CGImageRef, CGAffineTransform, CGPatternTiling);

static void checkIOSurfacePattern(CGImageRef image, CGColorSpaceRef *spaces) {
 unsigned char expected[2][4] = { { 0 }, { 0 } };
 for (unsigned c = 0; c < 2; ++c) {
  CGContextRef bitmap = CGBitmapContextCreate(expected[c], 1, 1, 8, 4, spaces[c], kCGImageAlphaPremultipliedLast);
  assert(bitmap);
  CGContextDrawImage(bitmap, CGRectMake(0, 0, 1, 1), image);
  CGContextRelease(bitmap);
 }
 CGColorSpaceRef patternSpace=CGColorSpaceCreatePattern(NULL);
 for(unsigned fresh=0;fresh<2;++fresh) for(unsigned route=0;route<3;++route) for(unsigned c=0;c<2;++c) {
  CGImageRef sample=fresh?CGImageCreateCopy(image):CGImageRetain(image);
  IOSurfaceRef surface=createSurface();
  CGContextRef context=CGIOSurfaceContextCreate(surface,4,4,8,32,spaces[c],kCGImageAlphaPremultipliedFirst|kCGBitmapByteOrder32Little);
  assert(context);
  if(!route) CGContextDrawImage(context,CGRectMake(0,0,4,4),sample);
  else if(route==1) CGContextDrawTiledImage(context,CGRectMake(0,0,4,4),sample);
  else {
   CGFloat alpha=1;CGPatternRef pattern=CGPatternCreateWithImage2(sample,CGAffineTransformIdentity,kCGPatternTilingConstantSpacing);
   CGContextSetFillColorSpace(context,patternSpace);CGContextSetFillPattern(context,pattern,&alpha);CGContextFillRect(context,CGRectMake(0,0,4,4));CGPatternRelease(pattern);
  }
  CGContextFlush(context);IOSurfaceLock(surface,kIOSurfaceLockReadOnly,NULL);
  unsigned char *p=IOSurfaceGetBaseAddress(surface);
  printf("\nIOSurface fresh%u route%u %s=%u,%u,%u,%u",fresh,route,c?"P3":"sRGB",p[2],p[1],p[0],p[3]);
  assert(abs((int)p[2] - expected[c][0]) <= 1);
  assert(abs((int)p[1] - expected[c][1]) <= 1);
  assert(abs((int)p[0] - expected[c][2]) <= 1);
  assert(p[3] == expected[c][3]);
  IOSurfaceUnlock(surface,kIOSurfaceLockReadOnly,NULL);CGContextRelease(context);CFRelease(surface);CGImageRelease(sample);
 }
 CGColorSpaceRelease(patternSpace);
}

int main(int argc,char** argv)
{
    assert(argc>2);
    CGColorSpaceRef spaces[]={CGColorSpaceCreateWithName(kCGColorSpaceSRGB),pngProfile(argv[1])};
    for(int i=2;i<argc;++i) {
        FILE* input=fopen(argv[i],"rb");assert(input);
        struct jpeg_decompress_struct info;
        struct jpeg_error_mgr error;
        info.err=jpeg_std_error(&error);jpeg_create_decompress(&info);
        jpeg_stdio_src(&info,input);jpeg_save_markers(&info,JPEG_APP0+2,0xffff);
        assert(jpeg_read_header(&info,TRUE)==JPEG_HEADER_OK);
        unsigned char* profile=NULL;unsigned profileSize=0;
        assert(jpeg_read_icc_profile(&info,&profile,&profileSize));
        CFDataRef data=CFDataCreate(NULL,profile,profileSize);free(profile);
        CGColorSpaceRef source=CGColorSpaceCreateWithICCProfile(data);CFRelease(data);assert(source);
        assert(CGColorSpaceGetModel(source)==kCGColorSpaceModelCMYK);
        info.out_color_space=JCS_CMYK;jpeg_start_decompress(&info);
        size_t width=info.output_width,height=info.output_height,stride=width*4;
        unsigned char* pixels=malloc(stride*height);assert(pixels);
        while(info.output_scanline<height) {
            JSAMPROW row=pixels+info.output_scanline*stride;
            assert(jpeg_read_scanlines(&info,&row,1)==1);
        }
        printf("%s raw %u,%u,%u,%u adobe%d",argv[i],pixels[0],pixels[1],pixels[2],pixels[3],info.saw_Adobe_marker);
        CFDataRef pixelData=CFDataCreate(NULL,pixels,stride*height);free(pixels);
        CGDataProviderRef provider=CGDataProviderCreateWithCFData(pixelData);CFRelease(pixelData);
        const CGFloat inverted[]={1,0,1,0,1,0,1,0};
        CGImageRef image=CGImageCreate(width,height,8,32,stride,source,kCGImageAlphaNone,provider,info.saw_Adobe_marker?inverted:NULL,false,kCGRenderingIntentDefault);assert(image);
        unsigned char coverage[]={0,255};
        CGDataProviderRef coverageProvider=CGDataProviderCreateWithData(NULL,coverage,sizeof(coverage),NULL);
        CGImageRef mask=CGImageMaskCreate(1,2,8,8,1,coverageProvider,NULL,false);assert(mask);
        CGImageRef partial=CGImageCreateWithMask(image,mask);
        printf(" CMYK mask image %s",partial?"created":"unavailable");
        assert(partial);
        for(unsigned c=0;c<2;++c) {
            unsigned char fullPixels[8*8*4]={0},partialPixels[sizeof(fullPixels)]={0};
            CGContextRef fullContext=CGBitmapContextCreate(fullPixels,8,8,8,8*4,spaces[c],kCGImageAlphaPremultipliedLast);
            CGContextRef partialContext=CGBitmapContextCreate(partialPixels,8,8,8,8*4,spaces[c],kCGImageAlphaPremultipliedLast);
            assert(fullContext&&partialContext);
            CGContextDrawImage(fullContext,CGRectMake(0,0,8,8),image);
            CGContextDrawImage(partialContext,CGRectMake(0,0,8,8),partial);
            unsigned opaque=0,transparent=0,translucent=0,maxDifference=0;
            for(unsigned p=0;p<64;++p) {
                unsigned alpha=partialPixels[4*p+3];
                opaque+=alpha==255;transparent+=alpha==0;
                translucent+=alpha>0&&alpha<255;
                for(unsigned channel=0;channel<3;++channel) {
                    unsigned expected=(fullPixels[4*p+channel]*alpha+127)/255;
                    unsigned difference=abs((int)partialPixels[4*p+channel]-(int)expected);
                    if(difference>maxDifference)maxDifference=difference;
                }
            }
            assert(opaque&&transparent&&maxDifference<=1);
            printf(" %s partial=%uopaque/%utransparent/%utranslucent max%u",c?"P3":"sRGB",opaque,transparent,translucent,maxDifference);
            CGContextRelease(fullContext);CGContextRelease(partialContext);
        }
        CGImageRelease(partial);CGImageRelease(mask);CGDataProviderRelease(coverageProvider);
        for(unsigned c=0;c<2;++c) {
            unsigned char pixel[4]={0};
            CGContextRef context=CGBitmapContextCreate(pixel,1,1,8,4,spaces[c],kCGImageAlphaPremultipliedLast);assert(context);
            CGContextDrawImage(context,CGRectMake(0,0,1,1),image);
            printf(" %s=%u,%u,%u,%u",c?"P3":"sRGB",pixel[0],pixel[1],pixel[2],pixel[3]);
            CGContextRelease(context);
        }
        checkIOSurfacePattern(image, spaces);
        puts("");CGImageRelease(image);CGDataProviderRelease(provider);CGColorSpaceRelease(source);
        jpeg_finish_decompress(&info);jpeg_destroy_decompress(&info);fclose(input);
    }
    CGColorSpaceRelease(spaces[0]);CGColorSpaceRelease(spaces[1]);
}
