/*
 * Network.framework, as much of it as TestWebKitAPI's HTTPServer and Connection use, on macOS 10.9.
 *
 * The API-test HTTP server is written against nw_listener / nw_connection / nw_framer and the
 * sec_protocol_options TLS configuration. 10.9 ships no Network.framework, so this file supplies
 * those entry points over BSD sockets, dispatch sources and SecureTransport, and the API-test
 * binaries link it in place of -framework Network. Tools/TestWebKitAPI/cocoa/HTTPServer.mm and
 * Tools/TestWebKitAPI/NetworkConnection.mm compile and run unmodified against it.
 *
 * Declarations come from the build SDK's <Network/Network.h> and <Security/SecProtocolOptions.h>,
 * so every signature below is checked against the real API.
 *
 * Shape of a connection: bytes arrive from the socket, pass through the framer stage (when the
 * parameters carry a framer -- how the HTTPS-proxy CONNECT handshake is expressed), then through
 * the TLS stage (when the parameters carry TLS), and land in the application's receive buffer.
 * Sends run the reverse. All work for one connection happens on the queue given to
 * nw_connection_set_queue, and all work for a listener on the queue given to
 * nw_listener_set_queue.
 */

#import <Foundation/Foundation.h>
#import <Network/Network.h>
#import <Security/SecProtocolOptions.h>
#import <Security/SecProtocolTypes.h>
#import <Security/SecureTransport.h>
#import <arpa/inet.h>
#import <dispatch/dispatch.h>
#import <errno.h>
#import <fcntl.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <string.h>
#import <sys/socket.h>
#import <unistd.h>

#include <algorithm>

static void fatal(const char *what)
{
    fprintf(stderr, "NetworkFrameworkMavericks: %s\n", what);
    abort();
}

// MARK: - Value objects

@interface WKNWError : NSObject <OS_nw_error>
@property (nonatomic) int posixCode;
@end
@implementation WKNWError
@end

static nw_error_t makeError(int posixCode)
{
    WKNWError *error = [[[WKNWError alloc] init] autorelease];
    error.posixCode = posixCode;
    return (nw_error_t)error;
}

@interface WKNWEndpoint : NSObject <OS_nw_endpoint>
@property (nonatomic, copy) NSString *hostname;
@property (nonatomic) uint16_t port;
@end
@implementation WKNWEndpoint
- (void)dealloc
{
    [_hostname release];
    [super dealloc];
}
@end

@interface WKNWContentContext : NSObject <OS_nw_content_context>
@end
@implementation WKNWContentContext
@end

@interface WKNWProtocolMetadata : NSObject <OS_nw_protocol_metadata>
@end
@implementation WKNWProtocolMetadata
@end

@interface WKSecTrust : NSObject <OS_sec_trust>
@property (nonatomic) SecTrustRef trust;
@end
@implementation WKSecTrust
- (void)dealloc
{
    if (_trust)
        CFRelease(_trust);
    [super dealloc];
}
@end

@interface WKSecIdentity : NSObject <OS_sec_identity>
@property (nonatomic) SecIdentityRef identity;
@end
@implementation WKSecIdentity
- (void)dealloc
{
    if (_identity)
        CFRelease(_identity);
    [super dealloc];
}
@end

@interface WKSecProtocolMetadata : NSObject <OS_sec_protocol_metadata>
@end
@implementation WKSecProtocolMetadata
@end

@interface WKSecProtocolOptions : NSObject <OS_sec_protocol_options>
@property (nonatomic, retain) WKSecIdentity *localIdentity;
@property (nonatomic) tls_protocol_version_t minVersion;
@property (nonatomic) tls_protocol_version_t maxVersion;
@property (nonatomic) BOOL peerAuthenticationRequired;
@property (nonatomic, copy) sec_protocol_verify_t verifyBlock;
@property (nonatomic, retain) dispatch_queue_t verifyQueue;
@property (nonatomic, retain) NSMutableArray *applicationProtocols;
@end
@implementation WKSecProtocolOptions
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    _applicationProtocols = [[NSMutableArray alloc] init];
    return self;
}
- (void)dealloc
{
    [_localIdentity release];
    [_verifyBlock release];
    [_verifyQueue release];
    [_applicationProtocols release];
    [super dealloc];
}
@end

@interface WKNWProtocolDefinition : NSObject <OS_nw_protocol_definition>
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) nw_framer_start_handler_t startHandler;
@end
@implementation WKNWProtocolDefinition
- (void)dealloc
{
    [_identifier release];
    [_startHandler release];
    [super dealloc];
}
@end

// A protocol options object is either the TLS options or a framer's options; the two are the only
// application protocols HTTPServer builds a stack out of.
@interface WKNWProtocolOptions : NSObject <OS_nw_protocol_options>
@property (nonatomic, retain) WKSecProtocolOptions *tlsOptions;
@property (nonatomic, retain) WKNWProtocolDefinition *framerDefinition;
@end
@implementation WKNWProtocolOptions
- (void)dealloc
{
    [_tlsOptions release];
    [_framerDefinition release];
    [super dealloc];
}
@end

