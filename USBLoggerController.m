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


#import "USBLoggerController.h"

@implementation LoggerEntry
#define NUM_FRESH_ENTRIES 20000
static NSMutableArray * freshEntries = nil;
static int remainingFreshEntries = 0;

+ (void)initialize {
    freshEntries = [[NSMutableArray alloc] initWithCapacity:NUM_FRESH_ENTRIES];
    [self replenishFreshEntries];
}

+ (void)replenishFreshEntries {
    LoggerEntry *temp;
    int i;
    
    [freshEntries removeAllObjects];
    
    for (i=0; i<NUM_FRESH_ENTRIES; i++) {
        temp = [[LoggerEntry alloc] init];
        [freshEntries addObject:temp];
        [temp release];
    }
    
    remainingFreshEntries = NUM_FRESH_ENTRIES;
}

+ (LoggerEntry *)cachedFreshEntry {
    if (remainingFreshEntries <= 0) {
        [self replenishFreshEntries];
    }
    remainingFreshEntries--;
    return [freshEntries objectAtIndex: remainingFreshEntries];
}

- init {
    return [self initWithText:nil level:-1];
}

- initWithText:(NSString *)text level:(int)level {
    if (self = [super init]) {
        _text = [text retain];
        _level = level;
    }
    return self;
}

- (void)setText:(NSString *)text level:(int)level {
    [_text release];
    _text = [text retain];
    _level = level;
}

- (NSString *)text {
    return _text;
}

- (int)level {
    return _level;
}

@end

@interface USBLoggerController ()
- (void)resetDisplayGroup;
- (void)appendDisplayOutput:(NSString *)text;
- (NSString *)rawFilteredOutput;
@end

@implementation USBLoggerController

- init {
    if (self = [super init]) {
        _outputLines = [[NSMutableArray alloc] init];
        _currentFilterString = nil;
        _outputBuffer = [[NSMutableString alloc] init];
        _bufferLock = [[NSLock alloc] init];
        _outputLock = [[NSLock alloc] init];;
    }
    return self;
}

- (void)dealloc {
    if (_logger != nil) {
        [_logger invalidate];
        [_logger release];
    }
    [self resetDisplayGroup];
    [_outputLines release];
    [_currentFilterString release];
    [_outputBuffer release];
    [_bufferLock release];
    [_outputLock release];
    [super dealloc];
}

- (void)awakeFromNib {
    [LoggerOutputTV setFont:[NSFont fontWithName:@"Monaco" size:10]];
    [FilterProgressIndicator setUsesThreadedAnimation:YES];
    
    [LoggingLevelPopUp removeAllItems];
    NSArray *titles = @[@"Errors & faults", @"Default", @"Info", @"Debug"];
    NSArray *levels = @[@1, @3, @5, @7];
    for (NSUInteger index = 0; index < [titles count]; index++) {
        [LoggingLevelPopUp addItemWithTitle:[titles objectAtIndex:index]];
        [[LoggingLevelPopUp lastItem] setTag:[[levels objectAtIndex:index] intValue]];
    }
    NSInteger savedLevel = [[NSUserDefaults standardUserDefaults] integerForKey:@"USBLoggerLoggingLevel"];
    NSInteger level = savedLevel <= 0 ? 3 : (savedLevel <= 1 ? 1 : (savedLevel <= 3 ? 3 : (savedLevel <= 5 ? 5 : 7)));
    [LoggingLevelPopUp selectItemWithTag:level];

    _refreshTimer = [[NSTimer scheduledTimerWithTimeInterval: (NSTimeInterval) LOGGER_REFRESH_INTERVAL
                                                      target:                         self
                                                    selector:                       @selector(handlePendingOutput:)
                                                    userInfo:                       nil
                                                     repeats:                        YES] retain];

    [self setupRecentSearchesMenu];
}

