/*
 *
 * @APPLE_LICENSE_HEADER_START@
 *
 * Copyright (c) 1998-2003 Apple Computer, Inc.  All Rights Reserved.
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


#import <Cocoa/Cocoa.h>
#import <IOKit/IOKitLib.h>

NSString *USBLogTimestamp(void);

@protocol USBLoggerListener <NSObject>
- (void)usbLoggerTextAvailable:(NSString *)text forLevel:(int)level;
@end

// All lifecycle methods and listener callbacks run on the main thread.
@interface USBLogger : NSObject {
    id<USBLoggerListener> _listener; // The controller owns the logger.
    int _loggingLevel;
    BOOL _isLogging;
    BOOL _initialDevices;
    IONotificationPortRef _notificationPort;
    io_iterator_t _addedIterator;
    io_iterator_t _removedIterator;
    NSTask *_logTask;
    NSPipe *_outputPipe;
    NSPipe *_errorPipe;
    NSMutableData *_pendingOutput;
    NSTimer *_readTimer;
}
- (instancetype)initWithListener:(id<USBLoggerListener>)listener level:(int)level;
- (BOOL)beginLogging;
- (void)invalidate;
- (void)setLevel:(int)level;
- (BOOL)isLogging;
@end