// applicationProtocols is ordered topmost (closest to the application) first, which is the order
// nw_protocol_stack_prepend_application_protocol builds.
@interface WKNWProtocolStack : NSObject <OS_nw_protocol_stack>
@property (nonatomic, retain) NSMutableArray *applicationProtocols;
@end
@implementation WKNWProtocolStack
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    _applicationProtocols = [[NSMutableArray alloc] init];
    return self;
}
- (void)dealloc
{
    [_applicationProtocols release];
    [super dealloc];
}
@end

@interface WKNWParameters : NSObject <OS_nw_parameters>
@property (nonatomic, retain) WKNWProtocolStack *stack;
@property (nonatomic, retain) WKNWEndpoint *localEndpoint;
@end
@implementation WKNWParameters
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    _stack = [[WKNWProtocolStack alloc] init];
    return self;
}
- (void)dealloc
{
    [_stack release];
    [_localEndpoint release];
    [super dealloc];
}
@end

// MARK: - Connection

@class WKNWConnection;

@interface WKNWFramer : NSObject <OS_nw_framer>
@property (nonatomic, assign) WKNWConnection *connection;
@property (nonatomic, copy) nw_framer_input_handler_t inputHandler;
@property (nonatomic) NSUInteger deliveredDuringParse;
@end

@interface WKNWReceive : NSObject
@property (nonatomic) uint32_t minimumLength;
@property (nonatomic) uint32_t maximumLength;
@property (nonatomic, copy) nw_connection_receive_completion_t completion;
@end
@implementation WKNWReceive
- (void)dealloc
{
    [_completion release];
    [super dealloc];
}
@end

@interface WKNWPendingSend : NSObject
@property (nonatomic, retain) NSData *bytes;
@property (nonatomic, copy) nw_connection_send_completion_t completion;
@end
@implementation WKNWPendingSend
- (void)dealloc
{
    [_bytes release];
    [_completion release];
    [super dealloc];
}
@end

@interface WKNWConnection : NSObject <OS_nw_connection> {
@public
    int _fd;
    dispatch_queue_t _queue;
    dispatch_source_t _readSource;
    dispatch_source_t _writeSource;
    BOOL _writeSourceActive;
    nw_connection_state_changed_handler_t _stateHandler;
    WKNWParameters *_parameters;

    NSMutableData *_rawIn;    // read from the socket, not yet consumed by the bottom stage
    NSMutableData *_stageIn;  // framer output, i.e. TLS input (or application input with no TLS)
    NSMutableData *_appIn;    // available to the application
    NSMutableData *_out;      // waiting to go out on the socket
    int _writeError;          // the errno that ended the write side, 0 while it is healthy

    BOOL _socketReadClosed;
    BOOL _appClosed;

    WKNWFramer *_framer;
    BOOL _framerReady;

    WKSecProtocolOptions *_tls;
    SSLContextRef _ssl;
    BOOL _handshakeDone;
    BOOL _verifyInFlight;

    BOOL _started;
    BOOL _ready;
    BOOL _cancelled;

    NSMutableArray *_receives;
    BOOL _deliveringReceives;
    NSMutableArray *_queuedSends;
}
- (instancetype)initWithFileDescriptor:(int)fd parameters:(WKNWParameters *)parameters;
- (void)pump;
- (void)writeRawBytes:(const void *)bytes length:(size_t)length;
- (void)markFramerReady;
@end

@implementation WKNWFramer
- (void)dealloc
{
    [_inputHandler release];
    [super dealloc];
}
@end

static OSStatus sslRead(SSLConnectionRef connectionRef, void *data, size_t *dataLength);
static OSStatus sslWrite(SSLConnectionRef connectionRef, const void *data, size_t *dataLength);

@implementation WKNWConnection

- (instancetype)initWithFileDescriptor:(int)fd parameters:(WKNWParameters *)parameters
{
    if (!(self = [super init]))
        return nil;
    _fd = fd;
    _parameters = [parameters retain];
    _rawIn = [[NSMutableData alloc] init];
    _stageIn = [[NSMutableData alloc] init];
    _appIn = [[NSMutableData alloc] init];
    _out = [[NSMutableData alloc] init];
    _receives = [[NSMutableArray alloc] init];
    _queuedSends = [[NSMutableArray alloc] init];

    for (WKNWProtocolOptions *options in parameters.stack.applicationProtocols) {
        if (options.tlsOptions)
            _tls = [options.tlsOptions retain];
        else if (options.framerDefinition) {
            _framer = [[WKNWFramer alloc] init];
            _framer.connection = self;
            _framer.deliveredDuringParse = 0;
        }
    }
    return self;
}

- (void)dealloc
{
    if (_ssl)
        CFRelease(_ssl);
    if (_fd >= 0)
        close(_fd);
    [_parameters release];
    [_rawIn release];
    [_stageIn release];
    [_appIn release];
    [_out release];
    [_receives release];
    [_queuedSends release];
    [_framer release];
    [_tls release];
    [_stateHandler release];
    [_queue release];
    [super dealloc];
}

- (void)setQueue:(dispatch_queue_t)queue
{
    [_queue release];
    _queue = [queue retain];
}

- (void)reportState:(nw_connection_state_t)state error:(nw_error_t)error
{
    nw_connection_state_changed_handler_t handler = _stateHandler;
    if (!handler)
        return;
    [self retain];
    dispatch_async(_queue, ^{
        nw_connection_state_changed_handler_t current = _stateHandler;
        if (current)
            current(state, error);
        [self release];
    });
}

