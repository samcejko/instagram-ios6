#import "SHLegacyCollections.h"
#import "SHMediaProxy.h"
#import "SHHTTPRequest.h"
#import "SHLiveRemux.h"
#import "SHSettings.h"
#import "SHCommon.h"

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <poll.h>

static const NSUInteger SHProxyMaxFileEntries = 3000;      // (a live stream registers every segment it lists)
static const NSUInteger SHProxyMaxPlaylistEntries = 300;
static const int SHProxyMaxRedirects = 6;

typedef NS_ENUM(NSInteger, SHProxyEntryKind) {
    SHProxyEntryFile = 0,       // /<secret>/u/<id>/<name>: one absolute URL
    SHProxyEntryDirectory,      // /<secret>/d/<id>/<path>: a playlist and whatever it names relative to itself
    SHProxyEntryText,           // /<secret>/t/<id>/<name>: a playlist written by the app
    SHProxyEntryLive,           // /<secret>/l/<id>/live.m3u8 and <n>.ts: a live FLV stream repacked on the device
};

@interface SHProxyEntry : NSObject
@property (nonatomic) SHProxyEntryKind kind;
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, strong) SHLiveRemux *remux;
@property (nonatomic, copy) NSString *text;
@property (nonatomic, copy) NSDictionary *upstreamHeaders;   // extra headers to send to the origin (TikTok CDN wants Referer/UA)
@end

@implementation SHProxyEntry
@end

@interface SHMediaProxy ()
@property (atomic) int listenFD;
@property (atomic) uint16_t port;
@property (atomic, copy) NSString *secret;
@property (atomic) NSUInteger generation;
@property (atomic) BOOL adBreakActive;
@property (atomic) NSTimeInterval lastRequestTime;
@property (nonatomic, strong) NSMutableDictionary *entries;     // id -> SHProxyEntry
@property (nonatomic, strong) NSMutableDictionary *idsByURL;    // "u:"/"d:" + absolute URL -> id
@property (nonatomic, strong) NSMutableArray *fileOrder;        // ids of file entries, oldest first
@property (nonatomic, strong) NSMutableArray *playlistOrder;    // ids of directory and text entries, oldest first
@property (nonatomic) NSUInteger nextId;
@property (nonatomic, strong) NSMutableDictionary *servedCounts;   // content type -> @(requests)
@property (nonatomic, strong) NSMutableDictionary *servedBytes;    // content type -> @(bytes)
@end

static NSString * const SHProxyPlaylistName = @"playlist.m3u8";

static BOOL SHSendAll(int fd, const void *bytes, size_t length)
{
    const char *p = bytes;
    while (length > 0) {
        ssize_t n = send(fd, p, length, 0);
        if (n < 0) { if (errno == EINTR) continue; return NO; }
        if (n == 0) return NO;
        p += n;
        length -= (size_t)n;
    }
    return YES;
}

static BOOL SHSendString(int fd, NSString *s)
{
    NSData *d = [s dataUsingEncoding:NSISOLatin1StringEncoding allowLossyConversion:YES];
    return SHSendAll(fd, d.bytes, d.length);
}

static NSString *SHReasonPhrase(NSInteger status)
{
    switch (status) {
        case 200: return @"OK";
        case 206: return @"Partial Content";
        case 304: return @"Not Modified";
        case 403: return @"Forbidden";
        case 404: return @"Not Found";
        case 416: return @"Range Not Satisfiable";
        case 502: return @"Bad Gateway";
        default: return @"Status";
    }
}

static void SHSendStatus(int fd, NSInteger status)
{
    SHSendString(fd, [NSString stringWithFormat:@"HTTP/1.1 %ld %@\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", (long)status, SHReasonPhrase(status)]);
}

