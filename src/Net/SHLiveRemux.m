#import "SHLiveRemux.h"
#import "SHHTTPRequest.h"
#import "SHSettings.h"
#import "SHCommon.h"

static const double SHLiveTargetSeconds = 2.0;      // a segment ends at the first key frame after this long
static const NSUInteger SHLiveWindow = 6;           // segments kept (and listed)
static const NSTimeInterval SHLiveIdleSeconds = 30; // nobody asked for this long: the player is gone, stop reading
static const int64_t SHLiveLead = 90000;            // a second added to every time stamp (none comes out negative)
static const NSUInteger SHLiveMaxPending = 4 * 1024 * 1024;
static const uint16_t kPMTPid = 0x1000, kVideoPid = 0x100, kAudioPid = 0x101;

static inline uint32_t SHBE32(const uint8_t *p) { return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3]; }
static inline uint32_t SHBE24(const uint8_t *p) { return ((uint32_t)p[0] << 16) | ((uint32_t)p[1] << 8) | p[2]; }

#pragma mark - MPEG-TS writing (as in Tubie's remux, with a sound stream beside the pictures)

// MPEG-2 CRC32 (the one of PSI tables)
static uint32_t SHCRC32(const uint8_t *data, NSUInteger length)
{
    uint32_t crc = 0xFFFFFFFF;
    for (NSUInteger i = 0; i < length; i++) {
        crc ^= (uint32_t)data[i] << 24;
        for (int k = 0; k < 8; k++) crc = (crc & 0x80000000) ? (crc << 1) ^ 0x04C11DB7 : crc << 1;
    }
    return crc;
}

// One PSI section as a single TS packet (pointer field first)
static void SHWriteSection(NSMutableData *out, uint16_t pid, uint8_t *cc, const uint8_t *section, NSUInteger length)
{
    uint8_t packet[188];
    memset(packet, 0xFF, sizeof(packet));
    packet[0] = 0x47;
    packet[1] = 0x40 | (pid >> 8);
    packet[2] = pid & 0xFF;
    packet[3] = 0x10 | (*cc & 0x0F);
    *cc = (*cc + 1) & 0x0F;
    packet[4] = 0;   // pointer field
    memcpy(packet + 5, section, MIN(length, (NSUInteger)183));
    [out appendBytes:packet length:188];
}

// PAT, and a PMT with H.264 on the video PID (which also carries the clock) and ADTS AAC on the audio PID
static void SHWriteTables(NSMutableData *out, uint8_t *patCC, uint8_t *pmtCC)
{
    uint8_t pat[16] = { 0x00, 0xB0, 0x0D, 0x00, 0x01, 0xC1, 0x00, 0x00, 0x00, 0x01, (uint8_t)(0xE0 | (kPMTPid >> 8)), (uint8_t)(kPMTPid & 0xFF) };
    uint32_t crc = SHCRC32(pat, 12);
    pat[12] = crc >> 24; pat[13] = crc >> 16; pat[14] = crc >> 8; pat[15] = crc;
    SHWriteSection(out, 0, patCC, pat, 16);
    uint8_t pmt[26] = { 0x02, 0xB0, 0x17, 0x00, 0x01, 0xC1, 0x00, 0x00,
                        (uint8_t)(0xE0 | (kVideoPid >> 8)), (uint8_t)(kVideoPid & 0xFF),   // PCR PID
                        0xF0, 0x00,                                                        // no program info
                        0x1B, (uint8_t)(0xE0 | (kVideoPid >> 8)), (uint8_t)(kVideoPid & 0xFF), 0xF0, 0x00,   // H.264
                        0x0F, (uint8_t)(0xE0 | (kAudioPid >> 8)), (uint8_t)(kAudioPid & 0xFF), 0xF0, 0x00 }; // AAC (ADTS)
    crc = SHCRC32(pmt, 22);
    pmt[22] = crc >> 24; pmt[23] = crc >> 16; pmt[24] = crc >> 8; pmt[25] = crc;
    SHWriteSection(out, kPMTPid, pmtCC, pmt, 26);
}

