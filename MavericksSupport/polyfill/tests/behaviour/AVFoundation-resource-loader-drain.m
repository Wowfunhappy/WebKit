// The AVAssetReader polyfill (methods/AVFoundation.m + avf-resource-loader-drain.h): a reader built
// over an asset served by a resource loader delegate reads it, whoever the delegate is and whenever it
// answers. A delegate that answers on its own thread is served as well as one that answers inline, a
// delegate that declines leaves the caller with what 10.9 would have given it, and a track taken from
// the asset the caller asked to read is accepted by the reader.

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <stdio.h>

static int failures;

static void check(const char *what, long got, long want)
{
    bool ok = got == want;
    printf("  %-52s %-10ld %s\n", what, got, ok ? "ok" : "FAIL");
    if (!ok) {
        printf("  %-52s expected %ld\n", "", want);
        ++failures;
    }
}

// Answers on its own thread, after the delegate call has already returned.
@interface WKAsyncLoader : NSObject <AVAssetResourceLoaderDelegate> {
    NSData *_data;
    NSString *_type;
}
@end

@implementation WKAsyncLoader
- (id)initWithData:(NSData *)data type:(NSString *)type
{
    if (!(self = [super init]))
        return nil;
    _data = [data retain];
    _type = [type retain];
    return self;
}
- (BOOL)resourceLoader:(AVAssetResourceLoader *)loader shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)request
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 40ull * NSEC_PER_MSEC), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (request.contentInformationRequest) {
            request.contentInformationRequest.contentType = _type;
            request.contentInformationRequest.contentLength = _data.length;
            request.contentInformationRequest.byteRangeAccessSupported = YES;
        }
        if (request.dataRequest) {
            long long offset = request.dataRequest.requestedOffset;
            long long available = (long long)_data.length - offset;
            if (available > 0) {
                long long wanted = MIN(available, (long long)request.dataRequest.requestedLength);
                [request.dataRequest respondWithData:[_data subdataWithRange:NSMakeRange((NSUInteger)offset, (NSUInteger)wanted)]];
            }
        }
        [request finishLoading];
    });
    return YES;
}
@end

// Answers nothing: the resource is not available.
@interface WKDecliningLoader : NSObject <AVAssetResourceLoaderDelegate>
@end

@implementation WKDecliningLoader
- (BOOL)resourceLoader:(AVAssetResourceLoader *)loader shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)request
{
    [request finishLoadingWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorResourceUnavailable userInfo:nil]];
    return YES;
}
@end

static AVURLAsset *assetServedBy(id delegate)
{
    AVURLAsset *asset = [[AVURLAsset alloc] initWithURL:[NSURL URLWithString:@"wk-probe://audio"]
        options:@{ AVURLAssetPreferPreciseDurationAndTimingKey: @YES }];
    [[asset resourceLoader] setDelegate:delegate queue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)];
    return asset;
}

static long framesReadThrough(AVURLAsset *asset)
{
    NSArray *tracks = [asset tracksWithMediaType:AVMediaTypeAudio];
    if (!tracks.count)
        return -1;
    NSError *error = nil;
    AVAssetReader *reader = nil;
    @try {
        reader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
    } @catch (NSException *exception) {
        printf("  -[AVAssetReader initWithAsset:error:] raised: %s\n", exception.reason.UTF8String);
        return -2;
    }
    if (!reader)
        return -3;
    // The track came from the asset the caller asked to read, not from the reader's own asset.
    AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc] initWithTrack:tracks[0] outputSettings:nil];
    output.alwaysCopiesSampleData = NO;
    if (![reader canAddOutput:output])
        return -4;
    [reader addOutput:output];
    if (![reader startReading])
        return -5;
    long frames = 0;
    CMSampleBufferRef sampleBuffer;
    while ((sampleBuffer = [output copyNextSampleBuffer])) {
        frames += CMSampleBufferGetNumSamples(sampleBuffer);
        CFRelease(sampleBuffer);
    }
    return frames;
}

int main(void)
{
    @autoreleasepool {
        NSData *wav = [NSData dataWithContentsOfFile:@"/Users/jonathan/Desktop/webkit/LayoutTests/webaudio/resources/media/24bit-44khz.wav"];
        if (!wav.length) {
            printf("FAILED: the probe's WAV is missing\n");
            return 1;
        }

        // A delegate that answers only after returning, and describes the resource by MIME type.
        check("async delegate, MIME content type",
            framesReadThrough(assetServedBy([[WKAsyncLoader alloc] initWithData:wav type:@"audio/wave"])), 44100);

        // The same, described by the uniform type identifier the property is documented to take.
        check("async delegate, UTI content type",
            framesReadThrough(assetServedBy([[WKAsyncLoader alloc] initWithData:wav type:@"com.microsoft.waveform-audio"])), 44100);

        // A delegate with nothing to give: no tracks, and nothing raised.
        check("declining delegate answers no tracks",
            framesReadThrough(assetServedBy([[WKDecliningLoader alloc] init])), -1);

        // A local asset is untouched by any of this.
        AVURLAsset *localAsset = [[AVURLAsset alloc] initWithURL:
            [NSURL fileURLWithPath:@"/Users/jonathan/Desktop/webkit/LayoutTests/webaudio/resources/media/24bit-44khz.wav"] options:nil];
        check("a local asset reads as it always did", framesReadThrough(localAsset), 44100);
    }

    if (failures) {
        printf("FAILED: %d\n", failures);
        return 1;
    }
    printf("PASS\n");
    return 0;
}