- (void)becomeReady
{
    if (_ready || _cancelled)
        return;
    _ready = YES;
    [self reportState:nw_connection_state_ready error:nil];
    [self flushQueuedSends];
}

- (void)start
{
    if (_started)
        return;
    _started = YES;

    _readSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, _fd, 0, _queue);
    dispatch_source_set_event_handler(_readSource, ^{
        [self readFromSocket];
    });
    dispatch_resume(_readSource);

    if (_framer) {
        WKNWProtocolDefinition *definition = nil;
        for (WKNWProtocolOptions *options in _parameters.stack.applicationProtocols) {
            if (options.framerDefinition)
                definition = options.framerDefinition;
        }
        nw_framer_start_result_t result = definition.startHandler((nw_framer_t)_framer);
        if (result == nw_framer_start_result_ready)
            [self markFramerReady];
    } else
        [self beginUpperStage];
}

// The framer, when present, gates the stage above it: nothing may be handed to TLS or to the
// application until it says the connection is established.
- (void)markFramerReady
{
    if (_framerReady)
        return;
    _framerReady = YES;
    [self beginUpperStage];
}

- (void)beginUpperStage
{
    if (_tls)
        [self startTLS];
    else
        [self becomeReady];
}

// MARK: TLS

// 10.9's SecureTransport tops out at TLS 1.2. Answering a request for anything else with 1.2 would
// move a bound rather than report that it cannot be expressed -- and for a MINIMUM version that
// weakens the server, so a test asserting a legacy client is refused would pass without measuring it.
static SSLProtocol sslProtocolVersion(tls_protocol_version_t version)
{
    switch (version) {
    case tls_protocol_version_TLSv10:
        return kTLSProtocol1;
    case tls_protocol_version_TLSv11:
        return kTLSProtocol11;
    case tls_protocol_version_TLSv12:
        return kTLSProtocol12;
    default:
        break;
    }
    fprintf(stderr, "NetworkFrameworkMavericks: TLS protocol version 0x%04x\n", (unsigned)version);
    fatal("this OS's SecureTransport cannot express that TLS protocol version");
    return kTLSProtocol12;
}

- (void)startTLS
{
    _ssl = SSLCreateContext(kCFAllocatorDefault, kSSLServerSide, kSSLStreamType);
    if (!_ssl)
        fatal("SSLCreateContext failed");
    SSLSetIOFuncs(_ssl, sslRead, sslWrite);
    SSLSetConnection(_ssl, (SSLConnectionRef)self);

    if (_tls.localIdentity.identity) {
        const void *values[] = { _tls.localIdentity.identity };
        CFArrayRef certificates = CFArrayCreate(kCFAllocatorDefault, values, 1, &kCFTypeArrayCallBacks);
        OSStatus status = SSLSetCertificate(_ssl, certificates);
        CFRelease(certificates);
        if (status != noErr) {
            fprintf(stderr, "NetworkFrameworkMavericks: SSLSetCertificate failed (%d)\n", (int)status);
            fatal("the TLS server has no usable identity");
        }
    }

    if (_tls.minVersion)
        SSLSetProtocolVersionMin(_ssl, sslProtocolVersion(_tls.minVersion));
    if (_tls.maxVersion)
        SSLSetProtocolVersionMax(_ssl, sslProtocolVersion(_tls.maxVersion));

    if ([_tls.applicationProtocols count]) {
        // 10.9's SecureTransport has no ALPN extension to negotiate with, so a server asked for one
        // would quietly serve HTTP/1.1 and every assertion about the negotiated protocol would report
        // a result it did not measure.
        CFArrayRef protocols = (CFArrayRef)[[_tls.applicationProtocols copy] autorelease];
        OSStatus status = SSLSetALPNProtocols(_ssl, protocols);
        if (status != noErr) {
            fprintf(stderr, "NetworkFrameworkMavericks: SSLSetALPNProtocols failed (%d)\n", (int)status);
            fatal("this OS cannot negotiate a TLS application protocol");
        }
    }

    if (_tls.peerAuthenticationRequired) {
        SSLSetClientSideAuthenticate(_ssl, kAlwaysAuthenticate);
        if (_tls.verifyBlock)
            SSLSetSessionOption(_ssl, kSSLSessionOptionBreakOnClientAuth, true);
    }

    [self driveHandshake];
}

- (void)driveHandshake
{
    if (_verifyInFlight || _handshakeDone || _cancelled)
        return;

    OSStatus status = SSLHandshake(_ssl);
    if (status == errSSLWouldBlock)
        return;

    if (status == errSSLPeerAuthCompleted || status == errSSLClientCertRequested) {
        [self runVerifyBlock];
        return;
    }

    if (status != noErr) {
        fprintf(stderr, "NetworkFrameworkMavericks: SSLHandshake failed (%d)\n", (int)status);
        [self failWithPOSIXError:ECONNRESET];
        return;
    }

    _handshakeDone = YES;
    [self becomeReady];
    [self pump];
}