// A whole PES packet as TS packets. The first one carries the clock (pcr >= 0) and the random access flag of key
// frames; the last one is padded with an adaptation field.
static void SHWritePES(NSMutableData *out, uint16_t pid, uint8_t *cc, const uint8_t *pes, NSUInteger length, int64_t pcr, BOOL keyframe)
{
    NSUInteger offset = 0;
    BOOL first = YES;
    uint8_t packet[188];
    while (offset < length || first) {
        NSUInteger remaining = length - offset;
        NSUInteger adaptation = 0;   // bytes after the 4-byte header, the length byte included
        uint8_t flags = 0;
        if (first && (pcr >= 0 || keyframe)) {
            adaptation = 2;
            if (keyframe) flags |= 0x40;
            if (pcr >= 0) { flags |= 0x10; adaptation += 6; }
        }
        NSUInteger room = 184 - adaptation;
        if (remaining < room) {
            adaptation += room - remaining;   // stuffing fills the packet
            room = remaining;
        }
        packet[0] = 0x47;
        packet[1] = (first ? 0x40 : 0x00) | ((pid >> 8) & 0x1F);
        packet[2] = pid & 0xFF;
        packet[3] = (adaptation ? 0x30 : 0x10) | (*cc & 0x0F);
        *cc = (*cc + 1) & 0x0F;
        NSUInteger p = 4;
        if (adaptation) {
            packet[p++] = (uint8_t)(adaptation - 1);
            if (adaptation > 1) {
                packet[p++] = flags;
                NSUInteger written = 2;
                if (flags & 0x10) {
                    uint64_t base = (uint64_t)pcr & 0x1FFFFFFFFULL;
                    packet[p++] = base >> 25; packet[p++] = base >> 17; packet[p++] = base >> 9; packet[p++] = base >> 1;
                    packet[p++] = ((base & 1) << 7) | 0x7E; packet[p++] = 0;
                    written += 6;
                }
                while (written < adaptation) { packet[p++] = 0xFF; written++; }
            }
        }
        memcpy(packet + p, pes + offset, room);
        offset += room;
        [out appendBytes:packet length:188];
        first = NO;
    }
}

static void SHAppendTimestamp(NSMutableData *pes, uint8_t prefix, int64_t ts)
{
    uint64_t t = (uint64_t)ts & 0x1FFFFFFFFULL;
    uint8_t b[5] = { (uint8_t)((prefix << 4) | ((t >> 29) & 0x0E) | 1), (uint8_t)(t >> 22), (uint8_t)(((t >> 14) & 0xFE) | 1), (uint8_t)(t >> 7), (uint8_t)(((t << 1) & 0xFE) | 1) };
    [pes appendBytes:b length:5];
}

#pragma mark - Segments

@interface SHLiveSegment : NSObject
@property (nonatomic) NSUInteger sequence;
@property (nonatomic) double duration;
@property (nonatomic, strong) NSData *data;
@end

@implementation SHLiveSegment
@end

@interface SHLiveRemux ()
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, copy) NSDictionary *headers;
@property (atomic, strong) SHHTTPRequest *request;
@property (atomic) BOOL stopped;
@property (atomic, copy) NSString *failure;
@property (atomic) NSTimeInterval lastAsked;
@property (nonatomic, strong) NSMutableArray *segments;     // SHLiveSegment, oldest first (guarded by self)
@end

@implementation SHLiveRemux {
    // the reading thread's own state
    NSMutableData *_pending;          // FLV bytes not parsed yet
    BOOL _headerDone;
    NSData *_sps, *_pps;
    NSUInteger _nalLengthSize;
    BOOL _haveAudioConfig;
    NSInteger _audioObjectType, _audioFrequencyIndex, _audioChannels;
    NSMutableData *_current;          // the segment being made
    int64_t _currentStart;            // its first time stamp (90 kHz), -1 before the first key frame
    NSUInteger _nextSequence;
    uint8_t _patCC, _pmtCC, _videoCC, _audioCC;
    NSMutableData *_pes;
    // TikTok's CDN ends every pull after half a minute or so; the next one may start its clock anywhere
    BOOL _rebase;                     // a new pull: its first key frame follows on from the last time stamp sent
    int64_t _tsOffset;                // added to the pull's own time stamps
    int64_t _lastTs;                  // the latest time stamp sent (pictures or sound)
    NSUInteger _mediaTags;            // pictures and sound frames read, all pulls together
}