// What the player should take the file for: YouTube's servers call every segment "application/octet-stream" and
// their URLs carry no file extension, so the first bytes decide (MPEG-TS starts with 0x47, the packed AAC of the
// sound renditions with an ID3 tag or an ADTS sync word, MP4 with "ftyp").
static NSString *SHContentTypeForPath(NSString *path, NSString *upstream, NSData *firstBytes)
{
    // (the bytes first: YouTube's sound segments are called ".ts" too, and they are packed AAC, not transport streams)
    if (firstBytes.length >= 8) {
        const unsigned char *b = firstBytes.bytes;
        if (b[0] == 0x47 && (firstBytes.length < 189 || b[188] == 0x47)) return @"video/MP2T";
        if (b[0] == 'I' && b[1] == 'D' && b[2] == '3') return @"audio/aac";
        if (b[0] == 0xFF && (b[1] & 0xF6) == 0xF0) return @"audio/aac";
        if (b[4] == 'f' && b[5] == 't' && b[6] == 'y' && b[7] == 'p') return @"video/mp4";
    }
    NSString *ext = [[path pathExtension] lowercaseString];
    if ([ext isEqualToString:@"ts"]) return @"video/MP2T";
    if ([ext isEqualToString:@"mp4"] || [ext isEqualToString:@"m4v"]) return @"video/mp4";
    if ([ext isEqualToString:@"m4s"]) return @"video/iso.segment";
    if ([ext isEqualToString:@"aac"]) return @"audio/aac";
    if ([ext isEqualToString:@"m3u8"]) return @"application/vnd.apple.mpegurl";
    if (upstream.length && [upstream rangeOfString:@"octet-stream"].location == NSNotFound) return upstream;
    return @"application/octet-stream";
}

// The response head for the player: the headers of the file (the length only when the body is passed as it came)
static NSString *SHResponseHead(NSInteger status, NSDictionary *headers, NSString *contentType, BOOL keepLength)
{
    NSMutableString *s = [NSMutableString stringWithFormat:@"HTTP/1.1 %ld %@\r\n", (long)status, SHReasonPhrase(status)];
    if (contentType.length) [s appendFormat:@"Content-Type: %@\r\n", contentType];
    NSArray *names = @[@[@"content-length", @"Content-Length"], @[@"content-range", @"Content-Range"],
                       @[@"accept-ranges", @"Accept-Ranges"], @[@"last-modified", @"Last-Modified"], @[@"etag", @"ETag"]];
    for (NSArray *n in names) {
        NSString *v = [headers objectForKey:[n objectAtIndex:0]];
        if (!v.length || ([[n objectAtIndex:0] isEqualToString:@"content-length"] && !keepLength)) continue;
        [s appendFormat:@"%@: %@\r\n", [n objectAtIndex:1], v];
    }
    [s appendString:@"Connection: close\r\n\r\n"];
    return s;
}

@implementation SHMediaProxy

+ (instancetype)shared
{
    static SHMediaProxy *proxy;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        proxy = [[SHMediaProxy alloc] init];
        [proxy ensureRunning];
    });
    return proxy;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _listenFD = -1;
        _entries = [NSMutableDictionary dictionary];
        _idsByURL = [NSMutableDictionary dictionary];
        _fileOrder = [NSMutableArray array];
        _playlistOrder = [NSMutableArray array];
        _servedCounts = [NSMutableDictionary dictionary];
        _servedBytes = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)countServed:(NSString *)contentType bytes:(NSUInteger)bytes
{
    NSString *key = contentType.length ? contentType : @"?";
    @synchronized (self.servedCounts) {
        if (bytes == 0) SHLegacyDictionarySet(self.servedCounts, key, @([[self.servedCounts objectForKey:key] unsignedIntegerValue] + 1));
        else SHLegacyDictionarySet(self.servedBytes, key, @([[self.servedBytes objectForKey:key] unsignedLongLongValue] + bytes));
    }
}