- (void)runVerifyBlock
{
    sec_protocol_verify_t verify = _tls.verifyBlock;
    if (!verify) {
        [self driveHandshake];
        return;
    }

    SecTrustRef trust = nullptr;
    SSLCopyPeerTrust(_ssl, &trust);
    WKSecTrust *secTrust = [[[WKSecTrust alloc] init] autorelease];
    secTrust.trust = trust;

    _verifyInFlight = YES;
    WKSecProtocolMetadata *metadata = [[[WKSecProtocolMetadata alloc] init] autorelease];
    [self retain];
    sec_protocol_verify_complete_t completion = ^(bool valid) {
        dispatch_async(_queue, ^{
            _verifyInFlight = NO;
            if (valid)
                [self driveHandshake];
            else
                [self failWithPOSIXError:ECONNREFUSED];
            [self release];
        });
    };
    dispatch_queue_t queue = _tls.verifyQueue ?: _queue;
    dispatch_async(queue, ^{
        verify((sec_protocol_metadata_t)metadata, (sec_trust_t)secTrust, completion);
    });
}

// MARK: Socket

- (void)readFromSocket
{
    if (_cancelled)
        return;
    uint8_t buffer[16384];
    while (true) {
        ssize_t count = read(_fd, buffer, sizeof(buffer));
        if (count > 0) {
            [_rawIn appendBytes:buffer length:(NSUInteger)count];
            continue;
        }
        if (!count) {
            _socketReadClosed = YES;
            if (_readSource) {
                dispatch_source_cancel(_readSource);
                dispatch_release(_readSource);
                _readSource = nullptr;
            }
            break;
        }
        if (errno == EINTR)
            continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK)
            break;
        // A reset is not an end of stream, and leaving the source armed on a persistent error spins
        // the queue. Report it as the failure it is.
        [self failWithPOSIXError:errno ?: ECONNRESET];
        return;
    }
    [self pump];
}

- (void)writeRawBytes:(const void *)bytes length:(size_t)length
{
    if (length)
        [_out appendBytes:bytes length:length];
    [self flushOut];
}

- (void)flushOut
{
    if (_cancelled)
        return;
    while ([_out length]) {
        ssize_t written = write(_fd, [_out bytes], [_out length]);
        if (written > 0) {
            [_out replaceBytesInRange:NSMakeRange(0, (NSUInteger)written) withBytes:NULL length:0];
            continue;
        }
        if (written < 0 && errno == EINTR)
            continue;
        if (written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            [self enableWriteSource];
            return;
        }
        // The peer is gone. The bytes are dropped, so every send from here on has to say so.
        _writeError = errno ?: EPIPE;
        [_out setLength:0];
        [self disableWriteSource];
        return;
    }
    [self disableWriteSource];
}

- (void)enableWriteSource
{
    if (!_writeSource) {
        _writeSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_WRITE, _fd, 0, _queue);
        dispatch_source_set_event_handler(_writeSource, ^{
            [self flushOut];
        });
        _writeSourceActive = NO;
    }
    if (!_writeSourceActive) {
        _writeSourceActive = YES;
        dispatch_resume(_writeSource);
    }
}

- (void)disableWriteSource
{
    if (_writeSource && _writeSourceActive) {
        _writeSourceActive = NO;
        dispatch_suspend(_writeSource);
    }
}

// MARK: Pipeline

- (void)pump
{
    if (_cancelled)
        return;

    if (_framer) {
        while ([_rawIn length] && _framer.inputHandler) {
            NSUInteger before = [_rawIn length];
            _framer.inputHandler((nw_framer_t)_framer);
            if ([_rawIn length] == before)
                break;
        }
    } else if ([_rawIn length]) {
        [_stageIn appendData:_rawIn];
        [_rawIn setLength:0];
    }

    if (_tls) {
        if (!_handshakeDone)
            [self driveHandshake];
        if (_handshakeDone)
            [self drainDecryptedBytes];
    } else if ([_stageIn length]) {
        [_appIn appendData:_stageIn];
        [_stageIn setLength:0];
    }

    if (_socketReadClosed && ![_rawIn length] && ![_stageIn length])
        _appClosed = YES;

    [self deliverReceives];
}

- (void)drainDecryptedBytes
{
    uint8_t buffer[16384];
    while (true) {
        size_t processed = 0;
        OSStatus status = SSLRead(_ssl, buffer, sizeof(buffer), &processed);
        if (processed)
            [_appIn appendBytes:buffer length:processed];
        if (status == errSSLWouldBlock)
            return;
        if (status == noErr) {
            if (!processed)
                return;
            continue;
        }
        if (status == errSSLClosedGraceful || status == errSSLClosedAbort || status == errSSLClosedNoNotify)
            _appClosed = YES;
        return;
    }
}

