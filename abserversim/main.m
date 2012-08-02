//
//  main.m
//  abserversim
//
//  Created by Jim Dovey on 2012-07-25.
//  Copyright (c) 2012 Apress Inc. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AddressBook/AddressBook.h>
#import <sysexits.h>
#import "APRemoteAddressBookBrowser.h"
#import "APRemoteAddressBook.h"
#import "NSError+APDictionaryRepresentation.h"

@interface APSystemAddressBookCommandHandler : NSObject <APRemoteCommandHandler>
@end

@implementation APSystemAddressBookCommandHandler
{
    ABAddressBook *     _addressBook;
}

- (id) init
{
    self = [super init];
    if ( self == nil )
        return ( nil );
    
    _addressBook = [ABAddressBook addressBook];
    
    return ( self );
}

- (void) handleCommand: (NSDictionary *) command
       returningResult: (void (^)(NSDictionary *)) handler
{
    NSLog(@"Received message: %@", command);
    
    id result = nil;
    NSString * name = command[APRemoteAddressBookCommandNameKey];
    NSString * uuid = command[APRemoteAddressBookCommandUUIDKey];
    
    if ( [name isEqualToString: APRemoteAddressBookCommandAllPeople] )
    {
        NSArray * people = [self allPeople];
        result = @{
            APRemoteAddressBookCommandNameKey : APRemoteAddressBookCommandReply,
            APRemoteAddressBookCommandUUIDKey : uuid,
            APRemoteAddressBookCommandValueKey : people
        };
    }
    else if ( [name isEqualToString: APRemoteAddressBookCommandGetMailingAddresses] )
    {
        NSString * identifier = command[APRemoteAddressBookCommandPersonIDKey];
        NSArray * addresses = [self allAddressesForPersonWithIdentifier: identifier];
        result = @{
            APRemoteAddressBookCommandNameKey : APRemoteAddressBookCommandReply,
            APRemoteAddressBookCommandUUIDKey : uuid,
            APRemoteAddressBookCommandValueKey : addresses
        };
    }
    else if ( [name isEqualToString: APRemoteAddressBookCommandGetEmailAddresses] )
    {
        NSString * identifier = command[APRemoteAddressBookCommandPersonIDKey];
        NSArray * emails = [self allEmailsForPersonWithIdentifier: identifier];
        result = @{
            APRemoteAddressBookCommandNameKey : APRemoteAddressBookCommandReply,
            APRemoteAddressBookCommandUUIDKey : uuid,
            APRemoteAddressBookCommandValueKey : emails
        };
    }
    else if ( [name isEqualToString: APRemoteAddressBookCommandGetPhoneNumbers] )
    {
        NSString * identifier = command[APRemoteAddressBookCommandPersonIDKey];
        NSArray * phones = [self allPhoneNumbersForPersonWithIdentifier: identifier];
        result = @{
            APRemoteAddressBookCommandNameKey : APRemoteAddressBookCommandReply,
            APRemoteAddressBookCommandUUIDKey : uuid,
            APRemoteAddressBookCommandValueKey : phones
        };
    }
    else
    {
        id userInfo = @{ NSLocalizedDescriptionKey : @"Unknown command" };
        NSError * error = [NSError errorWithDomain: @"APRemoteAddressBookErrorDomain"
                                              code: 101
                                          userInfo: userInfo];
        result = @{
            APRemoteAddressBookCommandNameKey : APRemoteAddressBookCommandReply,
            APRemoteAddressBookCommandUUIDKey : uuid,
            APRemoteAddressBookCommandErrorKey : [error jsonDictionaryRepresentation]
        };
    }
    
    NSLog(@"Sending result: %@", result);
    
    handler(result);
}

- (NSArray *) allPeople
{
    NSMutableArray * result = [NSMutableArray new];
    for ( ABPerson * person in [[ABAddressBook addressBook] people] )
    {
        NSMutableDictionary * dict = [NSMutableDictionary new];
        dict[APRemoteAddressBookCommandPersonIDKey] = [person uniqueId];
        
        NSString * first = [person valueForProperty: kABFirstNameProperty];
        NSString * last = [person valueForProperty: kABLastNameProperty];
        
        if ( first != nil )
            dict[@"firstName"] = first;
        if ( last != nil )
            dict[@"lastName"] = last;
        
        [result addObject: [dict copy]];
    }
    return ( result );
}