- (instancetype)initWithURL:(NSURL *)url headers:(NSDictionary *)headers
{
    if ((self = [super init])) {
        _url = url;
        _headers = [headers copy];
        _segments = [NSMutableArray array];
        _pending = [NSMutableData data];
        _pes = [NSMutableData dataWithCapacity:262144];
        _currentStart = -1;
        _nalLengthSize = 4;
        _lastAsked = [NSDate timeIntervalSinceReferenceDate];
    }
    return self;
}

- (void)start { [NSThread detachNewThreadSelector:@selector(run) toTarget:self withObject:nil]; }

- (void)stop
{
    self.stopped = YES;
    [self.request cancel];
}

- (void)failWith:(NSString *)why
{
    if (self.stopped) return;
    self.failure = why;
    [self stop];
}

// The reading thread. TikTok's CDN ends every pull after half a minute or so (with or without its cookies; the address
// itself lasts two weeks): the next pull carries on at once, its time stamps joined to the last ones, so the player
// sees one unbroken stream. Pulls that bring no pictures three times in a row mean the stream is gone.
- (void)run
{
    @autoreleasepool {
        [[NSThread currentThread] setName:@"SHLiveRemux"];
        NSInteger failures = 0, pulls = 0;
        while (!self.stopped) {
            NSTimeInterval began = [NSDate timeIntervalSinceReferenceDate];
            NSUInteger tagsBefore = _mediaTags;
            NSString *why = nil;
            BOOL completed = [self pullOnce:&why];
            if (self.stopped) break;
            pulls++;
            if (completed && _mediaTags > tagsBefore) {
                failures = 0;
                SHLog(@"live: the CDN ended pull %ld after %.0f s, pulling again", (long)pulls, [NSDate timeIntervalSinceReferenceDate] - began);
            } else {
                SHLog(@"live: pull %ld brought nothing (%@)", (long)pulls, why ?: @"no pictures");
                if (++failures >= 3) {
                    self.failure = why ?: L(@"The live stream ended.");
                    break;
                }
                [NSThread sleepForTimeInterval:1.0];
            }
            [_pending setLength:0];
            _headerDone = NO;
            _rebase = YES;
        }
        self.stopped = YES;
        SHLog(@"live: reading ended (%@), %lu segments made", self.failure ?: @"stopped", (unsigned long)_nextSequence);
    }
}

// One pull: the FLV comes in as it is sent (redirects followed here) and is parsed as it comes. YES when the CDN ended
// it in good order; NO with the reason otherwise.
- (BOOL)pullOnce:(NSString **)why
{
    NSURL *url = self.url;
    for (int hop = 0; hop < 5 && !self.stopped; hop++) {
        SHHTTPRequest *r = [[SHHTTPRequest alloc] initWithMethod:@"GET" URL:url];
        NSMutableDictionary *h = [NSMutableDictionary dictionaryWithDictionary:self.headers ?: @{}];
        h[@"Accept"] = @"*/*";
        r.headers = h;
        r.verifyTLS = [SHSettings verifyTLS];
        r.highPriority = YES;
        r.noCompression = YES;
        r.connectTimeout = 15;
        r.readTimeout = 20;
        __block NSInteger status = 0;
        __block NSURL *redirect = nil;
        __weak SHLiveRemux *weakSelf = self;
        __weak SHHTTPRequest *weakRequest = r;
        NSURL *current = url;
        r.onHeaders = ^(NSInteger s, NSDictionary *hdrs) {
            status = s;
            if (s >= 300 && s < 400 && [hdrs[@"location"] length]) redirect = [[NSURL URLWithString:hdrs[@"location"] relativeToURL:current] absoluteURL];
        };
        r.onData = ^(NSData *data) {
            SHLiveRemux *me = weakSelf;
            if (!me || me.stopped) { [weakRequest cancel]; return; }
            if (status >= 300) return;
            @autoreleasepool { [me consume:data]; }
            if ([NSDate timeIntervalSinceReferenceDate] - me.lastAsked > SHLiveIdleSeconds) {
                SHLog(@"live: nobody watching any more, stopping");
                [me stop];
            }
        };
        __block NSError *failure = nil;
        r.onComplete = ^(NSError *error) { failure = error; };
        self.request = r;
        [r runSynchronously];
        if (redirect.host.length) { url = redirect; continue; }
        if (failure) { if (why) *why = failure.localizedDescription; return NO; }
        if (status < 200 || status >= 300) { if (why) *why = [NSString stringWithFormat:@"HTTP %ld", (long)status]; return NO; }
        return YES;
    }
    if (why) *why = @"too many redirects";
    return NO;
}

