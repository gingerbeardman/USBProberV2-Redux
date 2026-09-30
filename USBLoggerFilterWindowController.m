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

#import "USBLoggerFilterWindowController.h"


@implementation USBLoggerFilterWindowController

- init {
    if (self = [super init]) {
        _currentFilterString = nil;
        _outputLogLines = [[NSMutableArray alloc] init];
    }
    return self;
}

- (void)dealloc {
    [_currentFilterString release];
    [_outputLogLines release];
    [super dealloc];
}

- (void)awakeFromNib {
    [FilterProgressIndicator setUsesThreadedAnimation:YES];
    [FilterOutput setTarget:self];
    [FilterOutput setDoubleAction:@selector(itemDoubleClicked:)];

    [self setupRecentSearchesMenu];
}

- (void)setupRecentSearchesMenu {
    // we can only do this if we're running on 10.3 or later (where FilterTextField is an NSSearchField instance)
    if ([FilterTextField respondsToSelector: @selector(setRecentSearches:)]) {
        NSMenu *cellMenu = [[NSMenu alloc] initWithTitle:@"Search Menu"];
        NSMenuItem *recentsTitleItem, *norecentsTitleItem, *recentsItem, *separatorItem, *clearItem;
        id searchCell = [FilterTextField cell];

        [FilterTextField setRecentsAutosaveName:@"logger_output_search"];
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

- (IBAction)FilterOutput:(id)sender
{
    NSScroller *scroller = [[FilterOutput enclosingScrollView] verticalScroller];
    BOOL isScrolledToEnd = (![scroller isEnabled] || [scroller floatValue] == 1);
    NSEnumerator *entryEnumerator = [[LoggerController logEntries] objectEnumerator];
    LoggerEntry *thisEntry;
    
    [_currentFilterString release];
    if (![[FilterTextField stringValue] isEqualToString:@""]) {
        _currentFilterString = [[FilterTextField stringValue] retain];
    } else {
        _currentFilterString = nil;
    }

    [_outputLogLines removeAllObjects];
    
    [FilterProgressIndicator startAnimation:self];
    while (thisEntry = [entryEnumerator nextObject]) {
        if ([thisEntry level] <= 0)
            continue;
        if (_currentFilterString != nil && [[thisEntry text] rangeOfString:_currentFilterString options:NSCaseInsensitiveSearch].location != NSNotFound) {
            [_outputLogLines addObject:thisEntry];
        }
    }
    [FilterProgressIndicator stopAnimation:self];
    
    [FilterOutput reloadData];
    
    if (isScrolledToEnd) {
        [FilterOutput scrollRowToVisible:[_outputLogLines count]-1];
    }
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)aTableView {
    return [_outputLogLines count];
}

- (id)tableView:(NSTableView *)aTableView objectValueForTableColumn:(NSTableColumn *)aTableColumn row:(NSInteger)rowIndex {
    return [[_outputLogLines objectAtIndex:rowIndex] text];
}

- (void)itemDoubleClicked:(NSTableView *)sender {
    NSInteger row = [sender selectedRow];
    if (row < 0 || (NSUInteger)row >= [_outputLogLines count]) return;
    [LoggerController scrollToVisibleLine:[[_outputLogLines objectAtIndex:(NSUInteger)row] text]];
}

@end
