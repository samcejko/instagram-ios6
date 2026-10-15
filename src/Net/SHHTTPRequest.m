#import "SHHTTPRequest.h"
#import "SHTLSSocket.h"
#import "SHConnectionPool.h"
#import "SHCommon.h"

#include <zlib.h>
#include <string.h>
#include <stdlib.h>

typedef NS_ENUM(NSInteger, SHChunkState) {
    SHChunkStateSize = 0,
    SHChunkStateData,
    SHChunkStateDataEnd,
    SHChunkStateTrailer,
    SHChunkStateDone,
};

typedef NS_ENUM(NSInteger, SHExchangeResult) {
    SHExchangeDone = 0,      // response fully received
    SHExchangeRetry,         // reused connection turned out to be dead before any response byte arrived
    SHExchangeFailed,
};

static const NSUInteger SHInflateBufferSize = 32768;
static const long SHMaxConcurrentConnections = 10;
static const uint32_t SHReusedConnectionHeaderTimeoutMs = 10000;   // stale keep-alive connections must fail fast

static dispatch_semaphore_t SHConnectionSlots(void)
{
    static dispatch_semaphore_t slots;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ slots = dispatch_semaphore_create(SHMaxConcurrentConnections); });
    return slots;
}

@interface SHHTTPRequest ()
@property (nonatomic, strong) SHTLSSocket *socket;
@property (nonatomic, strong) SHHTTPRequest *selfRetain;
@property (nonatomic) NSInteger statusCode;
@property (nonatomic, strong) NSDictionary *responseHeaders;
@property (nonatomic, strong) NSArray *responseHeaderPairs;
@property (nonatomic, strong) NSArray *setCookieHeaders;
@property (nonatomic, strong) NSData *responseBody;
@property (nonatomic) BOOL isCancelled;
@property (nonatomic) BOOL isFinished;
@property (nonatomic) BOOL decodedContentEncoding;
@property (nonatomic, copy) NSString *tlsInfo;
@property (nonatomic, copy) NSString *timingSummary;
@property (nonatomic, strong) NSMutableData *accumulated;

// body decoding state
@property (nonatomic) BOOL chunked;
@property (nonatomic) long long contentLength;      // -1 unknown
@property (nonatomic) long long bodyReceived;       // raw (wire) body bytes
@property (nonatomic) SHChunkState chunkState;
@property (nonatomic) long long chunkRemaining;
@property (nonatomic) BOOL hasSlot;
@property (nonatomic) BOOL bodyError;
@property (nonatomic) BOOL http11;
@property (nonatomic) BOOL connectionClose;         // server asked to close after this response
@property (nonatomic) BOOL noBody;                  // HEAD, 204, 304
@property (nonatomic) BOOL keepAlive;               // decided once the response is complete
@end

@implementation SHHTTPRequest {
    z_stream _zstream;
    BOOL _zinit;
    BOOL _zactive;
    BOOL _zrawTried;          // the body was taken again as raw deflate (see deliverBodyBytes)
    NSUInteger _zproduced;    // decoded bytes so far
    uint8_t *_zout;
    // timing: started, got a connection slot, had a connection, saw the response headers
    CFAbsoluteTime _t0, _tSlot, _tConn, _tHead;
    BOOL _reusedConnection;
}

- (long long)wireBytes { return self.bodyReceived; }

- (instancetype)initWithMethod:(NSString *)method URL:(NSURL *)url
{
    self = [super init];
    if (self) {
        _method = [method length] ? [method uppercaseString] : @"GET";
        _url = url;
        _connectTimeout = 20;
        _readTimeout = 60;
        _verifyTLS = YES;
        _contentLength = -1;
        _accumulated = [NSMutableData data];
    }
    return self;
}

- (void)dealloc
{
    if (_zinit) inflateEnd(&_zstream);
    free(_zout);
}

+ (NSString *)defaultUserAgent
{
    static NSString *agent;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UIDevice *d = [UIDevice currentDevice];
        NSString *v = [[NSBundle mainBundle] infoDictionary][@"CFBundleShortVersionString"] ?: @"0";
        agent = [NSString stringWithFormat:@"Shutter/%@ (%@; iOS %@)", v, d.model, d.systemVersion];
    });
    return agent;
}

