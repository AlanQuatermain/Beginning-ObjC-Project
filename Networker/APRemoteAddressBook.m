//
//  APRemoteAddressBook.m
//  Core Data Contacts
//
//  Created by Jim Dovey on 2012-07-25.
//  Copyright (c) 2012 Apress Inc. All rights reserved.
//

#import "APRemoteAddressBook.h"

NSString * const APRemoteAddressBookErrorDomain = @"APRemoteAddressBookErrorDomain";

NSString * const APRemoteAddressBookCommandNameKey = @"command";
NSString * const APRemoteAddressBookCommandUUIDKey = @"uuid";
NSString * const APRemoteAddressBookCommandPersonIDKey = @"personID";
NSString * const APRemoteAddressBookCommandValueKey = @"value";
NSString * const APRemoteAddressBookCommandErrorKey = @"error";

// command names
NSString * const APRemoteAddressBookCommandAllPeople = @"allPeople";
NSString * const APRemoteAddressBookCommandGetMailingAddresses = @"getAddresses";
NSString * const APRemoteAddressBookCommandGetEmailAddresses = @"getEmails";
NSString * const APRemoteAddressBookCommandGetPhoneNumbers = @"getPhoneNumbers";
NSString * const APRemoteAddressBookCommandReply = @"reply";

@implementation APRemoteAddressBook
{
    NSInputStream *         _inputStream;
    NSOutputStream *        _outputStream;
    
    NSOperationQueue *      _networkQ;
    
    // NSUUID -> APRemoteXPCReply_t block
    NSMutableDictionary *   _replyHandlersByUUID;
    
    __weak id<APRemoteAddressBookDelegate> _delegate;
    
    NSUInteger              _inputSize;
    NSMutableData *         _inputMessageData;
}

- (id) initWithResolvedService: (NSNetService *) resolvedService
                      delegate: (id<APRemoteAddressBookDelegate>) delegate
{
    self = [super init];
    if ( self == nil )
        return ( nil );
    
    if ( [resolvedService getInputStream: &_inputStream
                            outputStream: &_outputStream] == NO )
        return ( nil );
    
    _delegate = delegate;
    _inputSize = NSNotFound;
    _inputMessageData = [NSMutableData new];
    
    _networkQ = [NSOperationQueue new];
    [_networkQ setMaxConcurrentOperationCount: 1];
    
    [_inputStream setDelegate: self];
    
    [_inputStream scheduleInRunLoop: [NSRunLoop mainRunLoop] forMode: NSRunLoopCommonModes];
    
    // NOT scheduling the output stream here: it's going to be scheduled only upon
    //  need while a single operation is sending data and needs to wait for output
    //  buffer space to become available.
    
    [_inputStream open];
    [_outputStream open];
    
    _replyHandlersByUUID = [NSMutableDictionary new];
    
    return ( self );
}

- (void) dealloc
{
    NSLog(@"Remote address book deallocating: %@", self);
    [_networkQ cancelAllOperations];
    if ( [_inputStream streamStatus] != NSStreamStatusClosed )
    {
        [_inputStream removeFromRunLoop: [NSRunLoop mainRunLoop] forMode: NSRunLoopCommonModes];
        [_inputStream close];
    }
    if ( [_outputStream streamStatus] != NSStreamStatusClosed )
    {
        [_outputStream close];
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
            if ( _inputSize == NSNotFound )
            {
                // need to read four bytes of size first
                uint32_t messageSize = 0;
                NSInteger sizeRead = [_inputStream read: (uint8_t *)&messageSize maxLength: 4];
                if ( sizeRead < 4 )
                {
                    // something horrible happened!
                    NSLog(@"ARGH! Couldn't read message size from stream, only got %ld bytes!", sizeRead);
                    return;
                }
                
                // byte-swap it properly
                _inputSize = ntohl(messageSize);
                NSLog(@"Incoming message is %lu bytes in size.", _inputSize);
                
                // clear out our mutable data, ready to accumulate a message blob
                [_inputMessageData setLength: 0];
            }
            
            // try to read some message data
            // by definition we need some more data at this point
            NSUInteger needed = _inputSize - [_inputMessageData length];
            
#define MAX_READ 1024*16
            uint8_t readBytes[MAX_READ];
            NSUInteger amountToRead = MIN(needed, MAX_READ);     // MAX 16KB at a time
            
            NSInteger numRead = [_inputStream read: readBytes maxLength: amountToRead];
            if ( numRead <= 0 )
                return;  // no data available
            
            // append the input to our accumulator
            [_inputMessageData appendBytes: readBytes length: numRead];
            
            // if we've read everything, we dispatch the message and reset our ivars
            if ( numRead == needed )
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
                NSUUID * uuid = [[NSUUID alloc] initWithUUIDString: message[APRemoteAddressBookCommandUUIDKey]];
                void (^reply)(NSArray *, NSError *) = _replyHandlersByUUID[uuid];
                
                // if the reply block has been consumed, a timeout occurred
                if ( reply == nil )
                    break;
                
                // otherwise, we consume it
                [_replyHandlersByUUID removeObjectForKey: uuid];
                
                reply(message[APRemoteAddressBookCommandValueKey],
                      message[APRemoteAddressBookCommandErrorKey]);
            }
            
            break;
        }
            
        default:
            break;
    }
}