- (NSString *)statsDescription
{
    NSMutableArray *parts = [NSMutableArray array];
    @synchronized (self.servedCounts) {
        for (NSString *key in [[self.servedCounts allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
            [parts addObject:[NSString stringWithFormat:@"%@: %@ (%.1f MB)", key, [self.servedCounts objectForKey:key], [[self.servedBytes objectForKey:key] unsignedLongLongValue] / 1048576.0]];
        }
    }
    return parts.count ? [parts componentsJoinedByString:@", "] : @"nothing served yet";
}

#pragma mark - Server

// Whether something still answers on the port (a socket the system reclaimed refuses the connection)
static BOOL SHProxyPortAnswers(uint16_t port)
{
    int fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (fd < 0) return NO;
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_len = sizeof(addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    BOOL ok = NO;
    int rc = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
    if (rc == 0) {
        ok = YES;
    } else if (errno == EINPROGRESS) {
        struct pollfd pfd = { fd, POLLOUT, 0 };
        if (poll(&pfd, 1, 300) > 0) {
            int soerr = 0;
            socklen_t len = sizeof(soerr);
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &len);
            ok = soerr == 0;
        }
    }
    close(fd);
    return ok;
}

- (BOOL)ensureRunning
{
    @synchronized (self) {
        if (self.listenFD >= 0) {
            if (SHProxyPortAnswers(self.port)) return YES;
            SHLog(@"Media proxy: port %u does not answer any more, starting again", self.port);
            close(self.listenFD);   // (the accept thread of that socket ends with the error this gives it)
            self.listenFD = -1;
        }
        return [self startServer];
    }
}

// (with the lock held)
- (BOOL)startServer
{
    int fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (fd < 0) { SHLog(@"Media proxy: no socket (%d)", errno); return NO; }
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_len = sizeof(addr);
    addr.sin_family = AF_INET;
    addr.sin_port = 0;   // (any free port)
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    socklen_t length = sizeof(addr);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, 32) != 0 || getsockname(fd, (struct sockaddr *)&addr, &length) != 0) {
        SHLog(@"Media proxy: cannot listen (%d)", errno);
        close(fd);
        return NO;
    }
    NSMutableString *secret = [NSMutableString string];
    for (int i = 0; i < 4; i++) [secret appendFormat:@"%08x", arc4random()];
    self.secret = secret;
    self.port = ntohs(addr.sin_port);
    self.listenFD = fd;
    self.generation = self.generation + 1;
    [self.entries removeAllObjects];
    [self.idsByURL removeAllObjects];
    [self.fileOrder removeAllObjects];
    [self.playlistOrder removeAllObjects];
    [NSThread detachNewThreadSelector:@selector(acceptLoop:) toTarget:self withObject:@(fd)];
    SHLog(@"Media proxy listening on 127.0.0.1:%u", self.port);
    return YES;
}

- (void)acceptLoop:(NSNumber *)socketNumber
{
    @autoreleasepool { [[NSThread currentThread] setName:@"SHMediaProxy"]; }
    int listenFD = socketNumber.intValue;
    int failures = 0;
    for (;;) {
        @autoreleasepool {
            int c = accept(listenFD, NULL, NULL);
            if (c < 0) {
                int err = errno;
                if (err == EINTR) continue;
                if (self.listenFD != listenFD) return;   // closed by ensureRunning: another socket took over
                if (++failures < 6) { usleep(100000); continue; }
                SHLog(@"Media proxy: accept keeps failing (%d), the listening socket is given up", err);
                @synchronized (self) {
                    if (self.listenFD == listenFD) {
                        close(listenFD);
                        self.listenFD = -1;
                    }
                }
                return;
            }
            failures = 0;
            int on = 1;
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
            [NSThread detachNewThreadSelector:@selector(serveConnection:) toTarget:self withObject:@(c)];
        }
    }
}

#pragma mark - Entries

// (with the lock held)
- (NSString *)addEntry:(SHProxyEntry *)entry key:(NSString *)key
{
    NSString *ident = [NSString stringWithFormat:@"%lu", (unsigned long)++self.nextId];
    SHLegacyDictionarySet(self.entries, ident, entry);
    if (key) SHLegacyDictionarySet(self.idsByURL, key, ident);
    NSMutableArray *order = entry.kind == SHProxyEntryFile ? self.fileOrder : self.playlistOrder;
    NSUInteger limit = entry.kind == SHProxyEntryFile ? SHProxyMaxFileEntries : SHProxyMaxPlaylistEntries;
    [order addObject:ident];
    while (order.count > limit) {
        NSString *old = [order objectAtIndex:0];
        SHProxyEntry *e = [self.entries objectForKey:old];
        if (e.url) {
            NSString *prefix = e.kind == SHProxyEntryFile ? @"u:" : @"d:";
            [self.idsByURL removeObjectForKey:[prefix stringByAppendingString:e.url.absoluteString]];
        }
        [e.remux stop];
        [self.entries removeObjectForKey:old];
        [order removeObjectAtIndex:0];
    }
    return ident;
}

