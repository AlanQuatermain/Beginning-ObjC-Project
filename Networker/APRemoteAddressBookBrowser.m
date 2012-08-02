//
//  APRemoteAddressBookBrowser.m
//  Core Data Contacts
//
//  Created by Jim Dovey on 2012-07-25.
//  Copyright (c) 2012 Apress Inc. All rights reserved.
//

#import "APRemoteAddressBookBrowser.h"
#import "APRemoteAddressBook.h"
#import "APAddressBookClient.h"

#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <netdb.h>

BOOL SendAllData(NSOutputStream * outputStream, NSData * data, NSError ** error)
{
    // byte swapping!
    NSUInteger length = [data length];
    uint32_t size = htonl(length);
    NSInteger sent = [outputStream write: (const uint8_t *)&size
                               maxLength: 4];
    if ( sent == 0 )
    {
        NSLog(@"Sending message size: zero bytes sent!");
        if ( error != NULL )
            *error = [outputStream streamError];
        return ( NO );
    }
    
    // now send the data
    NSUInteger totalSent = 0;
    const uint8_t *p = [data bytes];
    do
    {
        sent = [outputStream write: p maxLength: length - totalSent];
        if ( sent <= 0 )
        {
            NSLog(@"Sending message data blob, sent %ld bytes", sent);
            if ( error != NULL )
                *error = [outputStream streamError];
            return ( NO );
        }
        
        totalSent += sent;
        p += sent;
        
        if ( totalSent < length )
        {
            // wait for the stream to have room to write some more
            [outputStream scheduleInRunLoop: [NSRunLoop currentRunLoop]
                                    forMode: NSDefaultRunLoopMode];
            
            // spin this runloop until an event happens--
            // we actually ignore the space-available event, we're only
            // interested in its waking up this runloop invocation.
            @autoreleasepool
            {
                // this effectively means 'run until an event occurs'
                [[NSRunLoop currentRunLoop] runMode: NSDefaultRunLoopMode
                                         beforeDate: [NSDate distantFuture]];
            }
            
            // unregister the stream now
            [outputStream removeFromRunLoop: [NSRunLoop currentRunLoop]
                                    forMode: NSDefaultRunLoopMode];
        }
        
    } while (totalSent < length);
    
    NSLog(@"SendAllData() returning, totalSent=%lu, length=%lu", totalSent, length);
    return ( totalSent == length );
}

static BOOL _SocketAddressFromString(NSString * addrStr, BOOL isNumeric,
                                     UInt16 port,
                                     struct sockaddr_storage * outAddr,
                                     NSError ** outError)
{
    // Flags for getaddrinfo():
    //
    // `AI_ADDRCONFIG`: Only return IPv4 or IPv6 if the local host has configured
    // interfaces for those types.
    //
    // `AI_V4MAPPED`: If no IPv6 addresses found, return an IPv4-mapped IPv6
    // address for any IPv4 addresses found.
    int flags = AI_ADDRCONFIG|AI_V4MAPPED;
    
    // If providing a numeric IPv4 or IPv6 string, tell getaddrinfo() not to
    // do DNS name lookup.
    if ( isNumeric )
        flags |= AI_NUMERICHOST;
    
    // We're assuming TCP at this point
    struct addrinfo hints = {
        .ai_flags = flags,
        .ai_family = AF_INET6,       // using AF_INET6 with 4to6 support
        .ai_socktype = SOCK_STREAM,
        .ai_protocol = IPPROTO_TCP
    };
    
    struct addrinfo *pLookup = NULL;
    
    // Hrm-- this is synchronous, which is required since we can't init asynchronously
    int err = getaddrinfo([addrStr UTF8String], NULL, &hints, &pLookup);
    if ( err != 0 )
    {
        if ( outError != NULL )
        {
            NSDictionary * userInfo = @{ NSLocalizedDescriptionKey : @(gai_strerror(err)) };
            *outError = [NSError errorWithDomain: @"GetAddrInfoErrorDomain"
                                            code: err
                                        userInfo: userInfo];
        }
        
        return ( NO );
    }
    
    // Copy the returned address to the output parameter
    memcpy(outAddr, pLookup->ai_addr, pLookup->ai_addr->sa_len);
    
    switch ( outAddr->ss_family )
    {
        case AF_INET:
        {
            struct sockaddr_in *p = (struct sockaddr_in *)outAddr;
            p->sin_port = htons(port);  // remember to put in network byte-order!
            break;
        }
        case AF_INET6:
        {
            struct sockaddr_in6 *p = (struct sockaddr_in6 *)outAddr;
            p->sin6_port = htons(port); // network byte order again
            break;
        }
        default:
            return ( NO );
    }
    
    // Have to release the returned address information here
    freeaddrinfo(pLookup);
    return ( YES );
}