- (void)deliverReceives
{
    // A completion handler routinely asks for the next chunk (Connection::receiveHTTPRequest reads
    // until it has a whole request), and enqueueing re-enters here.
    if (_deliveringReceives)
        return;
    _deliveringReceives = YES;
    while ([_receives count]) {
        WKNWReceive *receive = [_receives objectAtIndex:0];
        NSUInteger available = [_appIn length];
        if (available >= receive.minimumLength && available) {
            NSUInteger length = std::min<NSUInteger>(available, receive.maximumLength);
            dispatch_data_t content = dispatch_data_create([_appIn bytes], length, _queue, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
            [_appIn replaceBytesInRange:NSMakeRange(0, length) withBytes:NULL length:0];
            [[receive retain] autorelease];
            [_receives removeObjectAtIndex:0];
            WKNWContentContext *context = [[[WKNWContentContext alloc] init] autorelease];
            receive.completion(content, (nw_content_context_t)context, false, nil);
            dispatch_release(content);
            continue;
        }
        if (_appClosed) {
            [[receive retain] autorelease];
            [_receives removeObjectAtIndex:0];
            receive.completion(nil, nil, true, nil);
            continue;
        }
        break;
    }
    _deliveringReceives = NO;
}

- (void)enqueueReceiveWithMinimum:(uint32_t)minimum maximum:(uint32_t)maximum completion:(nw_connection_receive_completion_t)completion
{
    WKNWReceive *receive = [[WKNWReceive alloc] init];
    receive.minimumLength = minimum;
    receive.maximumLength = maximum;
    receive.completion = completion;
    [_receives addObject:receive];
    [receive release];
    [self deliverReceives];
}

// MARK: Sending

- (void)flushQueuedSends
{
    while ([_queuedSends count]) {
        WKNWPendingSend *send = [[[_queuedSends objectAtIndex:0] retain] autorelease];
        [_queuedSends removeObjectAtIndex:0];
        [self writeApplicationBytes:send.bytes completion:send.completion];
    }
}

- (void)writeApplicationBytes:(NSData *)bytes completion:(nw_connection_send_completion_t)completion
{
    if (_cancelled) {
        if (completion)
            completion(makeError(ECANCELED));
        return;
    }

    if (_tls) {
        const uint8_t *cursor = static_cast<const uint8_t *>([bytes bytes]);
        size_t remaining = [bytes length];
        while (remaining) {
            size_t processed = 0;
            OSStatus status = SSLWrite(_ssl, cursor, remaining, &processed);
            cursor += processed;
            remaining -= processed;
            if (status == errSSLWouldBlock) {
                if (processed)
                    continue;
                if (completion)
                    completion(makeError(EAGAIN));
                return;
            }
            if (status != noErr) {
                if (completion)
                    completion(makeError(ECONNRESET));
                return;
            }
        }
    } else
        [self writeRawBytes:[bytes bytes] length:[bytes length]];

    if (completion)
        completion(_writeError ? makeError(_writeError) : nil);
}

- (void)sendBytes:(NSData *)bytes completion:(nw_connection_send_completion_t)completion
{
    // Before the stack is established there is no encoder to hand the bytes to, so they wait.
    if (_tls && !_handshakeDone) {
        WKNWPendingSend *send = [[WKNWPendingSend alloc] init];
        send.bytes = bytes;
        send.completion = completion;
        [_queuedSends addObject:send];
        [send release];
        return;
    }
    [self writeApplicationBytes:bytes completion:completion];
}

// MARK: Teardown

- (void)failWithPOSIXError:(int)posixCode
{
    if (_cancelled)
        return;
    [self tearDown];
    [self reportState:nw_connection_state_failed error:makeError(posixCode)];
    _appClosed = YES;
    [self deliverReceives];
}

- (void)tearDown
{
    if (_readSource) {
        dispatch_source_cancel(_readSource);
        dispatch_release(_readSource);
        _readSource = nullptr;
    }
    if (_writeSource) {
        if (!_writeSourceActive)
            dispatch_resume(_writeSource);
        _writeSourceActive = NO;
        dispatch_source_cancel(_writeSource);
        dispatch_release(_writeSource);
        _writeSource = nullptr;
    }
    if (_ssl) {
        SSLClose(_ssl);
        CFRelease(_ssl);
        _ssl = nullptr;
    }
    if (_fd >= 0) {
        close(_fd);
        _fd = -1;
    }
}

- (void)cancel
{
    if (_cancelled)
        return;
    _cancelled = YES;
    [self flushOut];
    [self tearDown];
    _appClosed = YES;

    NSArray *pending = [[_receives copy] autorelease];
    [_receives removeAllObjects];
    for (WKNWReceive *receive in pending)
        receive.completion(nil, nil, true, nil);

    [self reportState:nw_connection_state_cancelled error:nil];
}

@end

static OSStatus sslRead(SSLConnectionRef connectionRef, void *data, size_t *dataLength)
{
    WKNWConnection *connection = (WKNWConnection *)connectionRef;
    NSMutableData *source = connection->_stageIn;
    size_t wanted = *dataLength;
    size_t available = [source length];
    size_t count = wanted < available ? wanted : available;
    if (count) {
        memcpy(data, [source bytes], count);
        [source replaceBytesInRange:NSMakeRange(0, count) withBytes:NULL length:0];
    }
    *dataLength = count;
    if (count < wanted)
        return connection->_socketReadClosed && !count ? errSSLClosedGraceful : errSSLWouldBlock;
    return noErr;
}

static OSStatus sslWrite(SSLConnectionRef connectionRef, const void *data, size_t *dataLength)
{
    WKNWConnection *connection = (WKNWConnection *)connectionRef;
    [connection writeRawBytes:data length:*dataLength];
    return noErr;
}

// MARK: - Listener

@interface WKNWListener : NSObject <OS_nw_listener> {
@public
    int _fd;
    uint16_t _port;
    dispatch_queue_t _queue;
    dispatch_source_t _acceptSource;
    nw_listener_state_changed_handler_t _stateHandler;
    nw_listener_new_connection_handler_t _newConnectionHandler;
    WKNWParameters *_parameters;
    BOOL _cancelled;
}
@end

@implementation WKNWListener

- (instancetype)initWithParameters:(WKNWParameters *)parameters
{
    if (!(self = [super init]))
        return nil;
    _fd = -1;
    _parameters = [parameters retain];

    int fd = socket(AF_INET6, SOCK_STREAM, IPPROTO_TCP);
    if (fd < 0) {
        [self release];
        return nil;
    }

    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
    int off = 0;
    setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &off, sizeof(off));

    struct sockaddr_in6 address;
    memset(&address, 0, sizeof(address));
    address.sin6_len = sizeof(address);
    address.sin6_family = AF_INET6;
    address.sin6_addr = in6addr_any;
    address.sin6_port = htons(parameters.localEndpoint ? parameters.localEndpoint.port : 0);
    if (bind(fd, (const struct sockaddr *)&address, sizeof(address)) < 0 || listen(fd, 128) < 0) {
        close(fd);
        [self release];
        return nil;
    }

    socklen_t length = sizeof(address);
    if (getsockname(fd, (struct sockaddr *)&address, &length) < 0) {
        close(fd);
        [self release];
        return nil;
    }
    _port = ntohs(address.sin6_port);
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
    _fd = fd;
    return self;
}

