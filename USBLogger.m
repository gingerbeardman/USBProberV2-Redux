/*
 * Copyright � 1998-2012 Apple Inc.  All rights reserved.
 *
 * @APPLE_LICENSE_HEADER_START@
 *
 * This file contains Original Code and/or Modifications of Original Code
 * as defined in and that are subject to the Apple Public Source License
 * Version 2.0 (the 'License'). You may not use this file except in
 * compliance with the License. Please obtain a copy of the License at
 * http://www.opensource.apple.com/apsl/ and read it before using this
 * file.
 *
 * The Original Code and all software distributed under the License are
 * distributed on an 'AS IS' basis, WITHOUT WARRANTY OF ANY KIND, EITHER
 * EXPRESS OR IMPLIED, AND APPLE HEREBY DISCLAIMS ALL SUCH WARRANTIES,
 * INCLUDING WITHOUT LIMITATION, ANY WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE, QUIET ENJOYMENT OR NON-INFRINGEMENT.
 * Please see the License for the specific language governing rights and
 * limitations under the License.
 *
 * @APPLE_LICENSE_HEADER_END@
 */

#import "USBLogger.h"
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>

NSString *USBLogTimestamp(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [[NSDateFormatter alloc] init];
        [formatter setLocale:[[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"] autorelease]];
        [formatter setTimeZone:[NSTimeZone localTimeZone]];
        [formatter setDateFormat:@"yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"];
    });
    return [formatter stringFromDate:[NSDate date]];
}

static NSString *LogString(id value) {
    return [value isKindOfClass:[NSString class]] ? value : @"";
}

static NSString *NormalizeLogTimestamp(NSString *timestamp) {
    static NSRegularExpression *pattern;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pattern = [[NSRegularExpression alloc] initWithPattern:
            @"^(\\d{4}-\\d{2}-\\d{2})[ T](\\d{2}:\\d{2}:\\d{2})(?:\\.(\\d+))?(Z|[+-]\\d{2}:?\\d{2})$" options:0 error:NULL];
    });
    NSTextCheckingResult *match = [pattern firstMatchInString:timestamp options:0 range:NSMakeRange(0, [timestamp length])];
    if (!match) return [timestamp length] ? timestamp : USBLogTimestamp();
    NSString *fraction = [match rangeAtIndex:3].location == NSNotFound ? @"000" :
        [timestamp substringWithRange:[match rangeAtIndex:3]];
    fraction = [[fraction stringByAppendingString:@"000"] substringToIndex:3];
    NSString *zone = [timestamp substringWithRange:[match rangeAtIndex:4]];
    if ([zone length] == 5) zone = [NSString stringWithFormat:@"%@:%@", [zone substringToIndex:3], [zone substringFromIndex:3]];
    return [NSString stringWithFormat:@"%@T%@.%@%@", [timestamp substringWithRange:[match rangeAtIndex:1]],
        [timestamp substringWithRange:[match rangeAtIndex:2]], fraction, zone];
}

static NSString *LogSource(NSDictionary *record, NSString *message) {
    NSString *process = [LogString([record objectForKey:@"processImagePath"]) lastPathComponent];
    NSString *sender = [LogString([record objectForKey:@"senderImagePath"]) lastPathComponent];
    // Kernel records often omit a useful sender image; their message may name the driver.
    if (![sender length] || [sender isEqualToString:process]) {
        static NSRegularExpression *driverPattern;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            driverPattern = [[NSRegularExpression alloc] initWithPattern:
                @"^(?:DK: )?((?:Apple|IOUSB|Xbox)[A-Za-z0-9_]+(?:@[0-9a-fA-F]+)?)(?::|[- ]|$)" options:0 error:NULL];
        });
        NSTextCheckingResult *match = [driverPattern firstMatchInString:message options:0 range:NSMakeRange(0, [message length])];
        if (match) sender = [message substringWithRange:[match rangeAtIndex:1]];
    }
    if (![process length]) process = @"system";
    return [sender length] && ![sender isEqualToString:process]
        ? [NSString stringWithFormat:@"%@/%@", process, sender] : process;
}

