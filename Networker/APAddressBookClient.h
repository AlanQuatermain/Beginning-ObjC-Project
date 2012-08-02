//
//  APAddressBookClient.h
//  Core Data Contacts
//
//  Created by Jim Dovey on 2012-07-25.
//  Copyright (c) 2012 Apress Inc. All rights reserved.
//

#import <Foundation/Foundation.h>

#import "APRemoteAddressBookInterface.h"

@interface APAddressBookClient : NSObject  <NSStreamDelegate>
- (id) initWithSocket: (CFSocketNativeHandle) sock
             delegate: (id<APAddressBookClientDelegate>) delegate;
@property (nonatomic, readonly) NSInputStream * inputStream;
@property (nonatomic, readonly) NSOutputStream * outputStream;
@end