- (NSString *)proxyURLForURL:(NSURL *)url
{
    return [self proxyURLForURL:url upstreamHeaders:nil];
}

- (NSString *)proxyURLForURL:(NSURL *)url upstreamHeaders:(NSDictionary *)upstreamHeaders
{
    NSString *absolute = url.absoluteString;
    if (!absolute.length || !url.host.length) return nil;
    BOOL playlist = [[url.path lowercaseString] hasSuffix:@".m3u8"];
    @synchronized (self) {
        if (self.listenFD < 0) return nil;
        NSString *key = [(playlist ? @"d:" : @"u:") stringByAppendingString:absolute];
        NSString *ident = [self.idsByURL objectForKey:key];
        if (!ident) {
            SHProxyEntry *entry = [[SHProxyEntry alloc] init];
            entry.kind = playlist ? SHProxyEntryDirectory : SHProxyEntryFile;
            entry.url = url;
            entry.upstreamHeaders = upstreamHeaders;
            ident = [self addEntry:entry key:key];
        } else if (upstreamHeaders.count) {
            ((SHProxyEntry *)[self.entries objectForKey:ident]).upstreamHeaders = upstreamHeaders;
        }
        if (playlist) {
            return [NSString stringWithFormat:@"http://127.0.0.1:%u/%@/d/%@/%@", self.port, self.secret, ident, SHProxyPlaylistName];
        }
        // (the extension tells the player the kind of file; the names themselves are hundreds of characters long)
        NSString *ext = [[url.path pathExtension] lowercaseString];
        NSCharacterSet *other = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
        if (!ext.length || ext.length > 5 || [ext rangeOfCharacterFromSet:other].location != NSNotFound) ext = @"bin";
        return [NSString stringWithFormat:@"http://127.0.0.1:%u/%@/u/%@/file.%@", self.port, self.secret, ident, ext];
    }
}

- (NSString *)proxyURLForPlaylistText:(NSString *)text
{
    if (!text.length) return nil;
    @synchronized (self) {
        if (self.listenFD < 0) return nil;
        SHProxyEntry *entry = [[SHProxyEntry alloc] init];
        entry.kind = SHProxyEntryText;
        entry.text = text;
        NSString *ident = [self addEntry:entry key:nil];
        return [NSString stringWithFormat:@"http://127.0.0.1:%u/%@/t/%@/master.m3u8", self.port, self.secret, ident];
    }
}

- (NSString *)proxyURLForLiveFLV:(NSURL *)url headers:(NSDictionary *)headers
{
    if (!url.host.length) return nil;
    @synchronized (self) {
        if (self.listenFD < 0) return nil;
        SHProxyEntry *entry = [[SHProxyEntry alloc] init];
        entry.kind = SHProxyEntryLive;
        entry.url = url;
        entry.remux = [[SHLiveRemux alloc] initWithURL:url headers:headers];
        NSString *ident = [self addEntry:entry key:nil];
        [entry.remux start];
        return [NSString stringWithFormat:@"http://127.0.0.1:%u/%@/l/%@/live.m3u8", self.port, self.secret, ident];
    }
}

- (void)stopLiveStreams
{
    @synchronized (self) {
        for (SHProxyEntry *e in [self.entries allValues]) if (e.kind == SHProxyEntryLive) [e.remux stop];
    }
}

- (BOOL)liveStreamRunning
{
    @synchronized (self) {
        for (SHProxyEntry *e in [self.entries allValues]) if (e.kind == SHProxyEntryLive && !e.remux.stopped) return YES;
    }
    return NO;
}