// A frame's time on the output's clock: 90 kHz, a second ahead (nothing comes out negative), and unbroken across the
// pulls - the first key frame of a new pull follows a frame's length after the last time stamp sent
- (int64_t)timestamp:(uint32_t)ms
{
    int64_t raw = (int64_t)ms * 90 + SHLiveLead;
    if (_rebase) {
        _rebase = NO;
        if (_lastTs > 0) _tsOffset = _lastTs + 3000 - raw;
    }
    int64_t ts = raw + _tsOffset;
    if (ts > _lastTs) _lastTs = ts;
    _mediaTags++;
    return ts;
}

#pragma mark - FLV

- (void)consume:(NSData *)data
{
    [_pending appendData:data];
    const uint8_t *b = _pending.bytes;
    NSUInteger n = _pending.length, o = 0;
    if (!_headerDone) {
        if (n < 13) return;
        if (b[0] != 'F' || b[1] != 'L' || b[2] != 'V') { [self failWith:@"not an FLV stream"]; return; }
        uint32_t headerSize = SHBE32(b + 5);
        if (headerSize < 9 || headerSize > 64) { [self failWith:@"a broken FLV header"]; return; }
        if (n < headerSize + 4) return;
        o = headerSize + 4;   // the header and the first "previous tag size"
        _headerDone = YES;
    }
    while (o + 11 <= n && !self.stopped) {
        uint8_t type = b[o] & 0x1F;
        uint32_t size = SHBE24(b + o + 1);
        uint32_t ms = SHBE24(b + o + 4) | ((uint32_t)b[o + 7] << 24);
        if (o + 11 + size + 4 > n) break;   // the rest of this tag has not come yet
        if (type == 9) [self videoTag:b + o + 11 length:size time:ms];
        else if (type == 8) [self audioTag:b + o + 11 length:size time:ms];
        o += 11 + size + 4;
    }
    if (o) [_pending replaceBytesInRange:NSMakeRange(0, o) withBytes:NULL length:0];
    if (_pending.length > SHLiveMaxPending) [self failWith:@"the stream does not parse"];
}

- (void)parseAVCConfig:(const uint8_t *)d length:(NSUInteger)n
{
    if (n < 7) return;
    NSUInteger lengthSize = (d[4] & 3) + 1;
    NSUInteger o = 5;
    NSData *sps = nil, *pps = nil;
    NSUInteger numSps = d[o++] & 0x1F;
    for (NSUInteger i = 0; i < numSps; i++) {
        if (o + 2 > n) return;
        NSUInteger len = ((NSUInteger)d[o] << 8) | d[o + 1];
        o += 2;
        if (o + len > n) return;
        if (!sps) sps = [NSData dataWithBytes:d + o length:len];
        o += len;
    }
    if (o >= n) return;
    NSUInteger numPps = d[o++];
    for (NSUInteger i = 0; i < numPps; i++) {
        if (o + 2 > n) return;
        NSUInteger len = ((NSUInteger)d[o] << 8) | d[o + 1];
        o += 2;
        if (o + len > n) return;
        if (!pps) pps = [NSData dataWithBytes:d + o length:len];
        o += len;
    }
    if (sps.length && pps.length) {
        if (![sps isEqualToData:_sps]) SHLog(@"live: H.264 profile %u level %u, NAL length %lu", d[1], d[3], (unsigned long)lengthSize);
        _sps = sps;
        _pps = pps;
        _nalLengthSize = lengthSize;
    }
}