#pragma mark -

@implementation APRemoteAddressBookBrowser
{
    NSNetServiceBrowser *       _browser;
    NSMutableDictionary *       _servicesByDomain;
    
    id<APRemoteCommandHandler>  _commandHandler;
    CFSocketNativeHandle        _serverSocket;
    dispatch_source_t           _listenSource;
    NSNetService *              _publishedService;
    
    NSMutableSet *              _clients;
    
    NSMutableSet *              _remoteAddressBooks;
    
    // NSNetService name string to OS_dispatch_semaphore (dispatch_semaphore_t)
    NSMutableDictionary *       _serviceResolutionSemaphores;
}

- (id) init
{
    self = [super init];
    if ( self == nil )
        return ( nil );
    
    _servicesByDomain = [NSMutableDictionary new];
    _serviceResolutionSemaphores = [NSMutableDictionary new];
    _clients = [NSMutableSet new];
    _remoteAddressBooks = [NSMutableSet new];
    
    _browser = [NSNetServiceBrowser new];
    [_browser setDelegate: self];
    [_browser searchForServicesOfType: @"_apad._tcp" inDomain: @""];
    
    return ( self );
}

- (void) dealloc
{
    [_publishedService stop];
    [_browser stop];
    [_servicesByDomain enumerateKeysAndObjectsUsingBlock: ^(id key, id obj, BOOL *stop) {
        [obj makeObjectsPerformSelector: @selector(stop)];
    }];
}

- (void) setCommandHandler: (id<APRemoteCommandHandler>) commandHandler
              errorHandler: (void (^)(NSError *)) errorHandler
{
    // listen for connections using the BSD API and some GCD goodness
    NSHost * localHost = [NSHost currentHost];
    struct sockaddr_storage saddr = {0};
    NSError * error = nil;
    
    if ( _SocketAddressFromString([localHost address], YES, 0, &saddr, &error) == NO )
    {
        NSLog(@"Failed to get socket address from string %@: %@", [localHost address], error);
        return;
    }
    
    _serverSocket = socket(saddr.ss_family, SOCK_STREAM, IPPROTO_TCP);
    if ( _serverSocket < 0 )
    {
        error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        NSLog(@"Failed to create listening socket: %@", error);
        if ( errorHandler != nil )
            errorHandler(error);
        return;
    }
    
    int val = 1;
    if ( setsockopt(_serverSocket, SOL_SOCKET, SO_REUSEADDR, &val, sizeof(val)) < 0 )
    {
        NSLog(@"Failed to set SO_REUSEADDR on listening socket: %d (%s)", errno, strerror(errno));
    }
    if ( setsockopt(_serverSocket, SOL_SOCKET, SO_NOSIGPIPE, &val, sizeof(val)) < 0 )
    {
        NSLog(@"Failed to set SO_NOSIGPIPE on listening socket: %d (%s)", errno, strerror(errno));
    }
    if ( bind(_serverSocket, (const struct sockaddr *)&saddr, saddr.ss_len) < 0 )
    {
        error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        NSLog(@"Error binding listening socket: %@", error);
        close(_serverSocket);
        _serverSocket = -1;
        if ( errorHandler != nil )
            errorHandler(error);
        return;
    }
    
    listen(_serverSocket, 16);
    _listenSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, _serverSocket, 0, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0));
    
    dispatch_source_set_event_handler(_listenSource, ^{
        int lfd = (int)dispatch_source_get_handle(_listenSource);
        CFSocketNativeHandle clientSock = accept(lfd, NULL, NULL);
        if ( clientSock < 0 )
        {
            NSLog(@"Failed to accept new connection: %d (%s)", errno, strerror(errno));
            return;
        }
        
        NSLog(@"Accepted new connection");
        
        APAddressBookClient * client = nil;
        client = [[APAddressBookClient alloc] initWithSocket: clientSock
                                                    delegate: self];
        [_clients addObject: client];
    });
    
    dispatch_resume(_listenSource);
    
    // Find out what port we were assigned.
    struct sockaddr_storage myAddr = {0};
    socklen_t slen = sizeof(struct sockaddr_storage);
    getsockname(_serverSocket, (struct sockaddr *)&myAddr, &slen);
    
    char addrStr[INET6_ADDRSTRLEN];
    struct sockaddr_in *pIn4 = (struct sockaddr_in *)&myAddr;
    struct sockaddr_in6 *pIn6 = (struct sockaddr_in6 *)&myAddr;
    inet_ntop(myAddr.ss_family, (myAddr.ss_family == AF_INET ? (void *)&pIn4->sin_addr : (void *)&pIn6->sin6_addr), addrStr, INET6_ADDRSTRLEN);
    
    UInt16 port = (myAddr.ss_family == AF_INET ? ntohs(pIn4->sin_port) : ntohs(pIn6->sin6_port));
    _publishedService = [[NSNetService alloc] initWithDomain: @""
                                                        type: @"_apad._tcp"
                                                        name: @"" // default name
                                                        port: port];
    [_publishedService publishWithOptions: 0];
    
    _commandHandler = commandHandler;
}