- (NSArray *) allAddressesForPersonWithIdentifier: (NSString *) identifier
{
    ABPerson * person = (ABPerson *)[[ABAddressBook addressBook] recordForUniqueId: identifier];
    if ( person == nil )
        return ( [NSArray array] );
    
    NSMutableArray * result = [NSMutableArray new];
    ABMultiValue * addresses = [person valueForProperty: kABAddressProperty];
    for ( NSUInteger i = 0, max = [addresses count]; i < max; i++ )
    {
        NSDictionary * addressInfo = [addresses valueAtIndex: i];
        
        NSMutableDictionary * address = [NSMutableDictionary new];
        address[@"label"] = ABLocalizedPropertyOrLabel([addresses labelAtIndex: i]);
        
        NSString * street = addressInfo[kABAddressStreetKey];
        NSString * city = addressInfo[kABAddressCityKey];
        NSString * region = addressInfo[kABAddressStateKey];
        NSString * country = addressInfo[kABAddressCountryKey];
        
        if ( street != nil )
            address[@"street"] = street;
        if ( city != nil )
            address[@"city"] = city;
        if ( region != nil )
            address[@"region"] = region;
        if ( country != nil )
            address[@"country"] = country;
        
        [result addObject: [address copy]];
    }
    
    return ( result );
}

- (NSArray *) allEmailsForPersonWithIdentifier: (NSString *) identifier
{
    ABPerson * person = (ABPerson *)[[ABAddressBook addressBook] recordForUniqueId: identifier];
    if ( person == nil )
        return ( [NSArray array] );
    
    NSMutableArray * result = [NSMutableArray new];
    ABMultiValue * emails = [person valueForProperty: kABEmailProperty];
    for ( NSUInteger i = 0, max = [emails count]; i < max; i++ )
    {
        NSMutableDictionary * email = [NSMutableDictionary new];
        email[@"label"] = ABLocalizedPropertyOrLabel([emails labelAtIndex: i]);
        email[@"email"] = [emails valueAtIndex: i];
        [result addObject: [email copy]];
    }
    
    return ( result );
}

- (NSArray *) allPhoneNumbersForPersonWithIdentifier: (NSString *) identifier
{
    ABPerson * person = (ABPerson *)[[ABAddressBook addressBook] recordForUniqueId: identifier];
    if ( person == nil )
        return ( [NSArray array] );
    
    NSMutableArray * result = [NSMutableArray new];
    ABMultiValue * phones = [person valueForProperty: kABPhoneProperty];
    for ( NSUInteger i = 0, max = [phones count]; i < max; i++ )
    {
        NSMutableDictionary * phone = [NSMutableDictionary new];
        phone[@"label"] = ABLocalizedPropertyOrLabel([phones labelAtIndex: i]);
        phone[@"phoneNumber"] = [phones valueAtIndex: i];
        [result addObject: [phone copy]];
    }
    
    return ( result );
}

@end

#pragma mark -

int main(int argc, const char * argv[])
{
    @autoreleasepool
    {
        APSystemAddressBookCommandHandler * handler = nil;
        handler = [APSystemAddressBookCommandHandler new];
        
        APRemoteAddressBookBrowser * browser = nil;
        browser = [APRemoteAddressBookBrowser new];
        
        // this will cause it to advertise on the network, if it works
        [browser setCommandHandler: handler errorHandler: ^(NSError * error) {
            if ( error != nil )
            {
                NSLog(@"Error vending service: %@", error);
                exit(EX_IOERR);
            }
        }];
        
        // handle SIGINT and SIGTERM
        __block BOOL stop = NO;
        dispatch_block_t terminator = ^{ stop = YES; };
        
        dispatch_source_t intSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,
                                                             SIGINT, 0,
                                                             dispatch_get_main_queue());
        dispatch_source_t termSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,
                                                              SIGTERM, 0,
                                                              dispatch_get_main_queue());
        dispatch_source_set_event_handler(intSource, terminator);
        dispatch_source_set_event_handler(termSource, terminator);
        dispatch_resume(intSource);
        dispatch_resume(termSource);
        
        while (stop == NO )
        {
            @autoreleasepool
            {
                // this method returns each time a source is handled
                [[NSRunLoop currentRunLoop] runMode: NSDefaultRunLoopMode
                                         beforeDate: [NSDate distantFuture]];
            }
        }
        
        dispatch_source_cancel(intSource);
        dispatch_source_cancel(termSource);
    }
    
    return ( EX_OK );
}

