//
//  APAddressBookClient.m
//  Core Data Contacts
//
//  Created by Jim Dovey on 2012-07-25.
//  Copyright (c) 2012 Apress Inc. All rights reserved.
//

#import "APAddressBookClient.h"

@implementation APAddressBookClient
{
    id<APAddressBookClientDelegate> _delegate __weak;
    
    NSUInteger                      _inputSize;
    NSMutableData *                 _inputMessageData;
}

- (id) initWithSocket: (CFSocketNativeHandle) sock
             delegate: (id<APAddressBookClientDelegate>) delegate
{
    self = [super init];
    if ( self == nil )
        return ( nil );
    
    NSLog(@"Client attached");
    
    CFReadStreamRef cfRead = NULL;
    CFWriteStreamRef cfWrite = NULL;
    CFStreamCreatePairWithSocket(kCFAllocatorDefault, sock, &cfRead, &cfWrite);
    
    _inputStream = CFBridgingRelease(cfRead);
    _outputStream = CFBridgingRelease(cfWrite);
    
    // register the input stream on the MAIN runloop
    [_inputStream scheduleInRunLoop: [NSRunLoop mainRunLoop]
                            forMode: NSRunLoopCommonModes];
    
    [_inputStream open];
    [_outputStream open];
    [_inputStream setDelegate: self];       // to receive incoming messages
    [_outputStream setDelegate: self];      // for the SendAllData() thing to work
    
    _delegate = delegate;
    
    _inputSize = NSNotFound;        // 'not currently reading a message'
    _inputMessageData = [NSMutableData new];
    
    return ( self );
}

- (void) processDataBlob: (const uint8_t *) blob length: (NSUInteger) length
{
    const uint8_t *p = blob;
    if ( _inputSize == NSNotFound )
    {
        // need to read four bytes of size first
        union {
            uint32_t messageSize;
            uint8_t buf[4];
        } messageBuf;
        
        memcpy(messageBuf.buf, blob, 4);
        
        _inputSize = ntohl(messageBuf.messageSize);
        NSLog(@"Incoming message is %lu bytes in size.", _inputSize);
        
        // clear out our mutable data, ready to accumulate a message blob
        [_inputMessageData setLength: 0];
        
        p += 4;
        length -= 4;
    }
    
    // try to read some message data
    // by definition we need some more data at this point
    NSUInteger needed = _inputSize - [_inputMessageData length];
    
    NSUInteger amountToRead = MIN(needed, length);
    
    // append the input to our accumulator
    [_inputMessageData appendBytes: p length: amountToRead];
    
    // if we've read everything, we dispatch the message and reset our ivars
    if ( amountToRead == needed )
    {
        NSError * jsonError = nil;
        NSDictionary * message = [NSJSONSerialization JSONObjectWithData: _inputMessageData
                                                                 options: 0
                                                                   error: &jsonError];
        
        // set our size marker & empty the data accumulator
        _inputSize = NSNotFound;
        [_inputMessageData setLength: 0];
        
        if ( message == nil )
        {
            NSLog(@"Failed to decode message: %@", jsonError);
            return;
        }
        
        // dispatch the message
        [_delegate client: self handleMessage: message];
    }
    
    p += amountToRead;
    length -= amountToRead;
    
    if ( length > 0 )
    {
        // recurse to handle a following command
        [self processDataBlob: p length: length];
    }
}

- (void) stream: (NSStream *) aStream handleEvent: (NSStreamEvent) eventCode
{
    if ( aStream != _inputStream )
        return;
    
    switch ( eventCode )
    {
        case NSStreamEventHasBytesAvailable:
        {
            NSLog(@"Message data incoming");
            
            // read everything -- accumulate it in our data ivar
#define MAX_READ 1024*16
            uint8_t readBytes[MAX_READ];
            NSInteger sizeRead = [_inputStream read: readBytes maxLength: MAX_READ];
            NSLog(@"Read %ld bytes", sizeRead);
            if ( sizeRead <= 0 )
            {
                NSLog(@"Failed to read message!!! streamError = %@", [_inputStream streamError]);
                return;
            }
            
            [self processDataBlob: readBytes length: sizeRead];
            break;
        }
            
        default:
            break;
    }
}

@end