- (void)serveLive:(SHLiveRemux *)remux name:(NSString *)name method:(NSString *)method to:(int)fd
{
    if ([name isEqualToString:@"live.m3u8"]) {
        // the first time it waits for three segments (about six seconds of the stream): a live playlist with fewer
        // makes the player stall at once
        NSString *text = [remux playlistWaitingForSegments:3 timeout:25];
        if (!text) {
            if (remux.failure) SHLog(@"live: no playlist: %@", remux.failure);
            [self countServed:@"HTTP 502" bytes:0];
            SHSendStatus(fd, 502);
            return;
        }
        [self sendPlaylist:text method:method to:fd];
        return;
    }
    if ([name hasSuffix:@".ts"]) {
        NSData *data = [remux segment:(NSUInteger)[[name stringByDeletingPathExtension] integerValue] waiting:10];
        if (!data) { [self countServed:@"HTTP 404" bytes:0]; SHSendStatus(fd, 404); return; }
        NSString *head = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: video/MP2T\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n", (unsigned long)data.length];
        [self countServed:@"video/MP2T" bytes:0];
        if (SHSendString(fd, head) && ![method isEqualToString:@"HEAD"]) {
            SHSendAll(fd, data.bytes, data.length);
            [self countServed:@"video/MP2T" bytes:data.length];
        }
        return;
    }
    SHSendStatus(fd, 404);
}

- (void)resetPlaybackState
{
    self.adBreakActive = NO;
}

#pragma mark - Connections