- (void)dealloc
{
    if (_fd >= 0)
        close(_fd);
    [_parameters release];
    [_stateHandler release];
    [_newConnectionHandler release];
    [_queue release];
    [super dealloc];
}

- (void)start
{
    _acceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, _fd, 0, _queue);
    dispatch_source_set_event_handler(_acceptSource, ^{
        [self acceptConnections];
    });
    dispatch_resume(_acceptSource);

    [self retain];
    dispatch_async(_queue, ^{
        if (_stateHandler)
            _stateHandler(nw_listener_state_ready, nil);
        [self release];
    });
}

- (void)acceptConnections
{
    while (true) {
        int fd = accept(_fd, nullptr, nullptr);
        if (fd < 0)
            return;
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
        int on = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, sizeof(on));

        WKNWConnection *connection = [[WKNWConnection alloc] initWithFileDescriptor:fd parameters:_parameters];
        if (_newConnectionHandler) {
            @autoreleasepool {
                _newConnectionHandler((nw_connection_t)connection);
            }
        }
        [connection release];
    }
}

- (void)cancel
{
    if (_cancelled)
        return;
    _cancelled = YES;
    if (_acceptSource) {
        dispatch_source_cancel(_acceptSource);
        dispatch_release(_acceptSource);
        _acceptSource = nullptr;
    }
    if (_fd >= 0) {
        close(_fd);
        _fd = -1;
    }
    [self retain];
    dispatch_async(_queue, ^{
        if (_stateHandler)
            _stateHandler(nw_listener_state_cancelled, nil);
        [self release];
    });
}

@end

// MARK: - C entry points