- (void)setupRecentSearchesMenu {
    // we can only do this if we're running on 10.3 or later (where FilterTextField is an NSSearchField instance)
    if ([FilterTextField respondsToSelector: @selector(setRecentSearches:)]) {
        NSMenu *cellMenu = [[NSMenu alloc] initWithTitle:@"Search Menu"];
        NSMenuItem *recentsTitleItem, *norecentsTitleItem, *recentsItem, *separatorItem, *clearItem;
        id searchCell = [FilterTextField cell];

        [FilterTextField setRecentsAutosaveName:@"logger_output_filter"];
        [searchCell setMaximumRecents:10];

        recentsTitleItem = [[NSMenuItem alloc] initWithTitle:@"Recent Searches" action: nil keyEquivalent:@""];
        [recentsTitleItem setTag:NSSearchFieldRecentsTitleMenuItemTag];
        [cellMenu insertItem:recentsTitleItem atIndex:0];
        [recentsTitleItem release];
        norecentsTitleItem = [[NSMenuItem alloc] initWithTitle:@"No recent searches" action: nil keyEquivalent:@""];
        [norecentsTitleItem setTag:NSSearchFieldNoRecentsMenuItemTag];
        [cellMenu insertItem:norecentsTitleItem atIndex:1];
        [norecentsTitleItem release];
        recentsItem = [[NSMenuItem alloc] initWithTitle:@"Recents" action: nil keyEquivalent:@""];
        [recentsItem setTag:NSSearchFieldRecentsMenuItemTag];
        [cellMenu insertItem:recentsItem atIndex:2];
        [recentsItem release];
        separatorItem = (NSMenuItem *)[NSMenuItem separatorItem];
        [separatorItem setTag:NSSearchFieldRecentsTitleMenuItemTag];
        [cellMenu insertItem:separatorItem atIndex:3];
        clearItem = [[NSMenuItem alloc] initWithTitle:@"Clear" action: nil keyEquivalent:@""];
        [clearItem setTag:NSSearchFieldClearRecentsMenuItemTag];
        [cellMenu insertItem:clearItem atIndex:4];
        [clearItem release];
        [searchCell setSearchMenuTemplate:cellMenu];
        [cellMenu release];
    }
}

- (IBAction)ChangeLoggingLevel:(id)sender
{
    if (_logger != nil) {
        [_logger setLevel:(int)[[sender selectedItem] tag]];
    }
    [[NSUserDefaults standardUserDefaults] setObject:[NSNumber numberWithInt:[[sender selectedItem] tag]] forKey:@"USBLoggerLoggingLevel"];
}

- (IBAction)ClearOutput:(id)sender
{
    [_bufferLock lock];
    [_outputLock lock];
    [_outputLines removeAllObjects];
    [_outputBuffer setString:@""];
    [LoggerOutputTV setString:@""];
    [self resetDisplayGroup];
    [_outputLock unlock];
    [_bufferLock unlock];
}

- (IBAction)MarkOutput:(id)sender
{
    [self appendOutput:[NSString stringWithFormat:@"%@ [Session] **** Mark ****\n", USBLogTimestamp()] atLevel:@0];
    
}

/*- (IBAction)SaveOutput:(id)sender
{
    NSSavePanel *sp = [NSSavePanel savePanel];
    int result;
    
    [sp setRequiredFileType:@"txt"];
    result = [sp runModalForDirectory:NSHomeDirectory() file:@"USB Log"];
    if (result == NSOKButton) {
        NSString *finalString;
        
        [_outputLock lock];
        
        finalString = [LoggerOutputTV string];
        
        if (![finalString writeToFile:[sp filename] atomically:YES encoding:NSUTF8StringEncoding error:NULL])
            NSBeep();
        
        [_outputLock unlock];
    }
}*/

- (IBAction)SaveOutput:(id)sender
{
    NSSavePanel *sp = [NSSavePanel savePanel];
    [sp setAllowedFileTypes:[NSArray arrayWithObjects:@"txt", nil]];
    [sp setDirectoryURL:[NSURL fileURLWithPath:NSHomeDirectory()]];
    [sp setNameFieldStringValue:@"USB Log"];
    [sp setExtensionHidden:NO];
    [sp beginSheetModalForWindow:[NSApp mainWindow] completionHandler:^(NSInteger returnCode){
        
        if (returnCode==NSModalResponseOK)
        {
            NSString *finalString;
            
            [_outputLock lock];
            
            finalString = [self rawFilteredOutput];
                
            if (![finalString writeToURL:[sp URL] atomically:YES encoding:NSUTF8StringEncoding error:NULL])
            {
                NSBeep();
            }
            [_outputLock unlock];
        }
    }];
}

- (IBAction)Start:(id)sender
{
    if ([DumpCheckBox state] == NSControlStateValueOn)
    {
        NSSavePanel *sp;
        
        sp = [NSSavePanel savePanel];
        [sp setAllowedFileTypes:[NSArray arrayWithObjects:@"txt", nil]];
        
        [sp setDirectoryURL:[NSURL fileURLWithPath:NSHomeDirectory()]];
        [sp setNameFieldStringValue:@"USB Log"];
        [sp setExtensionHidden:NO];
        [sp beginSheetModalForWindow:[NSApp mainWindow] completionHandler:^(NSInteger returnCode){
            if (returnCode == NSModalResponseOK)
            {
                NSString *theFileName;
                theFileName = [[sp URL] path];
        
                _dumpingFile = fopen ([theFileName cStringUsingEncoding:NSUTF8StringEncoding],"w");
        if (_dumpingFile == NULL) {
                    [self appendOutput:[NSString stringWithFormat:@"%@ [Session] Error: unable to open capture file %@\n",USBLogTimestamp(),theFileName] atLevel:[NSNumber numberWithInt:0]];
        } else {
                    [self appendOutput:[NSString stringWithFormat:@"%@ [Session] Capture file: %@\n",USBLogTimestamp(),theFileName] atLevel:[NSNumber numberWithInt:0]];
                }
                [self actuallyStartLogging];
            }
        }];
        }
    else
    {
        [self actuallyStartLogging];
    }
}