- (void)serveConnection:(NSNumber *)socketNumber
{
    @autoreleasepool {
        int fd = socketNumber.intValue;
        [[NSThread currentThread] setName:@"SHMediaProxy connection"];
        struct timeval tv = { 30, 0 };
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        NSMutableData *buffer = [NSMutableData data];
        NSData *blank = [@"\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding];
        NSRange end = NSMakeRange(NSNotFound, 0);
        char chunk[4096];
        while (buffer.length < 32768) {
            ssize_t n = recv(fd, chunk, sizeof(chunk), 0);
            if (n <= 0) break;
            [buffer appendBytes:chunk length:(NSUInteger)n];
            end = [buffer rangeOfData:blank options:0 range:NSMakeRange(0, buffer.length)];
            if (end.location != NSNotFound) break;
        }
        if (end.location == NSNotFound) { close(fd); return; }
        NSString *head = [[NSString alloc] initWithData:[buffer subdataWithRange:NSMakeRange(0, end.location)] encoding:NSISOLatin1StringEncoding] ?: @"";
        NSArray *lines = [head componentsSeparatedByString:@"\r\n"];
        NSArray *requestLine = [lines.firstObject componentsSeparatedByString:@" "];
        NSString *method = requestLine.count >= 2 ? [[requestLine objectAtIndex:0] uppercaseString] : nil;
        NSMutableDictionary *headers = [NSMutableDictionary dictionary];
        for (NSUInteger i = 1; i < lines.count; i++) {
            NSRange colon = [[lines objectAtIndex:i] rangeOfString:@":"];
            if (colon.location == NSNotFound) continue;
            SHLegacyDictionarySet(headers, [[[lines objectAtIndex:i] substringToIndex:colon.location] lowercaseString], [[[lines objectAtIndex:i] substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]);
        }
        if (requestLine.count < 2 || !([method isEqualToString:@"GET"] || [method isEqualToString:@"HEAD"])) {
            SHSendStatus(fd, 404);
            close(fd);
            return;
        }
        self.lastRequestTime = [NSDate timeIntervalSinceReferenceDate];
        [self serveTarget:[requestLine objectAtIndex:1] method:method headers:headers to:fd];
        close(fd);
    }
}

// "/<secret>/<kind>/<id>/<rest>"
- (void)serveTarget:(NSString *)target method:(NSString *)method headers:(NSDictionary *)headers to:(int)fd
{
    NSArray *parts = [target componentsSeparatedByString:@"/"];
    if (parts.count < 5 || ![[parts objectAtIndex:1] isEqualToString:self.secret]) { [self countServed:@"HTTP 404" bytes:0]; SHSendStatus(fd, 404); return; }
    NSString *kind = [parts objectAtIndex:2];
    NSString *rest = [[parts subarrayWithRange:NSMakeRange(4, parts.count - 4)] componentsJoinedByString:@"/"];
    SHProxyEntry *entry;
    @synchronized (self) { entry = [self.entries objectForKey:[parts objectAtIndex:3]]; }
    if (self.logRequests) {
        NSString *range = [headers objectForKey:@"range"];
        SHLog(@"Proxy %@ %@/%@/%@%@ -> %@", method, kind, [parts objectAtIndex:3], rest.length > 40 ? [rest substringToIndex:40] : rest,
              range.length ? [NSString stringWithFormat:@" [%@]", range] : @"", entry ? (entry.url.host ?: @"text") : @"unknown entry");
    }
    if (!entry) { [self countServed:@"HTTP 404" bytes:0]; SHSendStatus(fd, 404); return; }

    if (entry.kind == SHProxyEntryText && [kind isEqualToString:@"t"]) {
        [self sendPlaylist:entry.text method:method to:fd];
        return;
    }
    if (entry.kind == SHProxyEntryLive && [kind isEqualToString:@"l"]) {
        [self serveLive:entry.remux name:rest method:method to:fd];
        return;
    }
    NSString *label = [NSString stringWithFormat:@"%@/%@", kind, [parts objectAtIndex:3]];
    if (entry.kind == SHProxyEntryFile && [kind isEqualToString:@"u"]) {
        [self relayURL:entry.url method:method headers:headers upstream:entry.upstreamHeaders viaDirectory:NO label:label to:fd];
        return;
    }
    if (entry.kind == SHProxyEntryDirectory && [kind isEqualToString:@"d"]) {
        NSURL *url = entry.url;
        NSString *name = rest;
        NSRange query = [name rangeOfString:@"?"];
        if (query.location != NSNotFound) name = [name substringToIndex:query.location];
        if (![name isEqualToString:SHProxyPlaylistName]) {
            // something the playlist names relative to itself
            if (!rest.length || [rest hasPrefix:@"/"] || [rest rangeOfString:@".."].location != NSNotFound) { SHSendStatus(fd, 404); return; }
            url = [[NSURL URLWithString:rest relativeToURL:entry.url] absoluteURL];
            if (!url.host.length) { SHSendStatus(fd, 404); return; }
        }
        [self relayURL:url method:method headers:headers upstream:entry.upstreamHeaders viaDirectory:YES label:label to:fd];
        return;
    }
    [self countServed:@"HTTP 404" bytes:0];
    SHSendStatus(fd, 404);
}

- (void)sendPlaylist:(NSString *)text method:(NSString *)method to:(int)fd
{
    NSData *body = [text dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    NSString *head = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nContent-Length: %lu\r\n"
                                                 "Cache-Control: no-cache\r\nConnection: close\r\n\r\n", (unsigned long)body.length];
    [self countServed:@"playlist" bytes:0];
    if (SHSendString(fd, head) && ![method isEqualToString:@"HEAD"]) {
        SHSendAll(fd, body.bytes, body.length);
        [self countServed:@"playlist" bytes:body.length];
    }
}

// One request of the player, through the app's network layer, on this thread: redirects followed here, the body
// passed on as it comes (a player that lets go ends the request), a playlist rewritten first.
- (void)relayURL:(NSURL *)startURL method:(NSString *)method headers:(NSDictionary *)playerHeaders upstream:(NSDictionary *)upstreamHeaders viaDirectory:(BOOL)viaDirectory label:(NSString *)label to:(int)fd
{
    NSURL *url = startURL;
    for (int hop = 0; hop < SHProxyMaxRedirects; hop++) {
        BOOL playlistByName = [[url.path lowercaseString] hasSuffix:@".m3u8"];
        NSMutableDictionary *h = [NSMutableDictionary dictionary];
        SHLegacyDictionarySet(h, @"Accept", @"*/*");
        // origin-specific headers (TikTok's CDN only serves with its Referer and a browser UA)
        for (NSString *k in upstreamHeaders) SHLegacyDictionarySet(h, k, [upstreamHeaders objectForKey:k]);
        if (!playlistByName) {
            if ([playerHeaders objectForKey:@"range"]) SHLegacyDictionarySet(h, @"Range", [playerHeaders objectForKey:@"range"]);
            if ([playerHeaders objectForKey:@"if-range"]) SHLegacyDictionarySet(h, @"If-Range", [playerHeaders objectForKey:@"if-range"]);
        }
        SHHTTPRequest *r = [[SHHTTPRequest alloc] initWithMethod:method URL:url];
        r.headers = h;
        r.verifyTLS = [SHSettings verifyTLS];
        r.highPriority = YES;   // (never behind image downloads)
        r.noCompression = !playlistByName;
        r.connectTimeout = 15;
        r.readTimeout = 30;
        __block NSURL *redirect = nil;
        __block BOOL playlist = NO, headSent = NO, broken = NO;
        __block NSInteger playlistStatus = 200;
        __block NSInteger pendingStatus = 200;
        __block NSDictionary *pendingHeaders = nil;
        __block BOOL pendingKeepLength = YES;
        __block NSString *servedType = nil;
        __block NSUInteger sentBytes = 0;
        NSMutableData *collected = [NSMutableData data];
        NSURL *current = url;
        __weak SHHTTPRequest *weakRequest = r;
        __weak SHMediaProxy *weakSelf = self;
        r.onHeaders = ^(NSInteger status, NSDictionary *hdrs) {
            NSString *location = [hdrs objectForKey:@"location"];
            if (status >= 300 && status < 400 && status != 304 && location.length) {
                redirect = [[NSURL URLWithString:location relativeToURL:current] absoluteURL];
                return;
            }
            NSString *type = [[hdrs objectForKey:@"content-type"] lowercaseString] ?: @"";
            playlist = status < 300 && (playlistByName || [type rangeOfString:@"mpegurl"].location != NSNotFound);
            if (playlist) { playlistStatus = status; return; }
            NSString *encoding = [[hdrs objectForKey:@"content-encoding"] lowercaseString] ?: @"";
            BOOL keepLength = !encoding.length || [encoding isEqualToString:@"identity"];
            if (status < 300 && status != 204) {
                // the type comes from the first bytes: the head waits for them (they follow right away)
                pendingStatus = status;
                pendingHeaders = hdrs;
                pendingKeepLength = keepLength;
                return;
            }
            headSent = YES;
            NSString *contentType = status < 300 ? SHContentTypeForPath(current.path, [hdrs objectForKey:@"content-type"], nil) : [hdrs objectForKey:@"content-type"];
            servedType = status < 300 ? contentType : [NSString stringWithFormat:@"HTTP %ld", (long)status];
            [weakSelf countServed:servedType bytes:0];
            if (!SHSendString(fd, SHResponseHead(status, hdrs, contentType, keepLength))) { broken = YES; [weakRequest cancel]; }
        };
        r.onData = ^(NSData *data) {
            if (redirect || broken) return;
            if (playlist) { [collected appendData:data]; return; }
            if (!headSent && pendingHeaders) {
                headSent = YES;
                NSString *contentType = SHContentTypeForPath(current.path, [pendingHeaders objectForKey:@"content-type"], data);
                servedType = contentType;
                [weakSelf countServed:servedType bytes:0];
                if (!SHSendString(fd, SHResponseHead(pendingStatus, pendingHeaders, contentType, pendingKeepLength))) { broken = YES; [weakRequest cancel]; return; }
            }
            if (!SHSendAll(fd, data.bytes, data.length)) { broken = YES; [weakRequest cancel]; return; }
            sentBytes += data.length;
            [weakSelf countServed:servedType bytes:data.length];
        };
        __block NSError *failure = nil;
        r.onComplete = ^(NSError *error) { failure = error; };
        [r runSynchronously];
        if (self.logRequests && !playlist && !redirect) {
            SHLog(@"Proxy %@ done: %@, %lu bytes%@%@", label, servedType ?: @"no head", (unsigned long)sentBytes, broken ? @", player let go" : @"",
                  failure ? [NSString stringWithFormat:@", %@", failure.localizedDescription] : @"");
        }
        if (broken) return;
        if (!headSent && pendingHeaders && !redirect) {
            // an empty body (or a HEAD request): the head goes out as it is
            headSent = YES;
            SHSendString(fd, SHResponseHead(pendingStatus, pendingHeaders, SHContentTypeForPath(current.path, [pendingHeaders objectForKey:@"content-type"], nil), pendingKeepLength));
        }
        if (redirect.host.length) { url = redirect; continue; }
        if (playlist) {
            if (failure) { SHLog(@"Media proxy: playlist %@ failed: %@", url.host, failure.localizedDescription); [self countServed:@"HTTP 502" bytes:0]; SHSendStatus(fd, 502); return; }
            NSString *text = [[NSString alloc] initWithData:collected encoding:NSUTF8StringEncoding] ?: [[NSString alloc] initWithData:collected encoding:NSISOLatin1StringEncoding] ?: @"";
            NSString *rewritten = [self rewritePlaylist:text baseURL:url viaDirectory:viaDirectory];
            if (self.logRequests) SHLog(@"Proxy playlist from %@: %lu bytes, status %ld, %lu lines", url.host, (unsigned long)collected.length, (long)playlistStatus, (unsigned long)[rewritten componentsSeparatedByString:@"\n"].count);
            [self sendPlaylist:rewritten method:method to:fd];
            return;
        }
        if (!headSent) {
            if (failure) SHLog(@"Media proxy: %@ failed: %@", url.host, failure.localizedDescription);
            [self countServed:@"HTTP 502" bytes:0];
            SHSendStatus(fd, 502);
        } else if (self.logRequests && failure) {
            SHLog(@"Proxy: %@ broke off: %@", url.host, failure.localizedDescription);
        }
        return;
    }
    [self countServed:@"HTTP 502" bytes:0];
    SHSendStatus(fd, 502);
}

#pragma mark - Playlists

// A playlist for the player: URIs through the proxy, and only the tags the HLS of 2012 knows. YouTube's live
// playlists carry #EXT-X-DATERANGE, #EXT-X-CUEPOINT and #EXT-X-PROGRAM-DATE-TIME lines on every reload.
- (NSString *)rewritePlaylist:(NSString *)text baseURL:(NSURL *)base viaDirectory:(BOOL)viaDirectory
{
    static NSRegularExpression *uriAttribute;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        uriAttribute = [NSRegularExpression regularExpressionWithPattern:@"URI=\"([^\"]+)\"" options:0 error:NULL];
    });
    NSMutableArray *out = [NSMutableArray array];
    BOOL media = NO, ad = NO;
    for (NSString *line in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *t = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (!t.length) continue;
        if ([t hasPrefix:@"#"]) {
            if ([t hasPrefix:@"#EXT-X-DATERANGE"]) {
                if ([t rangeOfString:@"stitched-ad"].location != NSNotFound) ad = YES;
                continue;
            }
            if ([t hasPrefix:@"#EXT-X-CUEPOINT"] || [t hasPrefix:@"#EXT-X-PROGRAM-DATE-TIME"] || [t hasPrefix:@"#EXT-X-SESSION-"] || [t hasPrefix:@"#EXT-X-INDEPENDENT-SEGMENTS"]) continue;
            if ([t hasPrefix:@"#EXTINF"]) media = YES;
            NSArray *found = [uriAttribute matchesInString:t options:0 range:NSMakeRange(0, t.length)];
            if (!found.count) { [out addObject:t]; continue; }
            NSMutableString *m = [t mutableCopy];
            for (NSTextCheckingResult *r in [found reverseObjectEnumerator]) {
                NSURL *abs = [[NSURL URLWithString:[t substringWithRange:[r rangeAtIndex:1]] relativeToURL:base] absoluteURL];
                NSString *proxied = abs ? [self proxyURLForURL:abs] : nil;
                if (proxied) [m replaceCharactersInRange:[r rangeAtIndex:1] withString:proxied];
            }
            [out addObject:m];
            continue;
        }
        // a URI line: what the directory entry reaches by itself stays as it is (thousands of lines in a long video)
        BOOL hasScheme = [t rangeOfString:@"://"].location != NSNotFound;
        if (viaDirectory && !hasScheme && ![t hasPrefix:@"/"] && [t rangeOfString:@".."].location == NSNotFound) {
            [out addObject:t];
            continue;
        }
        NSURL *abs = [[NSURL URLWithString:t relativeToURL:base] absoluteURL];
        [out addObject:(abs ? [self proxyURLForURL:abs] : nil) ?: t];
    }
    if (media) self.adBreakActive = ad;
    return [[out componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
}

@end