+ (NSString *)acceptLanguage
{
    NSArray *langs = [NSLocale preferredLanguages];
    NSMutableArray *parts = [NSMutableArray array];
    double q = 1.0;
    BOOL hasEnglish = NO;
    for (NSString *l in langs) {
        if (parts.count >= 4) break;
        if ([l hasPrefix:@"en"]) hasEnglish = YES;
        if (q >= 1.0) [parts addObject:l];
        else [parts addObject:[NSString stringWithFormat:@"%@;q=%.1f", l, q]];
        q -= 0.2;
    }
    if (!hasEnglish) [parts addObject:[NSString stringWithFormat:@"en;q=%.1f", MAX(0.1, q)]];
    return parts.count ? [parts componentsJoinedByString:@", "] : @"en";
}

- (void)start
{
    self.selfRetain = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
            [self run];
        }
    });
}

- (void)runSynchronously
{
    self.selfRetain = self;
    @autoreleasepool {
        [self run];
    }
}

- (void)cancel
{
    if (self.isFinished) return;
    self.isCancelled = YES;
    [self.socket cancel];
}

#pragma mark - Request

- (BOOL)isSecure
{
    return [[self.url.scheme lowercaseString] isEqualToString:@"https"];
}

- (int)port
{
    NSNumber *p = self.url.port;
    if (p) return [p intValue];
    return [self isSecure] ? 443 : 80;
}

- (NSString *)poolKey
{
    return [NSString stringWithFormat:@"%@://%@:%d", [self isSecure] ? @"https" : @"http", [self.url.host lowercaseString] ?: @"", [self port]];
}

// Path and query exactly as written in the URL (percent-encoded), without the fragment.
- (NSString *)requestTarget
{
    NSString *abs = self.url.absoluteString ?: @"/";
    NSRange schemeEnd = [abs rangeOfString:@"://"];
    NSString *rest = schemeEnd.location == NSNotFound ? abs : [abs substringFromIndex:schemeEnd.location + 3];
    NSRange slash = [rest rangeOfString:@"/"];
    NSString *target = slash.location == NSNotFound ? @"/" : [rest substringFromIndex:slash.location];
    NSRange hash = [target rangeOfString:@"#"];
    if (hash.location != NSNotFound) target = [target substringToIndex:hash.location];
    if (!target.length) target = @"/";
    return target;
}