- (void) stream: (NSStream *) aStream handleEvent: (NSStreamEvent) eventCode
{
    // we actually ignore the events-- we only register so we can get a
    // runloop woken up when we're waiting for output buffer space
}

- (void) client: (APAddressBookClient *) client
  handleMessage: (NSDictionary *) message
{
    [_commandHandler handleCommand: message returningResult: ^(NSDictionary *result) {
        NSError * jsonError = nil;
        NSData * jsonData = [NSJSONSerialization dataWithJSONObject: result
                                                            options: 0
                                                              error: &jsonError];
        if ( jsonData == nil )
        {
            NSLog(@"Error building JSON reply: %@. Message = %@. Reply = %@",
                  jsonError, message, result);
            return;
        }
        
        NSError * sendError = nil;
        if ( SendAllData(client.outputStream, jsonData, &sendError) == NO )
        {
            NSLog(@"Error replying to message: %@. Message = %@. Reply = %@",
                  sendError, message, result);
        }
    }];
}

- (void) availableServiceNames: (void (^)(NSArray *, NSError *)) reply
{
    NSMutableSet * allNames = [NSMutableSet new];
    NSPredicate * nullFilter = [NSPredicate predicateWithBlock: ^BOOL(id evaluatedObject, NSDictionary *bindings) {
        if ( [evaluatedObject isKindOfClass: [NSNull class]] )
            return ( NO );
        return ( YES );
    }];
    
    [_servicesByDomain enumerateKeysAndObjectsUsingBlock: ^(id key, id obj, BOOL *stop) {
        NSArray * names = [obj valueForKey: @"name"];
        [allNames addObjectsFromArray: [names filteredArrayUsingPredicate: nullFilter]];
    }];
    
    // sort it
    NSArray * sorted = [[allNames allObjects] sortedArrayUsingSelector: @selector(caseInsensitiveCompare:)];
    
    // post it back
    reply(sorted, nil);
}