@interface USBLogger ()
- (void)drainDevices:(io_iterator_t)iterator removed:(BOOL)removed;
- (void)readLogOutput:(NSTimer *)timer;
- (void)consumeLogData:(NSData *)data;
- (void)stopLogStream;
@end

static void USBDevicesAdded(void *context, io_iterator_t iterator) {
    [(USBLogger *)context drainDevices:iterator removed:NO];
}

static void USBDevicesRemoved(void *context, io_iterator_t iterator) {
    [(USBLogger *)context drainDevices:iterator removed:YES];
}

@implementation USBLogger

- (instancetype)initWithListener:(id<USBLoggerListener>)listener level:(int)level {
    self = [super init];
    if (self) {
        if (!listener) {
            [self release];
            return nil;
        }
        _listener = listener;
        _loggingLevel = level;
        _pendingOutput = [[NSMutableData alloc] init];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillTerminate:)
            name:NSApplicationWillTerminateNotification object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self invalidate];
    [_pendingOutput release];
    [super dealloc];
}

- (BOOL)isLogging { return _isLogging; }

- (void)applicationWillTerminate:(NSNotification *)notification { [self invalidate]; }

- (void)emit:(NSString *)message level:(int)level {
    if (_isLogging) {
        [_listener usbLoggerTextAvailable:message forLevel:level];
    }
}

- (void)emitStatus:(NSString *)message level:(int)level {
    [self emit:[NSString stringWithFormat:@"%@ %@", USBLogTimestamp(), message] level:level];
}

- (NSString *)captureLevel {
    return _loggingLevel <= 1 ? @"Errors & faults" : (_loggingLevel >= 6 ? @"Debug" : (_loggingLevel >= 4 ? @"Info" : @"Default"));
}

- (BOOL)startDeviceNotifications {
    _notificationPort = IONotificationPortCreate(kIOMainPortDefault);
    if (!_notificationPort) return NO;
    CFRunLoopSourceRef source = IONotificationPortGetRunLoopSource(_notificationPort);
    if (!source) return NO;
    CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);

    _initialDevices = YES;
    IOReturn result = IOServiceAddMatchingNotification(_notificationPort,
        kIOFirstMatchNotification, IOServiceMatching("IOUSBHostDevice"),
        USBDevicesAdded, self, &_addedIterator);
    if (result != kIOReturnSuccess) return NO;
    // Drain the initial snapshot to arm future arrival notifications.
    [self drainDevices:_addedIterator removed:NO];
    _initialDevices = NO;
    result = IOServiceAddMatchingNotification(_notificationPort,
        kIOTerminatedNotification, IOServiceMatching("IOUSBHostDevice"),
        USBDevicesRemoved, self, &_removedIterator);
    if (result != kIOReturnSuccess) return NO;
    [self drainDevices:_removedIterator removed:YES];
    return YES;
}

- (void)stopDeviceNotifications {
    if (_addedIterator) { IOObjectRelease(_addedIterator); _addedIterator = 0; }
    if (_removedIterator) { IOObjectRelease(_removedIterator); _removedIterator = 0; }
    if (_notificationPort) {
        IONotificationPortDestroy(_notificationPort);
        _notificationPort = NULL;
    }
}

- (void)drainDevices:(io_iterator_t)iterator removed:(BOOL)removed {
    io_service_t device;
    while ((device = IOIteratorNext(iterator))) {
        CFMutableDictionaryRef properties = NULL;
        IORegistryEntryCreateCFProperties(device, &properties, kCFAllocatorDefault, 0);
        NSDictionary *values = (NSDictionary *)properties;
        NSString *name = [values objectForKey:@"USB Product Name"];
        if (![name isKindOfClass:[NSString class]]) {
            io_name_t registryName;
            name = IORegistryEntryGetName(device, registryName) == KERN_SUCCESS
                ? [NSString stringWithUTF8String:registryName] : @"USB device";
        }
        NSString *event = removed ? @"Removed" : (_initialDevices ? @"Present" : @"Connected");
        [self emit:[NSString stringWithFormat:@"%@ [Device] %@: %@ (VID 0x%04x, PID 0x%04x, location 0x%08x)\n",
            USBLogTimestamp(), event, name,
            [[values objectForKey:@"idVendor"] unsignedIntValue],
            [[values objectForKey:@"idProduct"] unsignedIntValue],
            [[values objectForKey:@"locationID"] unsignedIntValue]] level:0];
        if (properties) CFRelease(properties);
        IOObjectRelease(device);
    }
}

