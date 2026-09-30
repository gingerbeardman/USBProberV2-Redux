/*
 * Modified by Matt Sephton on 2026-09-30 for USB Prober Redux.
 * Logger regression tests for the fork.
 *
 * Copyright (c) 2026 Matt Sephton. All rights reserved.
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
#import "USBLoggerController.h"
#import <os/log.h>

@interface USBLogger (Testing)
- (void)consumeLogData:(NSData *)data;
- (BOOL)startDeviceNotifications;
- (BOOL)startLogStream;
- (NSString *)logPredicate;
@end

@interface RecordingListener : NSObject <USBLoggerListener>
@property(nonatomic, retain) NSMutableString *text;
@property(nonatomic) NSUInteger callbacks;
@end
@implementation RecordingListener
- (instancetype)init {
    if ((self = [super init])) _text = [[NSMutableString alloc] init];
    return self;
}
- (void)usbLoggerTextAvailable:(NSString *)text forLevel:(int)level {
    NSCAssert([NSThread isMainThread], @"Callbacks must run on the main thread");
    [_text appendString:text];
    _callbacks++;
}
- (void)dealloc { [_text release]; [super dealloc]; }
@end

@interface ParserLogger : USBLogger
@end
@implementation ParserLogger
- (BOOL)startDeviceNotifications { return YES; }
- (BOOL)startLogStream { return YES; }
@end

// Isolate the marker from unrelated USB log floods on the host.
@interface LiveTestLogger : USBLogger
@end
@implementation LiveTestLogger
- (NSString *)logPredicate { return @"subsystem == \"com.example.usbprober.smoketest\""; }
@end

@interface USBLoggerController (Testing)
- (void)appendDisplayOutput:(NSString *)text;
- (NSString *)rawFilteredOutput;
@end
@interface TestOutputView : NSObject
@property(nonatomic, retain) NSMutableString *text;
- (NSString *)string;
- (void)replaceCharactersInRange:(NSRange)range withString:(NSString *)text;
- (void)setString:(NSString *)text;
@end
@implementation TestOutputView
- (instancetype)init { if ((self = [super init])) _text = [[NSMutableString alloc] init]; return self; }
- (NSString *)string { return _text; }
- (void)replaceCharactersInRange:(NSRange)range withString:(NSString *)text { [_text replaceCharactersInRange:range withString:text]; }
- (void)setString:(NSString *)text { [_text setString:text]; }
- (void)dealloc { [_text release]; [super dealloc]; }
@end

@interface TestLoggerController : USBLoggerController
- (void)setTestDumpFile:(FILE *)file;
- (void)setTestView:(id)view;
- (void)setTestLogger:(USBLogger *)logger;
@end
@implementation TestLoggerController
- (void)setTestView:(id)view { LoggerOutputTV = view; }
- (void)setTestLogger:(USBLogger *)logger { _logger = [logger retain]; }
- (void)setTestDumpFile:(FILE *)file {
    _dumpingFile = file;
    _currentFilterString = [@"unmatched filter" retain];
}
@end

static void Check(BOOL condition, NSString *reason) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", [reason UTF8String]);
        exit(1);
    }
}
static void RunLoopFor(NSTimeInterval duration) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:duration];
    while ([end timeIntervalSinceNow] > 0) {
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "--emit") == 0) {
            os_log_t log = os_log_create("com.example.usbprober.smoketest", "USBProberSmokeTest");
            os_log_error(log, "USBProber live stream smoke marker");
            usleep(500000);
            return 0;
        }
        RecordingListener *listener = [[RecordingListener alloc] init];
        USBLogger *parser = [[ParserLogger alloc] initWithListener:listener level:3];
        Check([parser beginLogging], @"Parser session starts");
        Check([listener.text containsString:@"[Session] Start; level: Default"], @"Capture header includes selected level");
        NSRegularExpression *timestampPattern = [NSRegularExpression regularExpressionWithPattern:
            @"^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d{3}(Z|[+-]\\d{2}:\\d{2}) " options:0 error:NULL];
        Check([timestampPattern numberOfMatchesInString:listener.text options:0 range:NSMakeRange(0, [listener.text length])] == 1,
              @"Session uses a locale-independent precise timestamp with timezone");
        NSString *record = @"{\"timestamp\":\"now\",\"messageType\":\"Error\",\"processImagePath\":\"/kernel\",\"subsystem\":\"usb\",\"category\":\"test\",\"eventMessage\":\"café 🔌\"}\n";
        NSData *data = [record dataUsingEncoding:NSUTF8StringEncoding];
        // Split the UTF-8 code point across pipe reads, not just the JSON tokens.
        const unsigned char *bytes = [data bytes];
        NSUInteger split = 0;
        for (NSUInteger i = 0; i < [data length]; i++) if (bytes[i] == 0xc3) { split = i + 1; break; }
        Check(split > 0, @"UTF-8 split found");
        [parser consumeLogData:[data subdataWithRange:NSMakeRange(0, split)]];
        Check([listener.text rangeOfString:@"café"].location == NSNotFound, @"Partial record is buffered");
        [parser consumeLogData:[data subdataWithRange:NSMakeRange(split, [data length] - split)]];
        Check([listener.text containsString:@"[System/Error] kernel [usb:test] café 🔌"], @"Complete UTF-8 record is formatted");
        NSString *kernelRecord = @"{\"timestamp\":\"2026-09-30 11:32:54.157791+0100\",\"messageType\":\"Error\",\"processImagePath\":\"/kernel\",\"senderImagePath\":\"/kernel\",\"subsystem\":\"\",\"category\":null,\"eventMessage\":\"AppleUSBIORequest: transaction error\"}\n";
        [parser consumeLogData:[kernelRecord dataUsingEncoding:NSUTF8StringEncoding]];
        Check([listener.text containsString:@"2026-09-30T11:32:54.157+01:00 [System/Error] kernel/AppleUSBIORequest AppleUSBIORequest: transaction error"],
              @"Kernel driver is inferred and timestamp normalized without empty metadata labels");
        NSString *senderRecord = @"{\"timestamp\":\"2026-09-30T11:32:54.158Z\",\"messageType\":null,\"processImagePath\":\"/kernel\",\"senderImagePath\":\"/System/Library/Extensions/IOUSBHostFamily/IOUSBHostFamily\",\"subsystem\":null,\"category\":null,\"eventMessage\":\"request failed\"}\n";
        [parser consumeLogData:[senderRecord dataUsingEncoding:NSUTF8StringEncoding]];
        Check([listener.text containsString:@"kernel/IOUSBHostFamily request failed"], @"Driver image is used when available");
        Check(![listener.text containsString:@"[:]"] && ![listener.text containsString:@"(null)"], @"Null metadata never leaks into labels");
        NSUInteger count = listener.callbacks;
        [parser consumeLogData:[@"Filtering the log data\n{}\n[]\n" dataUsingEncoding:NSUTF8StringEncoding]];
        Check(listener.callbacks == count, @"Non-event stream lines are ignored");
        [parser invalidate];
        Check([listener.text containsString:@"[Session] Stop"], @"Stop marker is emitted");
        count = listener.callbacks;
        [parser consumeLogData:data];
        Check(listener.callbacks == count, @"No callbacks after Stop");
        [parser release];
        [listener.text setString:@""];

        TestLoggerController *controller = [[TestLoggerController alloc] init];
        FILE *capture = tmpfile();
        Check(capture != NULL, @"Temporary capture file opens");
        [controller setTestDumpFile:capture];
        NSString *captureText = @"[Device] Connected: café 🔌\n";
        [controller usbLoggerTextAvailable:captureText forLevel:0];
        [controller MarkOutput:nil];
        rewind(capture);
        unsigned char captured[2048] = {0};
        size_t capturedLength = fread(captured, 1, sizeof(captured), capture);
        NSString *saved = [[[NSString alloc] initWithBytes:captured length:capturedLength encoding:NSUTF8StringEncoding] autorelease];
        Check([saved hasPrefix:captureText], @"File dumping preserves UTF-8 and does not add an @ prefix");
        Check([saved containsString:@"****"], @"Markers are dumped too");
        Check([[controller valueForKey:@"outputBuffer"] length] == 0, @"Display filter does not suppress file output");
        [controller ClearOutput:nil];
        Check([[controller logEntries] count] == 0 && [[controller valueForKey:@"outputBuffer"] length] == 0,
              @"Clear removes retained and pending entries");
        [controller Stop:nil];
        [controller release];

        TestOutputView *view = [[TestOutputView alloc] init];
        controller = [[TestLoggerController alloc] init];
        [controller setTestView:view];
        NSString *first = @"2026-09-30T11:32:54.157+01:00 [System/Error] kernel/AppleUSBIORequest transaction error\n";
        NSString *second = @"2026-09-30T11:32:54.211+01:00 [System/Error] kernel/AppleUSBIORequest transaction error\n";
        [controller appendDisplayOutput:first];
        [controller appendDisplayOutput:second];
        Check([view.text containsString:@"repeated 2 times; last 2026-09-30T11:32:54.211+01:00"], @"Adjacent repeats group across refreshes");
        [controller appendDisplayOutput:@"2026-09-30T11:32:54.212+01:00 [Device] Removed: Controller\n"];
        [controller appendDisplayOutput:second];
        Check(![view.text containsString:@"repeated 3 times"], @"Device changes break repeat groups");
        [controller ClearOutput:nil];
        [controller appendDisplayOutput:second];
        Check(![view.text containsString:@"repeated"], @"Clear resets repeat grouping");
        [controller release];
        [view release];

        // Disk capture and export keep every repeated event, plus the Stop marker.
        controller = [[TestLoggerController alloc] init];
        capture = tmpfile();
        [controller setTestDumpFile:capture];
        parser = [[ParserLogger alloc] initWithListener:controller level:7];
        [controller setTestLogger:parser];
        Check([parser beginLogging], @"File capture session starts");
        [controller usbLoggerTextAvailable:first forLevel:1];
        [controller usbLoggerTextAvailable:second forLevel:1];
        int captureFD = dup(fileno(capture));
        [controller Stop:nil];
        FILE *readCapture = fdopen(captureFD, "r");
        rewind(readCapture);
        memset(captured, 0, sizeof(captured));
        capturedLength = fread(captured, 1, sizeof(captured), readCapture);
        saved = [[[NSString alloc] initWithBytes:captured length:capturedLength encoding:NSUTF8StringEncoding] autorelease];
        Check([saved containsString:@"Start; level: Debug"] && [saved containsString:@"[Session] Stop"], @"Start, level and Stop are captured to disk");
        Check([saved containsString:first] && [saved containsString:second] && ![saved containsString:@"repeated"], @"Disk preserves repeated raw events");
        [controller setValue:nil forKey:@"currentFilterString"];
        Check([[controller rawFilteredOutput] containsString:first] && [[controller rawFilteredOutput] containsString:second], @"Save Output retains raw repetitions too");
        fclose(readCapture);
        [parser release];
        [controller release];

        if (argc > 1 && strcmp(argv[1], "--live") == 0) {
            USBLogger *logger = [[LiveTestLogger alloc] initWithListener:listener level:7];
            Check([logger beginLogging], @"Live session starts");
            RunLoopFor(1);
            Check(![listener.text containsString:@"Log stream ended"], @"System stream stays running");
            Check(![listener.text containsString:@"notifications are unavailable"], @"Device notifications register");
            NSTask *emitter = [[[NSTask alloc] init] autorelease];
            emitter.executableURL = [NSURL fileURLWithPath:[[NSProcessInfo processInfo] arguments][0]];
            emitter.arguments = @[@"--emit"];
            Check([emitter launchAndReturnError:NULL], @"Synthetic USB log emitter starts");
            [emitter waitUntilExit];
            RunLoopFor(2);
            Check([listener.text containsString:@"USBProber live stream smoke marker"], @"USB unified log arrives in listener");
            for (NSNumber *level in @[@1, @3, @5, @7]) {
                [logger setLevel:[level intValue]];
                RunLoopFor(0.4);
                Check(![listener.text containsString:@"Log stream ended"], @"Level predicate is accepted");
            }
            NSTask *stream = [[logger valueForKey:@"logTask"] retain];
            [logger invalidate];
            count = listener.callbacks;
            RunLoopFor(0.5);
            Check(![stream isRunning], @"Stop terminates log process");
            Check(listener.callbacks == count, @"Stopped session delivers no late callbacks");
            [stream release];
            Check([logger beginLogging], @"Stopped logger restarts");
            RunLoopFor(0.5);
            Check(![listener.text containsString:@"Log stream ended"], @"Restarted stream stays running");
            NSTask *failedStream = [logger valueForKey:@"logTask"];
            [failedStream terminate];
            RunLoopFor(0.5);
            Check([listener.text containsString:@"Log stream ended"], @"Stream failure is reported");
            Check([logger isLogging], @"Device monitoring survives system stream failure");
            [logger invalidate];
            [logger release];
            printf("Live system stream, device snapshot, levels, Stop and restart passed.\n");
            printf("%s", [listener.text UTF8String]);
        }
        [listener release];
        printf("Parser and lifecycle checks passed.\n");
    }
    return 0;
}
