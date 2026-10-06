// A software H.264 session fed frames without durations, on a presentation clock that started long before
// the session, keeps a usable quantizer after its rate changes. The encoder, property sequence and clock
// origin are libwebrtc's: ExpectedFrameRate 60 then 29 then 30, AverageBitRate 235000 then 600000, and a
// capture clock at 75510506 ms. The encoded samples carry the durations the frames were submitted with:
// none for these, and exactly the stated one for a frame that states it.
#include <CoreFoundation/CoreFoundation.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct Bits { unsigned char d[65536]; unsigned n,pos; };
static unsigned bit(struct Bits*b,int n) { unsigned v=0; assert(n>=0&&n<=32&&b->pos+n<=b->n*8); while(n--) {v=(v<<1)|((b->d[b->pos/8]>>(7-b->pos%8))&1); b->pos++;} return v; }
static unsigned ue(struct Bits*b) {int n=0; while(!bit(b,1)){n++;assert(n<31);} return ((1u<<n)-1)+bit(b,n);}
static int se(struct Bits*b) {unsigned v=ue(b);return (v&1)?(v+1)/2:-(int)(v/2);}
struct SPS {int logframe,poc,logpoc,delta0,frameonly,chroma,separate;};
struct PPS {int sps,entropy,bottom,refs[2],weighted,bipred,qp,redundant;};
struct Parser {struct SPS s[32];struct PPS p[256];};
static void scaling(struct Bits*b,int n){int last=8,next=8;for(int i=0;i<n;i++){if(next)next=(last+se(b)+256)%256;last=next?next:last;}}
static void refmods(struct Bits*b){if(bit(b,1)){unsigned op;do{op=ue(b);if(op==0||op==1||op==2)ue(b);else assert(op==3);}while(op!=3);}}
static int nalqp(struct Parser*p,const unsigned char*d,size_t n,int*idr) {
 struct Bits b={0};int z=0;for(size_t i=1;i<n;i++){if(z==2&&d[i]==3){z=0;continue;}assert(b.n<sizeof(b.d));b.d[b.n++]=d[i];z=d[i]==0?z+1:0;}
 int type=d[0]&31,ref=(d[0]>>5)&3;*idr=0;
 if(type==7){int profile=bit(&b,8);bit(&b,16);unsigned id=ue(&b);assert(id<32);struct SPS*s=&p->s[id];s->chroma=1;
 if(profile==100||profile==110||profile==122||profile==244||profile==44||profile==83||profile==86||profile==118||profile==128){s->chroma=ue(&b);if(s->chroma==3)s->separate=bit(&b,1);assert(ue(&b)==0);assert(ue(&b)==0);bit(&b,1);if(bit(&b,1))for(int i=0;i<(s->chroma==3?12:8);i++)if(bit(&b,1))scaling(&b,i<6?16:64);}
 s->logframe=ue(&b)+4;s->poc=ue(&b);if(s->poc==0)s->logpoc=ue(&b)+4;else if(s->poc==1){s->delta0=bit(&b,1);se(&b);se(&b);unsigned count=ue(&b);while(count--)se(&b);}ue(&b);bit(&b,1);ue(&b);ue(&b);s->frameonly=bit(&b,1);return -1;
 }
 if(type==8){unsigned id=ue(&b);assert(id<256);struct PPS*q=&p->p[id];q->sps=ue(&b);assert(q->sps<32);q->entropy=bit(&b,1);q->bottom=bit(&b,1);assert(ue(&b)==0);q->refs[0]=ue(&b)+1;q->refs[1]=ue(&b)+1;q->weighted=bit(&b,1);q->bipred=bit(&b,2);q->qp=26+se(&b);se(&b);se(&b);bit(&b,1);bit(&b,1);q->redundant=bit(&b,1);return -1;}
 if(type!=1&&type!=5)return -1;
 ue(&b);int st=ue(&b)%5;unsigned pid=ue(&b);assert(pid<256);struct PPS*q=&p->p[pid];struct SPS*s=&p->s[q->sps];if(s->separate)bit(&b,2);bit(&b,s->logframe);int field=0;if(!s->frameonly){field=bit(&b,1);if(field)bit(&b,1);}if(type==5)ue(&b);
 if(s->poc==0){bit(&b,s->logpoc);if(q->bottom&&!field)se(&b);}if(s->poc==1&&!s->delta0){se(&b);if(q->bottom&&!field)se(&b);}if(q->redundant)ue(&b);if(st==1)bit(&b,1);
 int refs[2]={q->refs[0],q->refs[1]};if(st==0||st==1||st==3){if(bit(&b,1)){refs[0]=ue(&b)+1;if(st==1)refs[1]=ue(&b)+1;}}
 if(st!=2&&st!=4){refmods(&b);if(st==1)refmods(&b);}
 if((q->weighted&&(st==0||st==3))||(q->bipred==1&&st==1)){ue(&b);int chroma=s->separate?0:s->chroma;if(chroma)ue(&b);for(int l=0;l<(st==1?2:1);l++)for(int i=0;i<refs[l];i++){if(bit(&b,1)){se(&b);se(&b);}if(chroma&&bit(&b,1))for(int j=0;j<2;j++){se(&b);se(&b);}}}
 if(ref){if(type==5){bit(&b,2);}else if(bit(&b,1)){unsigned op;do{op=ue(&b);if(op==1||op==3)ue(&b);if(op==2)ue(&b);if(op==3||op==6)ue(&b);if(op==4)ue(&b);assert(op<=6);}while(op);}}
 if(q->entropy&&st!=2&&st!=4)ue(&b);int qp=q->qp+se(&b);assert(qp>=0&&qp<=51);*idr=type==5;return qp;
}

