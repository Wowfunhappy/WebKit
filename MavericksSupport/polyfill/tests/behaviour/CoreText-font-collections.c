#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>

typedef const struct __FPFont* FPFontRef;
extern CFArrayRef FPFontCreateFontsFromData(CFDataRef);
extern CFArrayRef FPFontCreateMemorySafeFontsFromData(CFDataRef);
extern CFStringRef FPFontCopyPostScriptName(FPFontRef);
extern CFDataRef FPFontCopySFNTData(FPFontRef);
extern bool wk_font_is_ots_sanitized(CFDataRef);

int main(int argc,char** argv)
{
    assert(argc==2);
    const char* names[]={"fast/text/resources/collection.ttc","fast/text/resources/collection2.ttc","resources/Ahem.ttf"};
    CFArrayRef (*parsers[])(CFDataRef)={FPFontCreateFontsFromData,FPFontCreateMemorySafeFontsFromData};
    for(unsigned test=0;test<3;++test)for(unsigned parser=0;parser<2;++parser) {
        char path[4096];assert(snprintf(path,sizeof(path),"%s/%s",argv[1],names[test])<(int)sizeof(path));
        CGDataProviderRef provider=CGDataProviderCreateWithFilename(path);assert(provider);
        CFDataRef input=CGDataProviderCopyData(provider);assert(input);
        CFArrayRef fonts=parsers[parser](input);assert(fonts);
        // Each collection's second face, Ahemerator, is one OTS refuses (its cmap names glyph 277 of 276),
        // so the parsers keep only the face OTS accepts.
        assert(CFArrayGetCount(fonts)==1);
        CFDataRef first=NULL;
        for(CFIndex i=0;i<CFArrayGetCount(fonts);++i) {
            FPFontRef font=(FPFontRef)CFArrayGetValueAtIndex(fonts,i);
            CFStringRef name=FPFontCopyPostScriptName(font);assert(name);
            assert(CFEqual(name,i?CFSTR("Ahemerator"):CFSTR("Ahem")));
            CFDataRef data=FPFontCopySFNTData(font);assert(data);
            assert(CFDataGetLength(data)>=12&&memcmp(CFDataGetBytePtr(data),"ttcf",4));
            assert(wk_font_is_ots_sanitized(data));
            if(i)assert(!CFEqual(data,first));
            else first=(CFDataRef)CFRetain(data);
            CFRelease(data);CFRelease(name);
        }
        if(first)CFRelease(first);
        CFRelease(fonts);CFRelease(input);CGDataProviderRelease(provider);
        printf("PASS: %s parser%u accepted faces and standalone sfnt identity\n",names[test],parser);
    }
}