- (void)videoTag:(const uint8_t *)p length:(NSUInteger)len time:(uint32_t)ms
{
    if (len < 5) return;
    if (p[0] & 0x80) { [self failWith:@"the pictures are HEVC (enhanced FLV): this device cannot play them"]; return; }
    if ((p[0] & 0x0F) != 7) { [self failWith:@"the pictures are not H.264"]; return; }
    if ((p[0] >> 4) == 5) return;                       // (a command frame, no picture)
    BOOL keyframe = (p[0] >> 4) == 1;
    uint8_t packetType = p[1];
    int32_t cts = (int32_t)SHBE24(p + 2);
    if (cts & 0x800000) cts |= (int32_t)0xFF000000;   // (signed 24 bits)
    const uint8_t *d = p + 5;
    NSUInteger n = len - 5;
    if (packetType == 0) { [self parseAVCConfig:d length:n]; return; }
    if (packetType != 1 || !_sps.length) return;
    if (_rebase && !keyframe) return;          // (a new pull is joined at its first key frame)

    int64_t dts = [self timestamp:ms];
    int64_t pts = dts + (int64_t)cts * 90;
    if (pts < dts) pts = dts;
    if (keyframe) [self cutAt:dts];
    if (_currentStart < 0) return;            // (nothing before the first key frame)

    static const uint8_t startCode[4] = { 0, 0, 0, 1 };
    static const uint8_t aud[2] = { 0x09, 0xF0 };
    [_pes setLength:0];
    uint8_t header[9] = { 0, 0, 1, 0xE0, 0, 0, 0x84, 0xC0, 10 };   // unbounded length, data aligned, PTS + DTS
    [_pes appendBytes:header length:9];
    SHAppendTimestamp(_pes, 3, pts);
    SHAppendTimestamp(_pes, 1, dts);
    [_pes appendBytes:startCode length:4];
    [_pes appendBytes:aud length:2];
    if (keyframe) {
        [_pes appendBytes:startCode length:4];
        [_pes appendData:_sps];
        [_pes appendBytes:startCode length:4];
        [_pes appendData:_pps];
    }
    NSUInteger o = 0, lengthSize = _nalLengthSize;
    while (o + lengthSize <= n) {
        NSUInteger nal = 0;
        for (NSUInteger k = 0; k < lengthSize; k++) nal = (nal << 8) | d[o + k];
        o += lengthSize;
        if (nal == 0 || o + nal > n) break;
        uint8_t type = d[o] & 0x1F;
        if (type != 9 && type != 7 && type != 8) {   // (the stream's own AUD/SPS/PPS: ours stand in for them)
            [_pes appendBytes:startCode length:4];
            [_pes appendBytes:d + o length:nal];
        }
        o += nal;
    }
    // the clock runs a third of a second ahead of the pictures' decode times
    SHWritePES(_current, kVideoPid, &_videoCC, _pes.bytes, _pes.length, MAX((int64_t)0, dts - 27000), keyframe);
}