- (void) actuallyStartLogging
{
    if (_logger == nil) {
        _logger = [[USBLogger alloc] initWithListener:self level:(int)[[LoggingLevelPopUp selectedItem] tag]];
        
    }
    if (![_logger beginLogging]) {
        [self appendOutput:@"Unable to start USB logging.\n" atLevel:@0];
        [self Stop:nil];
        return;
    }
    
    [DumpCheckBox setEnabled:NO];
    [StartStopButton setAction:@selector(Stop:)];
    [StartStopButton setTitle:@"Stop"];
}

- (IBAction)Stop:(id)sender
{
    // Record Stop before closing the capture file.
    if (_logger != nil) {
        [_logger invalidate];
        [_logger release];
        _logger = nil;
    }
    if (_dumpingFile != NULL) {
        fclose(_dumpingFile);
        _dumpingFile = NULL;
    }

    [StartStopButton setAction:@selector(Start:)];
    [StartStopButton setTitle:@"Start"];
    [DumpCheckBox setEnabled:YES];
}

- (IBAction)ToggleDumping:(id)sender
{
}

- (IBAction)FilterOutput:(id)sender {
    NSScroller *scroller = [[LoggerOutputTV enclosingScrollView] verticalScroller];
    BOOL isScrolledToEnd = (![scroller isEnabled] || [scroller floatValue] == 1);
    [_currentFilterString release];
    _currentFilterString = [[sender stringValue] length] ? [[sender stringValue] copy] : nil;
    [_bufferLock lock];
    [_outputLock lock];
    [FilterProgressIndicator startAnimation:self];
    [LoggerOutputTV setString:@""];
    [self resetDisplayGroup];
    [self appendDisplayOutput:[self rawFilteredOutput]];
    [_outputBuffer setString:@""];
    [FilterProgressIndicator stopAnimation:self];
    if (isScrolledToEnd) {
        [LoggerOutputTV scrollRangeToVisible:NSMakeRange([[LoggerOutputTV string] length], 0)];
    }
    [_outputLock unlock];
    [_bufferLock unlock];
}

- (NSString *)rawFilteredOutput {
    NSMutableString *text = [NSMutableString string];
    for (LoggerEntry *entry in _outputLines) {
        if (!_currentFilterString || [[entry text] rangeOfString:_currentFilterString options:NSCaseInsensitiveSearch].location != NSNotFound) {
            [text appendString:[entry text]];
        }
    }
    return text;
}

- (void)resetDisplayGroup {
    [_displayGroupKey release]; _displayGroupKey = nil;
    [_displayGroupFirstLine release]; _displayGroupFirstLine = nil;
    _displayGroupCount = 0;
    _displayGroupRange = NSMakeRange(0, 0);
}

- (void)appendDisplayOutput:(NSString *)text {
    // Group only adjacent, identical system messages. Device/session records break a group.
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if (![line length]) continue;
        NSRange marker = [line rangeOfString:@" [System/"];
        NSString *key = marker.location == NSNotFound ? nil : [line substringFromIndex:marker.location];
        BOOL repeats = key && [key isEqualToString:_displayGroupKey]
            && NSMaxRange(_displayGroupRange) == [[LoggerOutputTV string] length];
        NSString *rendered;
        if (repeats) {
            _displayGroupCount++;
            rendered = [NSString stringWithFormat:@"%@ [repeated %lu times; last %@]\n",
                _displayGroupFirstLine, (unsigned long)_displayGroupCount, [line substringToIndex:marker.location]];
        } else {
            [self resetDisplayGroup];
            _displayGroupKey = [key copy];
            _displayGroupFirstLine = [line copy];
            _displayGroupCount = 1;
            _displayGroupRange = NSMakeRange([[LoggerOutputTV string] length], 0);
            rendered = [line stringByAppendingString:@"\n"];
        }
        [LoggerOutputTV replaceCharactersInRange:_displayGroupRange withString:rendered];
        _displayGroupRange.length = [rendered length];
    }
    if ([[LoggerOutputTV string] length] > 2 * 1024 * 1024) {
        NSRange newline = [[LoggerOutputTV string] rangeOfString:@"\n" options:0
            range:NSMakeRange(1024 * 1024, [[LoggerOutputTV string] length] - 1024 * 1024)];
        if (newline.location != NSNotFound) {
            NSUInteger removed = NSMaxRange(newline);
            [LoggerOutputTV replaceCharactersInRange:NSMakeRange(0, removed) withString:@""];
            if (_displayGroupRange.location >= removed) _displayGroupRange.location -= removed;
            else [self resetDisplayGroup];
        }
    }
}

