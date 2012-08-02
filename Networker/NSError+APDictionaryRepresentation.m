//
//  NSError+APDictionaryRepresentation.m
//  Core Data Contacts
//
//  Created by Jim Dovey on 2012-08-01.
//  Copyright (c) 2012 Apress Inc. All rights reserved.
//

#import "NSError+APDictionaryRepresentation.h"

@implementation NSError (APDictionaryRepresentation)

+ (NSError *) errorWithJSONDictionaryRepresentation: (NSDictionary *) dictionary
{
    return ( [NSError errorWithDomain: dictionary[@"Domain"]
                                 code: [dictionary[@"Code"] integerValue]
                             userInfo: dictionary[@"UserInfo"]] );
}

- (NSDictionary *) jsonDictionaryRepresentation
{
    NSMutableDictionary * dict = [NSMutableDictionary new];
    dict[@"Code"] = @([self code]);
    dict[@"Domain"] = [self domain];
    if ( [self userInfo] != nil )
        dict[@"UserInfo"] = [self userInfo];
    
    return ( [dict copy] );
}

@end