- (void)audioTag:(const uint8_t *)p length:(NSUInteger)len time:(uint32_t)ms
{
    if (len < 3 || (p[0] >> 4) != 10) return;          // AAC only
    if (p[1] == 0) {                                   // AudioSpecificConfig
        if (len < 4) return;
        _audioObjectType = p[2] >> 3;
        _audioFrequencyIndex = ((p[2] & 7) << 1) | (p[3] >> 7);
        _audioChannels = (p[3] >> 3) & 0x0F;
        _haveAudioConfig = YES;
        return;
    }
    if (!_haveAudioConfig || _currentStart < 0 || _rebase) return;   // (a new pull: sound once its pictures are joined)
    const uint8_t *frame = p + 2;
    NSUInteger size = len - 2;
    int64_t pts = [self timestamp:ms];
    NSInteger profile = _audioObjectType >= 1 && _audioObjectType <= 4 ? _audioObjectType - 1 : 1;   // (AAC-LC when in doubt)
    NSUInteger frameLength = size + 7;
    uint8_t adts[7] = {
        0xFF, 0xF1,
        (uint8_t)((profile << 6) | ((_audioFrequencyIndex & 0x0F) << 2) | ((_audioChannels >> 2) & 1)),
        (uint8_t)(((_audioChannels & 3) << 6) | ((frameLength >> 11) & 3)),
        (uint8_t)((frameLength >> 3) & 0xFF),
        (uint8_t)(((frameLength & 7) << 5) | 0x1F),
        0xFC,
    };
    NSUInteger pesLength = 3 + 5 + frameLength;        // flags, header length, PTS, then the ADTS frame
    [_pes setLength:0];
    uint8_t header[9] = { 0, 0, 1, 0xC0, (uint8_t)(pesLength >> 8), (uint8_t)(pesLength & 0xFF), 0x80, 0x80, 5 };   // PTS only
    [_pes appendBytes:header length:9];
    SHAppendTimestamp(_pes, 2, pts);
    [_pes appendBytes:adts length:7];
    [_pes appendBytes:frame length:size];
    SHWritePES(_current, kAudioPid, &_audioCC, _pes.bytes, _pes.length, -1, NO);
}

// A key frame: the segment being made ends here once it is long enough, and a new one opens with the tables
- (void)cutAt:(int64_t)dts
{
    if (_currentStart >= 0) {
        double seconds = (double)(dts - _currentStart) / 90000.0;
        if (seconds < SHLiveTargetSeconds) return;
        SHLiveSegment *s = [[SHLiveSegment alloc] init];
        s.duration = seconds;
        s.data = [_current copy];
        @synchronized (self) {
            s.sequence = _nextSequence++;
            [self.segments addObject:s];
            while (self.segments.count > SHLiveWindow) [self.segments removeObjectAtIndex:0];
        }
    }
    _current = [NSMutableData dataWithCapacity:768 * 1024];
    SHWriteTables(_current, &_patCC, &_pmtCC);
    _currentStart = dts;
}

#pragma mark - For the player

- (NSArray *)segmentsNow
{
    @synchronized (self) { return [self.segments copy]; }
}

- (NSString *)playlistFor:(NSArray *)segments
{
    double longest = SHLiveTargetSeconds;
    for (SHLiveSegment *s in segments) longest = MAX(longest, s.duration);
    NSMutableString *m = [NSMutableString stringWithFormat:@"#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:%d\n#EXT-X-MEDIA-SEQUENCE:%lu\n",
                          (int)ceil(longest), (unsigned long)[(SHLiveSegment *)segments.firstObject sequence]];
    for (SHLiveSegment *s in segments) [m appendFormat:@"#EXTINF:%.3f,\n%lu.ts\n", s.duration, (unsigned long)s.sequence];
    if (self.stopped) [m appendString:@"#EXT-X-ENDLIST\n"];
    return m;
}

- (NSString *)playlistWaitingForSegments:(NSUInteger)count timeout:(NSTimeInterval)timeout
{
    NSTimeInterval until = [NSDate timeIntervalSinceReferenceDate] + timeout;
    for (;;) {
        self.lastAsked = [NSDate timeIntervalSinceReferenceDate];
        NSArray *segments = [self segmentsNow];
        if (segments.count >= count || (segments.count && self.stopped)) return [self playlistFor:segments];
        if (self.stopped || [NSDate timeIntervalSinceReferenceDate] > until) return segments.count ? [self playlistFor:segments] : nil;
        usleep(100000);
    }
}

- (NSData *)segment:(NSUInteger)sequence waiting:(NSTimeInterval)timeout
{
    NSTimeInterval until = [NSDate timeIntervalSinceReferenceDate] + timeout;
    for (;;) {
        self.lastAsked = [NSDate timeIntervalSinceReferenceDate];
        NSArray *segments = [self segmentsNow];
        for (SHLiveSegment *s in segments) if (s.sequence == sequence) return s.data;
        if (segments.count && sequence < [(SHLiveSegment *)segments.firstObject sequence]) return nil;   // gone already
        if (self.stopped || [NSDate timeIntervalSinceReferenceDate] > until) return nil;
        usleep(100000);
    }
}

@end
