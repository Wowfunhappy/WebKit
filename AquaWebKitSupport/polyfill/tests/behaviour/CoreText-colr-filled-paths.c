#include <CoreText/CoreText.h>
#include <CoreGraphics/CoreGraphics.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(int argc,char** argv)
{
    assert(argc==2);
    CGDataProviderRef provider=CGDataProviderCreateWithFilename(argv[1]);assert(provider);
    CGFontRef cgFont=CGFontCreateWithDataProvider(provider);assert(cgFont);
    CTFontRef font=CTFontCreateWithGraphicsFont(cgFont,100,NULL,NULL);assert(font);
    UniChar text[]={'B','A','B'};CGGlyph glyphs[3];assert(CTFontGetGlyphsForCharacters(font,text,glyphs,3));
    CGPoint positions[]={{0,0},{100,0},{200,0}};
    CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    unsigned failures=0;
    for(unsigned scale=1;scale<=2;++scale)for(unsigned variant=0;variant<3;++variant)for(unsigned translucent=0;translucent<2;++translucent)for(unsigned shadow=0;shadow<2;++shadow){
        size_t side=400*scale,bytes=side*side*4;
        unsigned char* a=calloc(1,bytes);unsigned char* b=calloc(1,bytes);assert(a&&b);
        CGContextRef actual=CGBitmapContextCreate(a,side,side,8,side*4,space,kCGImageAlphaPremultipliedLast);
        CGContextRef expected=CGBitmapContextCreate(b,side,side,8,side*4,space,kCGImageAlphaPremultipliedLast);assert(actual&&expected);
        CGContextRef contexts[]={actual,expected};
        for(unsigned c=0;c<2;++c){
            CGContextScaleCTM(contexts[c],scale,scale);CGContextTranslateCTM(contexts[c],40,140);
            CGAffineTransform matrix=variant==0?CGAffineTransformIdentity:variant==1?CGAffineTransformMake(1,0,0,-1,0,0):CGAffineTransformMake(0,1,-1,0,100,-80);
            CGContextSetTextMatrix(contexts[c],matrix);
            if(c)CGContextConcatCTM(contexts[c],matrix);
            CGContextSetAlpha(contexts[c],translucent?0.5:1);
            CGContextSetRGBStrokeColor(contexts[c],0,0.5,0,1);CGContextSetLineWidth(contexts[c],2);
            CGContextSetTextDrawingMode(contexts[c],kCGTextStroke);
            if(shadow){CGFloat components[]={0,0,0,0.5};CGColorRef color=CGColorCreate(space,components);CGContextSetShadowWithColor(contexts[c],CGSizeMake(4,-3),2,color);CGColorRelease(color);}
        }
        CTFontDrawGlyphs(font,glyphs,positions,3,actual);
        CGContextStrokeRect(expected,CGRectMake(0,-20,100,100));
        CGContextBeginTransparencyLayer(expected,NULL);
        CGContextSetRGBFillColor(expected,1,0,1,1);CGContextFillRect(expected,CGRectMake(100,-20,100,100));
        CGContextSetRGBFillColor(expected,0,1,1,1);CGContextFillRect(expected,CGRectMake(120,-20,20,100));
        CGContextEndTransparencyLayer(expected);
        CGContextStrokeRect(expected,CGRectMake(200,-20,100,100));
        unsigned different=0,max=0;
        for(size_t i=0;i<bytes;++i){unsigned delta=abs(a[i]-b[i]);different+=delta!=0;if(delta>max)max=delta;}
        printf("COLR stroke scale%u matrix%u alpha%u shadow%u differences%u max%u\n",scale,variant,translucent,shadow,different,max);failures+=max>0;
        CGContextRelease(actual);CGContextRelease(expected);free(a);free(b);
    }
    CGColorSpaceRelease(space);CFRelease(font);CGFontRelease(cgFont);CGDataProviderRelease(provider);
    return failures!=0;
}