- (NSData *)serializedRequest
{
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"%@ %@ HTTP/1.1\r\n", self.method, [self requestTarget]];
    NSString *host = self.url.host ?: @"";
    int port = [self port];
    BOOL defaultPort = ([self isSecure] && port == 443) || (![self isSecure] && port == 80);
    [s appendFormat:@"Host: %@\r\n", defaultPort ? host : [NSString stringWithFormat:@"%@:%d", host, port]];
    NSMutableSet *given = [NSMutableSet set];
    for (NSString *key in self.headers) {
        NSString *lk = [key lowercaseString];
        if ([lk isEqualToString:@"host"] || [lk isEqualToString:@"content-length"] || [lk isEqualToString:@"connection"] ||
            [lk isEqualToString:@"accept-encoding"] || [lk isEqualToString:@"transfer-encoding"] || [lk isEqualToString:@"expect"] ||
            [lk isEqualToString:@"keep-alive"]) continue;
        NSString *value = [[self.headers[key] description] stringByReplacingOccurrencesOfString:@"\r" withString:@" "];
        value = [value stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
        [given addObject:lk];
        [s appendFormat:@"%@: %@\r\n", key, value];
    }
    if (![given containsObject:@"user-agent"]) [s appendFormat:@"User-Agent: %@\r\n", [SHHTTPRequest defaultUserAgent]];
    if (![given containsObject:@"accept"]) [s appendString:@"Accept: */*\r\n"];
    if (![given containsObject:@"accept-language"]) [s appendFormat:@"Accept-Language: %@\r\n", [SHHTTPRequest acceptLanguage]];
    // (media passes through the proxy byte for byte: a Range answer must not come back compressed)
    [s appendString:self.noCompression ? @"Accept-Encoding: identity\r\n" : @"Accept-Encoding: gzip, deflate\r\n"];
    [s appendString:@"Connection: keep-alive\r\n"];
    if (self.body || [self.method isEqualToString:@"POST"] || [self.method isEqualToString:@"PUT"] || [self.method isEqualToString:@"PATCH"]) {
        [s appendFormat:@"Content-Length: %lu\r\n", (unsigned long)self.body.length];
    }
    [s appendString:@"\r\n"];
    NSMutableData *d = [[s dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    if (self.body) [d appendData:self.body];
    return d;
}

#pragma mark - Completion

- (void)releaseSlot
{
    if (self.hasSlot) {
        self.hasSlot = NO;
        dispatch_semaphore_signal(SHConnectionSlots());
    }
}

- (void)finishWithError:(NSError *)error
{
    if (self.isFinished) return;
    self.isFinished = YES;
    if (_t0 > 0) {
        CFAbsoluteTime end = CFAbsoluteTimeGetCurrent();
        CFAbsoluteTime slot = _tSlot > 0 ? _tSlot : _t0, conn = _tConn > 0 ? _tConn : slot, head = _tHead > 0 ? _tHead : end;
        self.timingSummary = [NSString stringWithFormat:@"slot %.0f conn %.0f %@ ttfb %.0f body %.0f",
                              (slot - _t0) * 1000, (conn - slot) * 1000, _reusedConnection ? @"reused" : @"new",
                              (head - conn) * 1000, (end - head) * 1000];
    }
    [self.socket close];
    self.socket = nil;
    [self releaseSlot];
    if (!self.onData) self.responseBody = [self.accumulated copy];
    self.accumulated = nil;
    SHHTTPCompleteBlock done = self.onComplete;
    self.onComplete = nil;
    self.onData = nil;
    self.onHeaders = nil;
    if (done) done(error);
    self.selfRetain = nil;
}

#pragma mark - Body decoding

- (void)deliverDecodedBytes:(const void *)bytes length:(NSUInteger)length
{
    if (!length) return;
    SHHTTPDataBlock cb = self.onData;
    if (cb) cb([NSData dataWithBytes:bytes length:length]);
    else [self.accumulated appendBytes:bytes length:length];
}

- (BOOL)setupInflate
{
    return [self setupInflateWindowBits:15 + 32];   // auto-detects gzip and zlib headers
}

- (BOOL)setupInflateWindowBits:(int)bits
{
    if (_zinit) {
        inflateEnd(&_zstream);
        _zinit = NO;
    }
    memset(&_zstream, 0, sizeof(_zstream));
    if (inflateInit2(&_zstream, bits) != Z_OK) return NO;
    _zinit = YES;
    if (!_zout) _zout = (uint8_t *)malloc(SHInflateBufferSize);
    if (!_zout) return NO;
    _zactive = YES;
    return YES;
}

// Raw body bytes from the wire (after transfer decoding). Returns NO on a content decoding error.
- (BOOL)deliverBodyBytes:(const void *)bytes length:(NSUInteger)length
{
    if (!length) return YES;
    self.bodyReceived += length;
    if (!_zactive) {
        [self deliverDecodedBytes:bytes length:length];
        return YES;
    }
    _zstream.next_in = (Bytef *)bytes;
    _zstream.avail_in = (uInt)length;
    while (_zstream.avail_in > 0) {
        _zstream.next_out = _zout;
        _zstream.avail_out = (uInt)SHInflateBufferSize;
        int rc = inflate(&_zstream, Z_NO_FLUSH);
        if (rc == Z_DATA_ERROR && !_zrawTried && _zproduced == 0 && self.bodyReceived == length) {
            // "deflate" sent raw, without the zlib header (many servers do): the first bytes once more as raw
            // deflate, as browsers do
            _zrawTried = YES;
            if (![self setupInflateWindowBits:-15]) return NO;
            _zstream.next_in = (Bytef *)bytes;
            _zstream.avail_in = (uInt)length;
            continue;
        }
        if (rc != Z_OK && rc != Z_STREAM_END && rc != Z_BUF_ERROR) {
            SHLog(@"inflate failed (%d) for %@", rc, self.url);
            return NO;
        }
        NSUInteger produced = SHInflateBufferSize - _zstream.avail_out;
        _zproduced += produced;
        [self deliverDecodedBytes:_zout length:produced];
        if (rc == Z_STREAM_END) {
            _zactive = NO;   // anything after the end of the stream is ignored
            break;
        }
        if (rc == Z_BUF_ERROR && produced == 0) break;   // needs more input
    }
    return YES;
}

// Returns YES when the whole body has been consumed.
- (BOOL)consumeBody:(NSMutableData *)buffer
{
    if (!self.chunked) {
        if (self.contentLength >= 0) {
            long long remaining = self.contentLength - self.bodyReceived;
            NSUInteger take = (NSUInteger)MIN((long long)buffer.length, MAX(remaining, 0));
            if (take) {
                if (![self deliverBodyBytes:buffer.bytes length:take]) { self.bodyError = YES; return YES; }
                [buffer replaceBytesInRange:NSMakeRange(0, take) withBytes:NULL length:0];
            }
            return self.bodyReceived >= self.contentLength;
        }
        if (buffer.length) {
            if (![self deliverBodyBytes:buffer.bytes length:buffer.length]) { self.bodyError = YES; return YES; }
            buffer.length = 0;
        }
        return NO;   // ends with the connection
    }
    // Chunked transfer encoding state machine.
    for (;;) {
        const uint8_t *bytes = (const uint8_t *)buffer.bytes;
        NSUInteger len = buffer.length;
        if (self.chunkState == SHChunkStateSize || self.chunkState == SHChunkStateTrailer) {
            NSUInteger lineEnd = NSNotFound;
            for (NSUInteger i = 0; i + 1 < len; i++) {
                if (bytes[i] == '\r' && bytes[i + 1] == '\n') { lineEnd = i; break; }
            }
            if (lineEnd == NSNotFound) return NO;   // need more data
            NSString *line = [[NSString alloc] initWithBytes:bytes length:lineEnd encoding:NSASCIIStringEncoding] ?: @"";
            [buffer replaceBytesInRange:NSMakeRange(0, lineEnd + 2) withBytes:NULL length:0];
            if (self.chunkState == SHChunkStateTrailer) {
                if (line.length == 0) { self.chunkState = SHChunkStateDone; return YES; }
                continue;
            }
            if (line.length == 0) continue;   // tolerate stray blank lines
            NSRange semi = [line rangeOfString:@";"];
            NSString *hex = semi.location == NSNotFound ? line : [line substringToIndex:semi.location];
            unsigned long long size = strtoull([hex UTF8String], NULL, 16);
            if (size == 0) {
                self.chunkState = SHChunkStateTrailer;
                continue;
            }
            self.chunkRemaining = (long long)size;
            self.chunkState = SHChunkStateData;
            continue;
        }
        if (self.chunkState == SHChunkStateData) {
            if (len == 0) return NO;
            NSUInteger take = (NSUInteger)MIN((long long)len, self.chunkRemaining);
            if (![self deliverBodyBytes:bytes length:take]) { self.bodyError = YES; return YES; }
            [buffer replaceBytesInRange:NSMakeRange(0, take) withBytes:NULL length:0];
            self.chunkRemaining -= take;
            if (self.chunkRemaining == 0) self.chunkState = SHChunkStateDataEnd;
            continue;
        }
        if (self.chunkState == SHChunkStateDataEnd) {
            if (len < 2) return NO;
            [buffer replaceBytesInRange:NSMakeRange(0, 2) withBytes:NULL length:0];   // CRLF after the chunk
            self.chunkState = SHChunkStateSize;
            continue;
        }
        return YES; // done
    }
}

#pragma mark - Headers

// 0 = need more data, 1 = final headers parsed, 2 = interim (1xx) response skipped, -1 = error.
- (int)parseHeadersFromBuffer:(NSMutableData *)buffer error:(NSError **)error
{
    const uint8_t *bytes = (const uint8_t *)buffer.bytes;
    NSUInteger len = buffer.length;
    NSUInteger end = NSNotFound;
    for (NSUInteger i = 0; i + 3 < len; i++) {
        if (bytes[i] == '\r' && bytes[i + 1] == '\n' && bytes[i + 2] == '\r' && bytes[i + 3] == '\n') { end = i; break; }
    }
    if (end == NSNotFound) {
        if (len > 64 * 1024) {
            if (error) *error = SHMakeError(SHErrorBadResponse, L(@"The server sent an invalid response."));
            return -1;
        }
        return 0;
    }
    NSString *head = [[NSString alloc] initWithBytes:bytes length:end encoding:NSISOLatin1StringEncoding] ?: @"";
    [buffer replaceBytesInRange:NSMakeRange(0, end + 4) withBytes:NULL length:0];
    NSArray *lines = [head componentsSeparatedByString:@"\r\n"];
    NSString *statusLine = lines.count ? lines[0] : @"";
    if (![statusLine hasPrefix:@"HTTP/"]) {
        if (error) *error = SHMakeError(SHErrorBadResponse, [NSString stringWithFormat:L(@"Unexpected response: %@"), statusLine.length > 80 ? [statusLine substringToIndex:80] : statusLine]);
        return -1;
    }
    NSArray *parts = [statusLine componentsSeparatedByString:@" "];
    NSInteger status = parts.count >= 2 ? [parts[1] integerValue] : 0;
    if (status < 100 || status > 999) {
        if (error) *error = SHMakeError(SHErrorBadResponse, [NSString stringWithFormat:L(@"Unexpected response: %@"), statusLine]);
        return -1;
    }
    if (status < 200) return 2;   // 100 Continue, 103 Early Hints: the real headers follow

    self.http11 = [statusLine hasPrefix:@"HTTP/1.1"];
    NSMutableArray *pairs = [NSMutableArray array];
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    NSMutableArray *cookies = [NSMutableArray array];
    for (NSUInteger i = 1; i < lines.count; i++) {
        NSString *line = lines[i];
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound || colon.location == 0) continue;
        NSString *name = [[line substringToIndex:colon.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *value = [[line substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (!name.length) continue;
        [pairs addObject:@[name, value]];
        NSString *lname = [name lowercaseString];
        if ([lname isEqualToString:@"set-cookie"]) {
            [cookies addObject:value];
            continue;
        }
        NSString *existing = headers[lname];
        headers[lname] = existing ? [NSString stringWithFormat:@"%@, %@", existing, value] : value;
    }
    self.statusCode = status;
    self.responseHeaders = headers;
    self.responseHeaderPairs = pairs;
    self.setCookieHeaders = cookies;
    NSString *connection = [headers[@"connection"] lowercaseString] ?: @"";
    self.connectionClose = [connection rangeOfString:@"close"].location != NSNotFound || (!self.http11 && [connection rangeOfString:@"keep-alive"].location == NSNotFound);
    NSString *te = [headers[@"transfer-encoding"] lowercaseString];
    self.chunked = te && [te rangeOfString:@"chunked"].location != NSNotFound;
    NSString *cl = headers[@"content-length"];
    self.contentLength = (cl && !self.chunked) ? [cl longLongValue] : -1;
    self.noBody = [self.method isEqualToString:@"HEAD"] || status == 204 || status == 304;
    NSString *ce = [[headers[@"content-encoding"] lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (!self.noBody && ([ce isEqualToString:@"gzip"] || [ce isEqualToString:@"x-gzip"] || [ce isEqualToString:@"deflate"])) {
        if ([self setupInflate]) self.decodedContentEncoding = YES;
    }
    return 1;
}

- (void)resetResponseState
{
    self.statusCode = 0;
    self.responseHeaders = nil;
    self.responseHeaderPairs = nil;
    self.setCookieHeaders = nil;
    self.chunked = NO;
    self.contentLength = -1;
    self.bodyReceived = 0;
    self.chunkState = SHChunkStateSize;
    self.chunkRemaining = 0;
    self.bodyError = NO;
    self.http11 = NO;
    self.connectionClose = NO;
    self.noBody = NO;
    self.decodedContentEncoding = NO;
    if (_zinit) { inflateEnd(&_zstream); _zinit = NO; }
    _zactive = NO;
    _zrawTried = NO;
    _zproduced = 0;
}

#pragma mark - Worker

- (SHTLSSocket *)connectWithError:(NSError **)error
{
    SHTLSSocket *socket = [[SHTLSSocket alloc] init];
    socket.plain = ![self isSecure];
    if (![socket connectToHost:self.url.host port:[self port] verify:self.verifyTLS
              connectTimeoutMs:(int)(self.connectTimeout * 1000) readTimeoutMs:(int)(self.readTimeout * 1000) error:error]) {
        if (error && !*error) *error = SHMakeError(SHErrorConnect, L(@"Connection failed."));
        return nil;
    }
    return socket;
}

// Sends the request and reads the whole response on `socket`.
- (SHExchangeResult)exchangeOnSocket:(SHTLSSocket *)socket reused:(BOOL)reused error:(NSError **)error
{
    BOOL responseSeen = NO;   // any byte of a response arrived
    self.tlsInfo = [NSString stringWithFormat:@"%@ %@", socket.tlsVersion ?: @"", socket.cipherSuite ?: @""];
    NSError *err = nil;
    if (![socket writeData:[self serializedRequest] error:&err]) {
        if (reused && !self.isCancelled) return SHExchangeRetry;
        if (error) *error = err ?: SHMakeError(SHErrorConnectionLost, L(@"Sending the request failed."));
        return SHExchangeFailed;
    }
    if (reused) [socket setReadTimeoutMs:MIN(SHReusedConnectionHeaderTimeoutMs, (uint32_t)(self.readTimeout * 1000))];

    NSMutableData *buffer = [NSMutableData data];
    BOOL headersDone = NO;
    BOOL bodyDone = NO;
    const NSUInteger chunkSize = 16384;
    uint8_t *tmp = (uint8_t *)malloc(chunkSize);
    if (!tmp) {
        if (error) *error = SHMakeError(SHErrorNetwork, @"Out of memory");
        return SHExchangeFailed;
    }
    SHExchangeResult result = SHExchangeFailed;
    while (!bodyDone) {
        NSError *readError = nil;
        NSInteger n = [socket readIntoBuffer:tmp maxLength:chunkSize error:&readError];
        if (n < 0) {
            if (reused && !responseSeen && !self.isCancelled) { result = SHExchangeRetry; goto out; }
            if (error) *error = readError ?: SHMakeError(SHErrorConnectionLost, L(@"Connection lost."));
            goto out;
        }
        if (n == 0) {
            // EOF
            if (!headersDone) {
                if (reused && !responseSeen && !self.isCancelled) { result = SHExchangeRetry; goto out; }
                if (error) *error = SHMakeError(SHErrorBadResponse, L(@"The server closed the connection without responding."));
                goto out;
            }
            // The body ends with the connection (also for incomplete chunked / content-length bodies).
            [self consumeBody:buffer];
            if ((self.chunked || self.contentLength >= 0) && !self.isCancelled) {
                SHLog(@"HTTP body ended early (chunked=%d, received=%lld) for %@", self.chunked, self.bodyReceived, self.url);
            }
            self.connectionClose = YES;
            bodyDone = YES;
            break;
        }
        responseSeen = YES;
        [buffer appendBytes:tmp length:(NSUInteger)n];
        if (!headersDone) {
            NSError *hErr = nil;
            int rc = 0;
            while (!headersDone) {
                rc = [self parseHeadersFromBuffer:buffer error:&hErr];
                if (rc < 0) {
                    if (error) *error = hErr ?: SHMakeError(SHErrorBadResponse, L(@"The server sent an invalid response."));
                    goto out;
                }
                if (rc == 0) break;          // need more bytes
                if (rc == 2) continue;       // interim response, parse the next block
                headersDone = YES;
            }
            if (!headersDone) continue;
            if (_tHead <= 0) _tHead = CFAbsoluteTimeGetCurrent();
            if (reused) [socket setReadTimeoutMs:(uint32_t)(self.readTimeout * 1000)];
            NSInteger status = self.statusCode;
            SHHTTPHeadersBlock hb = self.onHeaders;
            self.onHeaders = nil;
            if (hb) hb(status, self.responseHeaders);
            if (self.isCancelled) {
                if (error) *error = SHMakeError(SHErrorCancelled, L(@"Cancelled"));
                goto out;
            }
            if (self.noBody) {
                bodyDone = YES;
                break;
            }
        }
        if ([self consumeBody:buffer]) bodyDone = YES;
        if (self.bodyError) {
            if (error) *error = SHMakeError(SHErrorBadResponse, L(@"Content decoding failed."));
            goto out;
        }
    }
    // Decide whether the connection can carry another request.
    BOOL framed = self.noBody || (self.chunked && self.chunkState == SHChunkStateDone) ||
                  (!self.chunked && self.contentLength >= 0 && self.bodyReceived >= self.contentLength);
    self.keepAlive = framed && !self.connectionClose && !self.isCancelled && !self.bodyError && buffer.length == 0 && socket.isConnected;
    result = SHExchangeDone;
out:
    free(tmp);
    return result;
}

- (void)run
{
    _t0 = CFAbsoluteTimeGetCurrent();
    // Limit the number of simultaneous connections (TLS handshakes are CPU heavy on this hardware).
    // The main document of a page never waits: it must not sit behind stuck subresource loads.
    if (!self.highPriority) {
        dispatch_semaphore_t slots = SHConnectionSlots();
        while (dispatch_semaphore_wait(slots, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(100 * NSEC_PER_MSEC))) != 0) {
            if (self.isCancelled) {
                [self finishWithError:SHMakeError(SHErrorCancelled, L(@"Cancelled"))];
                return;
            }
        }
        self.hasSlot = YES;
    }
    _tSlot = CFAbsoluteTimeGetCurrent();
    if (self.isCancelled) {
        [self finishWithError:SHMakeError(SHErrorCancelled, L(@"Cancelled"))];
        return;
    }

    NSString *key = [self poolKey];
    SHConnectionPool *pool = [SHConnectionPool shared];
    SHTLSSocket *socket = [pool checkoutSocketForKey:key];
    BOOL reused = (socket != nil);
    NSError *error = nil;
    if (!socket) {
        socket = [self connectWithError:&error];
        if (!socket) {
            [self finishWithError:error];
            return;
        }
    }
    _tConn = CFAbsoluteTimeGetCurrent();
    _reusedConnection = reused;
    self.socket = socket;
    if (self.isCancelled) {
        [self finishWithError:SHMakeError(SHErrorCancelled, L(@"Cancelled"))];
        return;
    }

    BOOL retried = NO;
    for (;;) {
        NSError *err = nil;
        SHExchangeResult result = [self exchangeOnSocket:socket reused:reused error:&err];
        if (result == SHExchangeRetry && !retried) {
            retried = YES;
            reused = NO;
            [socket close];
            [self resetResponseState];
            socket = [self connectWithError:&err];
            if (!socket) {
                self.socket = nil;
                [self finishWithError:err];
                return;
            }
            _tConn = CFAbsoluteTimeGetCurrent();
            _reusedConnection = NO;
            _tHead = 0;
            self.socket = socket;
            if (self.isCancelled) {
                [self finishWithError:SHMakeError(SHErrorCancelled, L(@"Cancelled"))];
                return;
            }
            continue;
        }
        if (result == SHExchangeDone) {
            if (self.keepAlive) {
                self.socket = nil;   // finishWithError must not close it
                [pool checkinSocket:socket forKey:key];
            }
            [self finishWithError:nil];
        } else {
            [self finishWithError:err ?: SHMakeError(SHErrorConnectionLost, L(@"Connection lost."))];
        }
        return;
    }
}

@end