- (void) connectToServiceWithName: (NSString *) name
                     replyHandler: (void (^)(id<APRemoteAddressBook>, NSError *)) replyHandler
{
    NSLog(@"Connecting to service named '%@'", name);
    __block NSNetService * selected = nil;
    
    // search individual domains -- look in "local" domain first, then any others
    NSMutableArray * localServices = _servicesByDomain[@"local."];
    NSLog(@"Searching local services: %@", localServices);
    for ( NSNetService * service in localServices )
    {
        if ( [[service name] isEqualToString: name] )
        {
            NSLog(@"Found local service: %@", service);
            selected = service;
            break;
        }
    }
    
    if ( selected == nil )
    {
        // look in other domains
        [_servicesByDomain enumerateKeysAndObjectsUsingBlock: ^(id key, id obj, BOOL *stop) {
            if ( [key isEqualToString: @"local."] )
                return;     // skip local domain, we've already looked there
            
            NSLog(@"Searching services in domain '%@': %@", key, obj);
            for ( NSNetService * service in obj )
            {
                if ( [[service name] isEqualToString: name] )
                {
                    NSLog(@"Found service: %@", service);
                    selected = service;
                    *stop = YES;
                    break;
                }
            }
        }];
    }
    
    if ( selected == nil )
    {
        NSDictionary * info = @{ NSLocalizedDescriptionKey : NSLocalizedString(@"An address book service with the provided name could not be found.", @"error") };
        NSError * error = [NSError errorWithDomain: APRemoteAddressBookErrorDomain
                                              code: APRemoteAddressBookErrorServiceNotFound
                                          userInfo: info];
        replyHandler(nil, error);
        return;
    }
    
    if ( [selected hostName] == nil )
    {
        void (^replyCopy)(id<APRemoteAddressBook>, NSError *) = [replyHandler copy];
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);        // already 'locked'
            _serviceResolutionSemaphores[[selected name]] = sem;
            
            // schedule it in the main run loop so the resolve success/failure will
            // trigger there while we're blocking on the semaphore
            [selected scheduleInRunLoop: [NSRunLoop mainRunLoop]
                                forMode: NSRunLoopCommonModes];
            
            // ensure it's got a delegate set, so we know whether it resolved or not
            [selected setDelegate: self];
            
            // start the lookup
            [selected resolveWithTimeout: 10.0];
            
            // wait for the semaphore to be triggered by resolution/failure
            if ( dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) != 0 )
            {
                // timed out
                NSError * error = [NSError errorWithDomain: NSNetServicesErrorDomain
                                                      code: NSNetServicesTimeoutError
                                                  userInfo: nil];
                NSLog(@"Timeout when resolving: %@", error);
                replyCopy(nil, error);
            }
            else
            {
                // if an error occurred, the semaphore in the dictionary has been
                // replaced by the error dictionary
                NSDictionary * errorDict = _serviceResolutionSemaphores[[selected name]];
                [_serviceResolutionSemaphores removeObjectForKey: [selected name]];
                
                if ( [errorDict isKindOfClass: [NSDictionary class]] )
                {
                    // error!
                    NSError * error = [NSError errorWithDomain: errorDict[NSNetServicesErrorDomain]
                                                          code: [errorDict[NSNetServicesErrorCode] intValue]
                                                      userInfo: nil];
                    NSLog(@"Error resolving: %@", error);
                    replyCopy(nil, error);
                }
                else
                {
                    // it resolved successfully
                    APRemoteAddressBook * book = [[APRemoteAddressBook alloc] initWithResolvedService: selected delegate: self];
                    [_remoteAddressBooks addObject: book];  // keep it alive
                    NSLog(@"Resolved successfully, book = %@", book);
                    replyCopy(book, nil);
                }
            }
        });
    }
    
    // expect a reply or a timeout/resolution error
}

#pragma mark - APRemoteAddressBookDelegate Implementation

- (void) addressBookDidDisconnect: (APRemoteAddressBook *) book
{
    [_remoteAddressBooks removeObject: book];   // let it be released
}

#pragma mark - NSNetServiceBrowserDelegate Implementation

- (void) netServiceBrowser: (NSNetServiceBrowser *) aNetServiceBrowser
            didFindService: (NSNetService *) aNetService
                moreComing: (BOOL) moreComing
{
    NSMutableArray * servicesInDomain = _servicesByDomain[aNetService.domain];
    if ( servicesInDomain == nil )
    {
        servicesInDomain = [NSMutableArray new];
        _servicesByDomain[aNetService.domain] = servicesInDomain;
    }
    
    [servicesInDomain addObject: aNetService];
}

- (void) netServiceBrowser: (NSNetServiceBrowser *) aNetServiceBrowser
          didRemoveService: (NSNetService *) aNetService
                moreComing: (BOOL) moreComing
{
    [aNetService stop];
    NSMutableArray * servicesInDomain = _servicesByDomain[aNetService.domain];
    [servicesInDomain removeObject: aNetService];
}

#pragma mark - NSNetServiceDelegate Implementation

- (void) netServiceDidResolveAddress: (NSNetService *) sender
{
    dispatch_semaphore_t sem = _serviceResolutionSemaphores[[sender name]];
    if ( sem == nil )
        return;
    
    // wake up the waiting thread
    dispatch_semaphore_signal(sem);
    [_serviceResolutionSemaphores removeObjectForKey: [sender name]];
}

- (void) netService: (NSNetService *) sender
      didNotResolve: (NSDictionary *) errorDict
{
    dispatch_semaphore_t sem = _serviceResolutionSemaphores[[sender name]];
    _serviceResolutionSemaphores[[sender name]] = errorDict;
    
    if ( sem == nil )
        return;
    
    // wake up the waiting thread
    dispatch_semaphore_signal(sem);
}

@end