extern "C" {

const nw_parameters_configure_protocol_block_t _nw_parameters_configure_protocol_default_configuration = ^(nw_protocol_options_t) { };
const nw_parameters_configure_protocol_block_t _nw_parameters_configure_protocol_disable = ^(nw_protocol_options_t) { };
const nw_content_context_t _nw_content_context_default_message = (nw_content_context_t)[[WKNWContentContext alloc] init];

nw_protocol_options_t nw_tls_create_options(void)
{
    WKNWProtocolOptions *options = [[WKNWProtocolOptions alloc] init];
    options.tlsOptions = [[[WKSecProtocolOptions alloc] init] autorelease];
    return (nw_protocol_options_t)options;
}

sec_protocol_options_t nw_tls_copy_sec_protocol_options(nw_protocol_options_t options)
{
    WKNWProtocolOptions *wrapper = (WKNWProtocolOptions *)options;
    return (sec_protocol_options_t)[wrapper.tlsOptions retain];
}

nw_parameters_t nw_parameters_create_secure_tcp(nw_parameters_configure_protocol_block_t configureTLS, nw_parameters_configure_protocol_block_t configureTCP)
{
    (void)configureTCP;
    WKNWParameters *parameters = [[WKNWParameters alloc] init];
    if (configureTLS != _nw_parameters_configure_protocol_disable) {
        nw_protocol_options_t tls = nw_tls_create_options();
        if (configureTLS && configureTLS != _nw_parameters_configure_protocol_default_configuration)
            configureTLS(tls);
        [parameters.stack.applicationProtocols insertObject:(WKNWProtocolOptions *)tls atIndex:0];
        [tls release];
    }
    return (nw_parameters_t)parameters;
}

nw_protocol_stack_t nw_parameters_copy_default_protocol_stack(nw_parameters_t parameters)
{
    return (nw_protocol_stack_t)[((WKNWParameters *)parameters).stack retain];
}

void nw_protocol_stack_prepend_application_protocol(nw_protocol_stack_t stack, nw_protocol_options_t protocol)
{
    [((WKNWProtocolStack *)stack).applicationProtocols insertObject:(WKNWProtocolOptions *)protocol atIndex:0];
}

nw_endpoint_t nw_endpoint_create_host(const char *hostname, const char *port)
{
    WKNWEndpoint *endpoint = [[WKNWEndpoint alloc] init];
    endpoint.hostname = [NSString stringWithUTF8String:hostname];
    endpoint.port = (uint16_t)atoi(port);
    return (nw_endpoint_t)endpoint;
}

void nw_parameters_set_local_endpoint(nw_parameters_t parameters, nw_endpoint_t endpoint)
{
    ((WKNWParameters *)parameters).localEndpoint = (WKNWEndpoint *)endpoint;
}

// MARK: sec_protocol_options

sec_identity_t sec_identity_create(SecIdentityRef identity)
{
    if (!identity)
        return nil;
    WKSecIdentity *wrapper = [[WKSecIdentity alloc] init];
    wrapper.identity = (SecIdentityRef)CFRetain(identity);
    return (sec_identity_t)wrapper;
}

SecIdentityRef sec_identity_copy_ref(sec_identity_t identity)
{
    SecIdentityRef ref = ((WKSecIdentity *)identity).identity;
    return ref ? (SecIdentityRef)CFRetain(ref) : nullptr;
}

sec_trust_t sec_trust_create(SecTrustRef trust)
{
    if (!trust)
        return nil;
    WKSecTrust *wrapper = [[WKSecTrust alloc] init];
    wrapper.trust = (SecTrustRef)CFRetain(trust);
    return (sec_trust_t)wrapper;
}

SecTrustRef sec_trust_copy_ref(sec_trust_t trust)
{
    SecTrustRef ref = ((WKSecTrust *)trust).trust;
    return ref ? (SecTrustRef)CFRetain(ref) : nullptr;
}

void sec_protocol_options_set_local_identity(sec_protocol_options_t options, sec_identity_t identity)
{
    ((WKSecProtocolOptions *)options).localIdentity = (WKSecIdentity *)identity;
}

void sec_protocol_options_set_min_tls_protocol_version(sec_protocol_options_t options, tls_protocol_version_t version)
{
    ((WKSecProtocolOptions *)options).minVersion = version;
}

void sec_protocol_options_set_max_tls_protocol_version(sec_protocol_options_t options, tls_protocol_version_t version)
{
    ((WKSecProtocolOptions *)options).maxVersion = version;
}

void sec_protocol_options_set_peer_authentication_required(sec_protocol_options_t options, bool required)
{
    ((WKSecProtocolOptions *)options).peerAuthenticationRequired = required;
}

void sec_protocol_options_set_verify_block(sec_protocol_options_t options, sec_protocol_verify_t verifyBlock, dispatch_queue_t queue)
{
    WKSecProtocolOptions *wrapper = (WKSecProtocolOptions *)options;
    wrapper.verifyBlock = verifyBlock;
    wrapper.verifyQueue = queue;
}

void sec_protocol_options_add_tls_application_protocol(sec_protocol_options_t options, const char *applicationProtocol)
{
    [((WKSecProtocolOptions *)options).applicationProtocols addObject:[NSString stringWithUTF8String:applicationProtocol]];
}

// MARK: framer

nw_protocol_definition_t nw_framer_create_definition(const char *identifier, uint32_t flags, nw_framer_start_handler_t startHandler)
{
    (void)flags;
    WKNWProtocolDefinition *definition = [[WKNWProtocolDefinition alloc] init];
    definition.identifier = [NSString stringWithUTF8String:identifier];
    definition.startHandler = startHandler;
    return (nw_protocol_definition_t)definition;
}

nw_protocol_options_t nw_framer_create_options(nw_protocol_definition_t definition)
{
    WKNWProtocolOptions *options = [[WKNWProtocolOptions alloc] init];
    options.framerDefinition = (WKNWProtocolDefinition *)definition;
    return (nw_protocol_options_t)options;
}

void nw_framer_set_input_handler(nw_framer_t framer, nw_framer_input_handler_t inputHandler)
{
    ((WKNWFramer *)framer).inputHandler = inputHandler;
}

// The framer's output goes straight to the transport in this implementation, so declaring
// pass-through is what already happens.
void nw_framer_pass_through_output(nw_framer_t framer)
{
    (void)framer;
}

bool nw_framer_parse_input(nw_framer_t framer, size_t minimumIncompleteLength, size_t maximumLength, uint8_t *tempBuffer, NW_NOESCAPE nw_framer_parse_completion_t parse)
{
    (void)tempBuffer;
    WKNWFramer *wrapper = (WKNWFramer *)framer;
    WKNWConnection *connection = wrapper.connection;
    NSMutableData *input = connection->_rawIn;
    NSUInteger available = [input length];
    if (available < minimumIncompleteLength && !connection->_socketReadClosed)
        return false;

    NSUInteger length = available < maximumLength ? available : maximumLength;
    wrapper.deliveredDuringParse = 0;
    size_t consumed = parse((uint8_t *)[input mutableBytes], length, connection->_socketReadClosed);
    NSUInteger total = wrapper.deliveredDuringParse + consumed;
    if (total > [input length]) {
        fprintf(stderr, "NetworkFrameworkMavericks: framer consumed %lu of %lu available bytes\n",
            (unsigned long)total, (unsigned long)[input length]);
        fatal("a framer consumed more input than it was given");
    }
    [input replaceBytesInRange:NSMakeRange(0, total) withBytes:NULL length:0];
    wrapper.deliveredDuringParse = 0;
    return true;
}

bool nw_framer_deliver_input_no_copy(nw_framer_t framer, size_t inputLength, nw_framer_message_t message, bool isComplete)
{
    (void)message;
    (void)isComplete;
    WKNWFramer *wrapper = (WKNWFramer *)framer;
    WKNWConnection *connection = wrapper.connection;
    NSUInteger offset = wrapper.deliveredDuringParse;
    NSUInteger available = [connection->_rawIn length];
    if (offset + inputLength > available)
        inputLength = available > offset ? available - offset : 0;
    if (inputLength) {
        [connection->_stageIn appendBytes:static_cast<const uint8_t *>([connection->_rawIn bytes]) + offset length:inputLength];
        wrapper.deliveredDuringParse = offset + inputLength;
    }
    return true;
}

void nw_framer_write_output_data(nw_framer_t framer, dispatch_data_t data)
{
    WKNWConnection *connection = ((WKNWFramer *)framer).connection;
    dispatch_data_apply(data, ^bool(dispatch_data_t, size_t, const void *buffer, size_t size) {
        [connection writeRawBytes:buffer length:size];
        return true;
    });
}

void nw_framer_mark_ready(nw_framer_t framer)
{
    [((WKNWFramer *)framer).connection markFramerReady];
}

nw_framer_message_t nw_framer_message_create(nw_framer_t framer)
{
    (void)framer;
    return (nw_framer_message_t)[[WKNWProtocolMetadata alloc] init];
}

// MARK: listener

nw_listener_t nw_listener_create(nw_parameters_t parameters)
{
    return (nw_listener_t)[[WKNWListener alloc] initWithParameters:(WKNWParameters *)parameters];
}

void nw_listener_set_queue(nw_listener_t listener, dispatch_queue_t queue)
{
    WKNWListener *wrapper = (WKNWListener *)listener;
    [wrapper->_queue release];
    wrapper->_queue = [queue retain];
}

void nw_listener_set_state_changed_handler(nw_listener_t listener, nw_listener_state_changed_handler_t handler)
{
    WKNWListener *wrapper = (WKNWListener *)listener;
    nw_listener_state_changed_handler_t copied = handler ? [handler copy] : nil;
    [wrapper->_stateHandler release];
    wrapper->_stateHandler = copied;
}

void nw_listener_set_new_connection_handler(nw_listener_t listener, nw_listener_new_connection_handler_t handler)
{
    WKNWListener *wrapper = (WKNWListener *)listener;
    nw_listener_new_connection_handler_t copied = handler ? [handler copy] : nil;
    [wrapper->_newConnectionHandler release];
    wrapper->_newConnectionHandler = copied;
}

uint16_t nw_listener_get_port(nw_listener_t listener)
{
    return ((WKNWListener *)listener)->_port;
}

void nw_listener_start(nw_listener_t listener)
{
    [(WKNWListener *)listener start];
}

void nw_listener_cancel(nw_listener_t listener)
{
    [(WKNWListener *)listener cancel];
}

// MARK: connection

void nw_connection_set_queue(nw_connection_t connection, dispatch_queue_t queue)
{
    [(WKNWConnection *)connection setQueue:queue];
}

void nw_connection_set_state_changed_handler(nw_connection_t connection, nw_connection_state_changed_handler_t handler)
{
    WKNWConnection *wrapper = (WKNWConnection *)connection;
    nw_connection_state_changed_handler_t copied = handler ? [handler copy] : nil;
    [wrapper->_stateHandler release];
    wrapper->_stateHandler = copied;
}

void nw_connection_start(nw_connection_t connection)
{
    [(WKNWConnection *)connection start];
}

void nw_connection_cancel(nw_connection_t connection)
{
    [(WKNWConnection *)connection cancel];
}

void nw_connection_receive(nw_connection_t connection, uint32_t minimumIncompleteLength, uint32_t maximumLength, nw_connection_receive_completion_t completion)
{
    [(WKNWConnection *)connection enqueueReceiveWithMinimum:minimumIncompleteLength maximum:maximumLength completion:completion];
}

void nw_connection_send(nw_connection_t connection, dispatch_data_t content, nw_content_context_t context, bool isComplete, nw_connection_send_completion_t completion)
{
    (void)context;
    (void)isComplete;
    NSMutableData *bytes = [NSMutableData data];
    if (content) {
        dispatch_data_apply(content, ^bool(dispatch_data_t, size_t, const void *buffer, size_t size) {
            [bytes appendBytes:buffer length:size];
            return true;
        });
    }
    [(WKNWConnection *)connection sendBytes:bytes completion:completion];
}

nw_protocol_metadata_t nw_connection_copy_protocol_metadata(nw_connection_t connection, nw_protocol_definition_t definition)
{
    (void)connection;
    (void)definition;
    return nil;
}

} // extern "C"