- (NSString *)streamLevel {
    if (_loggingLevel >= 6) return @"debug";
    if (_loggingLevel >= 4) return @"info";
    return @"default";
}

- (NSString *)logPredicate {
    // Avoid matching this app's own diagnostic output and creating a feedback loop.
    return [NSString stringWithFormat:
        @"processID != %d AND (subsystem CONTAINS[c] \"usb\" OR senderImagePath CONTAINS[c] \"/IOUSB\" OR senderImagePath CONTAINS[c] \"/AppleUSB\" OR (process == \"kernel\" AND eventMessage CONTAINS[c] \"usb\"))",
        getpid()];
}

- (BOOL)startLogStream {
    _logTask = [[NSTask alloc] init];
    _outputPipe = [[NSPipe alloc] init];
    _errorPipe = [[NSPipe alloc] init];
    [_logTask setExecutableURL:[NSURL fileURLWithPath:@"/usr/bin/log"]];
    NSString *predicate = [self logPredicate];
    if (_loggingLevel <= 1) {
        predicate = [predicate stringByAppendingString:@" AND (messageType == error OR messageType == fault)"];
    }
    [_logTask setArguments:@[@"stream", @"--style", @"ndjson", @"--level", [self streamLevel],
                            @"--predicate", predicate]];
    [_logTask setStandardOutput:_outputPipe];
    [_logTask setStandardError:_errorPipe];
    [_logTask setStandardInput:[NSFileHandle fileHandleWithNullDevice]];
    for (NSPipe *pipe in @[_outputPipe, _errorPipe]) {
        int fd = [[pipe fileHandleForReading] fileDescriptor];
        int flags = fcntl(fd, F_GETFL);
        if (flags == -1 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) == -1) {
            [self emitStatus:@"[System] Could not configure the system log reader.\n" level:0];
            [self stopLogStream];
            return NO;
        }
    }
    NSError *error = nil;
    if (![_logTask launchAndReturnError:&error]) {
        [self emitStatus:[NSString stringWithFormat:@"[System] Could not start USB system logs: %@\n", [error localizedDescription]] level:0];
        [self stopLogStream];
        return NO;
    }
    [[_outputPipe fileHandleForWriting] closeFile];
    [[_errorPipe fileHandleForWriting] closeFile];
    _readTimer = [[NSTimer timerWithTimeInterval:0.1 target:self
        selector:@selector(readLogOutput:) userInfo:nil repeats:YES] retain];
    [[NSRunLoop mainRunLoop] addTimer:_readTimer forMode:NSRunLoopCommonModes];
    return YES;
}

- (BOOL)beginLogging {
    NSAssert([NSThread isMainThread], @"USB logging must start on the main thread");
    if (_isLogging) return YES;
    _isLogging = YES;
    [self emitStatus:[NSString stringWithFormat:@"[Session] Start; level: %@; sources: USB device events + unified system logs\n", [self captureLevel]] level:0];
    [self emitStatus:@"[Session] Driver messages depend on what macOS exposes; private values may be redacted.\n" level:0];
    BOOL devices = [self startDeviceNotifications];
    if (!devices) {
        [self stopDeviceNotifications];
        [self emitStatus:@"[Device] USB connection notifications are unavailable.\n" level:0];
    }
    BOOL system = [self startLogStream];
    if (!system) [self emitStatus:@"[System] Device monitoring remains active if available.\n" level:0];
    if (!devices && !system) {
        [self invalidate];
        return NO;
    }
    return YES;
}