enum { frameCount = 150, measuredFrom = 120 };

struct Encoded {
    struct Parser parser;
    double qp[frameCount];
    unsigned slices[frameCount];
    unsigned frames;
    unsigned timedSamples;
};

static void encoded(void *context, void *frame, OSStatus status, VTEncodeInfoFlags flags, CMSampleBufferRef sample)
{
    (void)flags;
    struct Encoded *encoded = context;
    unsigned index = (unsigned)(uintptr_t)frame;
    assert(!status && sample && index < frameCount);
    if (CMTIME_IS_VALID(CMSampleBufferGetDuration(sample)))
        ++encoded->timedSamples;
    // The parameter sets come from the avcC record itself, independent of the CoreMedia accessors.
    CFDictionaryRef atoms = CMFormatDescriptionGetExtension(CMSampleBufferGetFormatDescription(sample), kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms);
    CFDataRef avcC = atoms ? CFDictionaryGetValue(atoms, CFSTR("avcC")) : NULL;
    assert(avcC && CFGetTypeID(avcC) == CFDataGetTypeID());
    const uint8_t *record = CFDataGetBytePtr(avcC);
    size_t recordLength = CFDataGetLength(avcC), offset = 5;
    for (unsigned array = 0; array < 2; ++array) {
        assert(offset < recordLength);
        unsigned count = array ? record[offset] : (record[offset] & 0x1f);
        ++offset;
        for (unsigned i = 0; i < count; ++i) {
            assert(offset + 2 <= recordLength);
            size_t size = ((size_t)record[offset] << 8) | record[offset + 1];
            offset += 2;
            assert(offset + size <= recordLength);
            int idr;
            nalqp(&encoded->parser, record + offset, size, &idr);
            offset += size;
        }
    }
    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
    size_t length = CMBlockBufferGetDataLength(block);
    unsigned char *bytes = malloc(length);
    assert(bytes && !CMBlockBufferCopyDataBytes(block, 0, length, bytes));
    for (size_t offset = 0; offset + 4 <= length;) {
        unsigned nal = ((unsigned)bytes[offset] << 24) | (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3];
        offset += 4;
        assert(offset + nal <= length);
        int idr;
        int qp = nalqp(&encoded->parser, bytes + offset, nal, &idr);
        if (qp >= 0) {
            encoded->qp[index] += qp;
            ++encoded->slices[index];
        }
        offset += nal;
    }
    free(bytes);
    ++encoded->frames;
}

static void setNumber(VTCompressionSessionRef session, CFStringRef key, int value)
{
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberIntType, &value);
    assert(!VTSessionSetProperty(session, key, number));
    CFRelease(number);
}

struct Stated {
    CMTime duration;
    unsigned samples;
    unsigned matching;
};

static void encodedWithStatedDuration(void *context, void *frame, OSStatus status, VTEncodeInfoFlags flags, CMSampleBufferRef sample)
{
    (void)frame;
    (void)flags;
    struct Stated *stated = context;
    assert(!status && sample);
    ++stated->samples;
    if (!CMTimeCompare(CMSampleBufferGetDuration(sample), stated->duration))
        ++stated->matching;
}

static CVPixelBufferRef grayFrame(void)
{
    CVPixelBufferRef image = NULL;
    assert(!CVPixelBufferCreate(NULL, 320, 240, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, NULL, &image));
    assert(!CVPixelBufferLockBaseAddress(image, 0));
    for (size_t plane = 0; plane < 2; ++plane)
        memset(CVPixelBufferGetBaseAddressOfPlane(image, plane), 128, CVPixelBufferGetBytesPerRowOfPlane(image, plane) * CVPixelBufferGetHeightOfPlane(image, plane));
    assert(!CVPixelBufferUnlockBaseAddress(image, 0));
    return image;
}