- (void) postMessage: (NSDictionary *) message
          replyingTo: (void (^)(NSArray *, NSError *)) reply
{
    // ensure the reply block is copied to the heap
    reply = [reply copy];
    
    __weak APRemoteAddressBook * weakSelf = self;
    NSBlockOperation * operation = [NSBlockOperation blockOperationWithBlock: ^{
        APRemoteAddressBook * strongSelf = weakSelf;
        if ( strongSelf == nil )
            return;
        
        NSError * error = nil;
        NSData * jsonData = [NSJSONSerialization dataWithJSONObject: message
                                                            options: 0
                                                              error: &error];
        if ( jsonData == nil )
        {
            NSLog(@"Failed to encode message: %@. Message = %@", error, message);
            reply(nil, error);
            return;
        }
        
        if ( SendAllData(_outputStream, jsonData, &error) == NO )
        {
            // an error occurred
            NSLog(@"Error sending message data: %@. Message = %@.", error, message);
            reply(nil, error);
            return;
        }
        
        // store the reply block, referenced by the command's unique ID
        NSUUID * uuid = [[NSUUID alloc] initWithUUIDString: message[APRemoteAddressBookCommandUUIDKey]];
        strongSelf->_replyHandlersByUUID[uuid] = reply;
        
        // we want a reply to arrive within ten seconds. If no reply arrives
        // (or if it's garbled) then we'll eventually time out and reply to the
        // client with an error message.
        double delayInSeconds = 10.0;
        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, delayInSeconds * NSEC_PER_SEC);
        dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
            APRemoteAddressBook * delayStrongSelf = weakSelf;
            void (^aReply)(NSArray *, NSError *) = delayStrongSelf->_replyHandlersByUUID[uuid];
            if ( aReply != nil )
            {
                // a real reply hasn't arrived yet -- send a timeout error
                aReply(nil, [NSError errorWithDomain: NSURLErrorDomain
                                                code: NSURLErrorTimedOut
                                            userInfo: nil]);
                [delayStrongSelf->_replyHandlersByUUID removeObjectForKey: uuid];
            }
        });
    }];
    
    __weak NSOperation * weakOp = operation;
    [operation setCompletionBlock: ^{
        NSOperation * strongOp = weakOp;
        
        // if cancelled, inform the waiting client
        if ( [strongOp isCancelled] )
        {
            NSDictionary * info = @{ NSLocalizedDescriptionKey : NSLocalizedString(@"The request was cancelled.", @"error") };
            NSError * error = [NSError errorWithDomain: NSOSStatusErrorDomain
                                                  code: userCanceledErr
                                              userInfo: info];
            reply(nil, error);
        }
    }];
    
    [_networkQ addOperation: operation];
}

- (void) allPeople: (void (^)(NSArray *, NSError *)) reply
{
    NSDictionary * command = @{
        APRemoteAddressBookCommandNameKey : APRemoteAddressBookCommandAllPeople,
        APRemoteAddressBookCommandUUIDKey : [[NSUUID UUID] UUIDString]
    };
    [self postMessage: command replyingTo: reply];
}

- (void) mailingAddressesForPersonWithIdentifier: (NSString *) identifier
                                           reply: (void (^)(NSArray *, NSError *)) reply
{
    NSDictionary * command = @{
        APRemoteAddressBookCommandNameKey : APRemoteAddressBookCommandGetMailingAddresses,
        APRemoteAddressBookCommandUUIDKey : [[NSUUID UUID] UUIDString],
        APRemoteAddressBookCommandPersonIDKey : identifier
    };
    [self postMessage: command replyingTo: reply];
}

- (void) emailAddressesForPersonWithIdentifier: (NSString *) identifier
                                         reply: (void (^)(NSArray *, NSError *)) reply
{
    NSDictionary * command = @{
        APRemoteAddressBookCommandNameKey : APRemoteAddressBookCommandGetEmailAddresses,
        APRemoteAddressBookCommandUUIDKey : [[NSUUID UUID] UUIDString],
        APRemoteAddressBookCommandPersonIDKey : identifier
    };
    [self postMessage: command replyingTo: reply];
}

- (void) phoneNumbersForPersonWithIdentifier: (NSString *) identifier
                                       reply: (void (^)(NSArray *, NSError *)) reply
{
    NSDictionary * command = @{
        APRemoteAddressBookCommandNameKey : APRemoteAddressBookCommandGetPhoneNumbers,
        APRemoteAddressBookCommandUUIDKey : [[NSUUID UUID] UUIDString],
        APRemoteAddressBookCommandPersonIDKey : identifier
    };
    [self postMessage: command replyingTo: reply];
}

- (void) disconnect
{
    [_inputStream setDelegate: nil];
    [_outputStream setDelegate: nil];
    
    [_inputStream removeFromRunLoop: [NSRunLoop mainRunLoop]
                            forMode: NSRunLoopCommonModes];
    [_outputStream removeFromRunLoop: [NSRunLoop mainRunLoop]
                             forMode: NSRunLoopCommonModes];
    
    [_inputStream close];
    [_outputStream close];
    
    [_delegate addressBookDidDisconnect: self];
}

@end