- (NSArray *)logEntries {
    return _outputLines;
}

- (NSArray *)displayedLogLines {
    return [[LoggerOutputTV string] componentsSeparatedByString:@"\n"];
}

- (void)scrollToVisibleLine:(NSString *)line {
    NSString *needle = [line stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSRange textRange = [[LoggerOutputTV string] rangeOfString:needle];
    if (textRange.location == NSNotFound) {
        NSRange marker = [needle rangeOfString:@" [System/"];
        if (marker.location != NSNotFound) {
            textRange = [[LoggerOutputTV string] rangeOfString:[needle substringFromIndex:marker.location]];
        }
    }
    if (textRange.location != NSNotFound) {
        [LoggerOutputTV scrollRangeToVisible:textRange];
        [LoggerOutputTV setSelectedRange:textRange];
        [[LoggerOutputTV window] makeFirstResponder:LoggerOutputTV];
        [[LoggerOutputTV window] makeKeyAndOrderFront:self];
    }
}

- (void)handlePendingOutput:(NSTimer *)timer {
    if ([_bufferLock tryLock]) {
        if ([_outputLock tryLock]) {
            if ([_outputBuffer length] > 0) {
                NSRange endMarker = NSMakeRange([[LoggerOutputTV string] length], 0);
                NSScroller *scroller = [[LoggerOutputTV enclosingScrollView] verticalScroller];
                BOOL isScrolledToEnd = (![scroller isEnabled] || [scroller floatValue] == 1);
                
                [self appendDisplayOutput:_outputBuffer];

                if (isScrolledToEnd) {
                    endMarker.location = [[LoggerOutputTV string] length];
                    [LoggerOutputTV scrollRangeToVisible:endMarker];
                }
                
                [_outputBuffer setString:@""];
                
                [LoggerOutputTV setNeedsDisplay:YES];
            }
            [_outputLock unlock];
        }
        [_bufferLock unlock];
    }
}

- (void)appendOutput:(NSString *)aString atLevel:(NSNumber *)level {
    LoggerEntry *entry = [[LoggerEntry alloc] initWithText:aString level:[level intValue]];

    [_outputLock lock];
    [_outputLines addObject:entry];
    // Keep long sessions bounded; dumping to disk still receives every record.
    if ([_outputLines count] > 10000) {
        [_outputLines removeObjectsInRange:NSMakeRange(0, 1000)];
    }
    [_outputLock unlock];
    
    [entry release];

    if (_dumpingFile != NULL) {
        fprintf(_dumpingFile, "%s", [aString cStringUsingEncoding:NSUTF8StringEncoding]);
        fflush(_dumpingFile);
    }
    
    [_bufferLock lock];
    if (_currentFilterString == nil || [aString rangeOfString:_currentFilterString options:NSCaseInsensitiveSearch].location != NSNotFound) {
        [_outputBuffer appendString:aString];
    }
    [_bufferLock unlock];
}

- (void)appendLoggerEntry:(LoggerEntry *)entry {
    NSString *text = [entry text];
    [_outputLock lock];
    [_outputLines addObject:entry];
    // Keep long sessions bounded; dumping to disk still receives every record.
    if ([_outputLines count] > 10000) {
        [_outputLines removeObjectsInRange:NSMakeRange(0, 1000)];
    }
    [_outputLock unlock];
    
    if (_dumpingFile != NULL) {
        fprintf(_dumpingFile, "%s", [text cStringUsingEncoding:NSUTF8StringEncoding]);
        fflush(_dumpingFile);
    }
    
    [_bufferLock lock];
    if (_currentFilterString == nil || [text rangeOfString:_currentFilterString options:NSCaseInsensitiveSearch].location != NSNotFound) {
        [_outputBuffer appendString:text];
    }
    [_bufferLock unlock];
}

- (void)usbLoggerTextAvailable:(NSString *)text forLevel:(int)level {
    // The backend delivers on the main run loop; each queued entry owns its text.
    [self appendOutput:text atLevel:[NSNumber numberWithInt:level]];
}

@end


