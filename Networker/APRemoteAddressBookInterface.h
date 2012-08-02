//
//  APRemoteAddressBookInterface.h
//  Core Data Contacts
//
//  Created by Jim Dovey on 2012-07-25.
//  Copyright (c) 2012 Apress Inc. All rights reserved.
//

#import <Foundation/Foundation.h>

@class APAddressBookClient;

// NSError domain
extern NSString * const APRemoteAddressBookErrorDomain;

// error codes within our domain
typedef NS_ENUM(NSInteger, APRemoteAddressBookError)
{
    APRemoteAddressBookNoError,
    APRemoteAddressBookErrorServiceNotFound,
};

// a useful send-all function for an output stream
// will schedule the output stream on the current runloop and spin it waiting for
// an event notifying of available output buffer space if not all data can be sent
// in the first try.
// NB: This requires that the output stream has a valid delegate set already.
// Implementation is in APRemoteAddressBookBrowser.m
extern BOOL SendAllData(NSOutputStream * outputStream, NSData * data, NSError ** error);

// command keys
extern NSString * const APRemoteAddressBookCommandNameKey;
extern NSString * const APRemoteAddressBookCommandUUIDKey;
extern NSString * const APRemoteAddressBookCommandPersonIDKey;
extern NSString * const APRemoteAddressBookCommandValueKey;
extern NSString * const APRemoteAddressBookCommandErrorKey;

// command names
extern NSString * const APRemoteAddressBookCommandAllPeople;
extern NSString * const APRemoteAddressBookCommandGetMailingAddresses;
extern NSString * const APRemoteAddressBookCommandGetEmailAddresses;
extern NSString * const APRemoteAddressBookCommandGetPhoneNumbers;
extern NSString * const APRemoteAddressBookCommandReply;

@protocol APRemoteAddressBook <NSObject>
- (void) allPeople: (void (^)(NSArray *, NSError *)) reply;
- (void) mailingAddressesForPersonWithIdentifier: (NSString *) identifier
                                           reply: (void (^)(NSArray *, NSError *)) reply;
- (void) emailAddressesForPersonWithIdentifier: (NSString *) identifier
                                         reply: (void (^)(NSArray *, NSError *)) reply;
- (void) phoneNumbersForPersonWithIdentifier: (NSString *) identifier
                                       reply: (void (^)(NSArray *, NSError *)) reply;
- (void) disconnect;
@end

@protocol APRemoteCommandHandler <NSObject>
- (void) handleCommand: (NSDictionary *) command
       returningResult: (void (^)(NSDictionary *packagedResult)) handler;
@end

@protocol APRemoteAddressBookBrowser <NSObject>
- (void) setCommandHandler: (id<APRemoteCommandHandler>) commandHandler
              errorHandler: (void (^)(NSError *)) errorHandler;
- (void) availableServiceNames: (void (^)(NSArray *, NSError *)) reply;
- (void) connectToServiceWithName: (NSString *) name
                     replyHandler: (void (^)(id<APRemoteAddressBook>, NSError *)) replyHandler;
@end

@protocol APAddressBookClientDelegate <NSObject>
- (void) client: (APAddressBookClient *) client
  handleMessage: (NSDictionary *) message;
@end