- (void)consumeLogData:(NSData *)data {
    [_pendingOutput appendData:data];
    while ([_pendingOutput length]) {
        const unsigned char *bytes = [_pendingOutput bytes];
        const unsigned char *newline = memchr(bytes, '\n', [_pendingOutput length]);
        if (!newline) break;
        NSUInteger length = newline - bytes;
        NSData *line = [_pendingOutput subdataWithRange:NSMakeRange(0, length)];
        [_pendingOutput replaceBytesInRange:NSMakeRange(0, length + 1) withBytes:NULL length:0];
        id record = [NSJSONSerialization JSONObjectWithData:line options:0 error:NULL];
        if (![record isKindOfClass:[NSDictionary class]]) continue;
        NSString *message = [record objectForKey:@"eventMessage"];
        if (![message isKindOfClass:[NSString class]]) continue;
        NSString *type = LogString([record objectForKey:@"messageType"]);
        int level = [type isEqualToString:@"Debug"] ? 7 : ([type isEqualToString:@"Info"] ? 5 : 3);
        if ([type isEqualToString:@"Error"] || [type isEqualToString:@"Fault"]) level = 1;
        NSString *subsystem = LogString([record objectForKey:@"subsystem"]);
        NSString *category = LogString([record objectForKey:@"category"]);
        NSString *metadata = [subsystem length] && [category length]
            ? [NSString stringWithFormat:@"%@:%@", subsystem, category]
            : ([subsystem length] ? subsystem : category);
        NSString *label = [metadata length] ? [NSString stringWithFormat:@" [%@]", metadata] : @"";
        [self emit:[NSString stringWithFormat:@"%@ [System/%@] %@%@ %@\n",
            NormalizeLogTimestamp(LogString([record objectForKey:@"timestamp"])),
            [type length] ? type : @"Default", LogSource(record, message), label, message] level:level];
    }
    // A malformed stream must not grow an unterminated line without bound.
    if ([_pendingOutput length] > 1024 * 1024) {
        [_pendingOutput setLength:0];
        [self emitStatus:@"[System] Discarded an oversized incomplete log record.\n" level:0];
    }
}

- (void)readLogOutput:(NSTimer *)timer {
    // Nonblocking reads with a per-tick budget keep the UI responsive under load.
    unsigned char bytes[8192];
    for (NSPipe *pipe in @[_outputPipe, _errorPipe]) {
        for (int chunk = 0; chunk < 8; chunk++) {
            ssize_t count = read([[pipe fileHandleForReading] fileDescriptor], bytes, sizeof(bytes));
            if (count <= 0) {
                if (count < 0 && errno == EINTR) { chunk--; continue; }
                break;
            }
            NSData *data = [NSData dataWithBytes:bytes length:(NSUInteger)count];
            if (pipe == _outputPipe) {
                [self consumeLogData:data];
            } else {
                NSString *message = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
                if (message) [self emitStatus:[NSString stringWithFormat:@"[System] %@%@", message,
                    [message hasSuffix:@"\n"] ? @"" : @"\n"] level:0];
            }
        }
    }
    if (![_logTask isRunning]) {
        int status = [_logTask terminationStatus];
        [self emitStatus:[NSString stringWithFormat:@"[System] Log stream ended (status %d). Device connection monitoring continues. Stop and Start to retry.\n", status] level:0];
        [self stopLogStream];
    }
}

- (void)stopLogStream {
    [_readTimer invalidate];
    [_readTimer release];
    _readTimer = nil;
    if ([_logTask isRunning]) [_logTask terminate];
    [_logTask release];
    _logTask = nil;
    [[_outputPipe fileHandleForReading] closeFile];
    [[_errorPipe fileHandleForReading] closeFile];
    [_outputPipe release]; _outputPipe = nil;
    [_errorPipe release]; _errorPipe = nil;
    [_pendingOutput setLength:0];
}

- (void)invalidate {
    if (_isLogging) [self emitStatus:@"[Session] Stop\n" level:0];
    _isLogging = NO;
    [self stopLogStream];
    [self stopDeviceNotifications];
}

- (void)setLevel:(int)level {
    if (_loggingLevel == level) return;
    _loggingLevel = level;
    if (_isLogging) {
        [self stopLogStream];
        [self emitStatus:[NSString stringWithFormat:@"[Session] Level changed to %@\n", [self captureLevel]] level:0];
        [self startLogStream];
    }
}
@end