int main(void)
{
    static struct Encoded result;
    VTCompressionSessionRef session = NULL;
    assert(!VTCompressionSessionCreate(NULL, 320, 240, kCMVideoCodecType_H264, NULL, NULL, NULL, encoded, &result, &session));
    assert(!VTSessionSetProperty(session, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel));
    assert(!VTSessionSetProperty(session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse));
    setNumber(session, kVTCompressionPropertyKey_ExpectedFrameRate, 60);
    setNumber(session, kVTCompressionPropertyKey_AverageBitRate, 235000);
    setNumber(session, kVTCompressionPropertyKey_MaxKeyFrameInterval, 7200);

    const int64_t origin = 75510506;
    uint32_t noise = 12345;
    for (unsigned frame = 0; frame < frameCount; ++frame) {
        if (frame == 1)
            setNumber(session, kVTCompressionPropertyKey_ExpectedFrameRate, 29);
        if (frame == 10)
            setNumber(session, kVTCompressionPropertyKey_ExpectedFrameRate, 30);
        if (frame == 11)
            setNumber(session, kVTCompressionPropertyKey_AverageBitRate, 600000);
        CVPixelBufferRef image = NULL;
        assert(!CVPixelBufferCreate(NULL, 640, 480, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, NULL, &image));
        assert(!CVPixelBufferLockBaseAddress(image, 0));
        for (size_t plane = 0; plane < 2; ++plane) {
            unsigned char *base = CVPixelBufferGetBaseAddressOfPlane(image, plane);
            size_t stride = CVPixelBufferGetBytesPerRowOfPlane(image, plane);
            size_t rows = plane ? 240 : 480;
            for (size_t y = 0; y < rows; ++y) {
                for (size_t x = 0; x < 640; ++x) {
                    noise = noise * 1103515245 + 12345;
                    base[y * stride + x] = plane ? (unsigned char)(128 + ((x + frame * 3) & 31)) : (unsigned char)(((x + y + frame * 4) & 255) / 2 + ((noise >> 16) & 63));
                }
            }
        }
        assert(!CVPixelBufferUnlockBaseAddress(image, 0));
        CMTime presentationTime = CMTimeMake(origin + frame * 1000 / 30, 1000);
        assert(!VTCompressionSessionEncodeFrame(session, image, presentationTime, kCMTimeInvalid, NULL, (void *)(uintptr_t)frame, NULL));
        CVPixelBufferRelease(image);
    }
    assert(!VTCompressionSessionCompleteFrames(session, kCMTimeInvalid));
    VTCompressionSessionInvalidate(session);
    CFRelease(session);

    double qp = 0;
    unsigned slices = 0;
    for (unsigned frame = measuredFrom; frame < frameCount; ++frame) {
        qp += result.qp[frame];
        slices += result.slices[frame];
    }
    int failures = 0;
    if (result.frames != frameCount) {
        printf("FAIL %u of %u frames encoded\n", result.frames, frameCount);
        ++failures;
    }
    if (result.timedSamples) {
        printf("FAIL %u samples of frames submitted without a duration carry one\n", result.timedSamples);
        ++failures;
    }

    static struct Stated stated;
    stated.duration = CMTimeMake(1001, 30000);
    VTCompressionSessionRef statedSession = NULL;
    assert(!VTCompressionSessionCreate(NULL, 320, 240, kCMVideoCodecType_H264, NULL, NULL, NULL, encodedWithStatedDuration, &stated, &statedSession));
    for (unsigned frame = 0; frame < 10; ++frame) {
        CVPixelBufferRef image = grayFrame();
        assert(!VTCompressionSessionEncodeFrame(statedSession, image, CMTimeMake(origin + frame * 1001 / 30, 1000), stated.duration, NULL, NULL, NULL));
        CVPixelBufferRelease(image);
    }
    assert(!VTCompressionSessionCompleteFrames(statedSession, kCMTimeInvalid));
    VTCompressionSessionInvalidate(statedSession);
    CFRelease(statedSession);
    if (stated.samples != 10 || stated.matching != stated.samples) {
        printf("FAIL %u of %u samples keep the stated duration\n", stated.matching, stated.samples);
        ++failures;
    }

    double mean = slices ? qp / slices : 99;
    // libwebrtc's H.264 quality scaler raises resolution while the quantizer stays under 39.
    if (mean >= 39) {
        printf("FAIL mean slice QP %.3f over frames %u-%u after the rate change\n", mean, measuredFrom, frameCount - 1);
        ++failures;
    }
    printf("VideoToolbox encode cadence: mean slice QP %.3f over frames %u-%u, %d failure(s)\n", mean, measuredFrom, frameCount - 1, failures);
    return !!failures;
}
