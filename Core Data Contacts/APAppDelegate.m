//
//  APAppDelegate.m
//  Core Data Contacts
//
//  Created by Jim Dovey on 2012-07-15.
//  Copyright (c) 2012 Apress Inc. All rights reserved.
//

#import "APAppDelegate.h"
#import "APAddressBookImporter.h"
#import "APRemoteAddressBook.h"
#import "APRemoteAddressBookWindowController.h"

#import "Person.h"
#import "MailingAddress.h"
#import "EmailAddress.h"
#import "PhoneNumber.h"

// APRemoteAddressBook isn't a member of this target, so we will have to
// define the constants here so the app still links
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

@implementation APAppDelegate
{
    NSXPCConnection *               _xpcConnection;
    id<APRemoteAddressBookBrowser>  _browser;
    
    APRemoteBrowserWindowController *_browserWindow;
    NSMutableSet *                  _remoteBookWindows;
    NSMutableDictionary *           _remoteBookObservers;
}

@synthesize persistentStoreCoordinator = _persistentStoreCoordinator;
@synthesize managedObjectModel = _managedObjectModel;
@synthesize managedObjectContext = _managedObjectContext;

- (void) awakeFromNib
{
    _remoteBookWindows = [NSMutableSet new];
    _remoteBookObservers = [NSMutableDictionary new];
    
    if ( _personSortDescriptors == nil )
    {
        [self willChangeValueForKey: @"personSortDescriptors"];
        _personSortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey: @"lastName"
                                                                 ascending: YES]];
        [self didChangeValueForKey: @"personSortDescriptors"];
    }
    if ( _labelSortDescriptors == nil )
    {
        [self willChangeValueForKey: @"labelSortDescriptors"];
        _labelSortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey: @"label"
                                                                ascending: YES]];
        [self didChangeValueForKey: @"labelSortDescriptors"];
    }
}

- (void)importAddressBookData
{
    APAddressBookImporter * importer = [[APAddressBookImporter alloc] initWithParentObjectContext: self.managedObjectContext];
    [importer beginImportingWithCompletion: ^(NSError *error) {
        if ( error != nil )
        {
            [NSApp presentError: error];
        }
        
        if ( [self.managedObjectContext hasChanges] )
        {
            [self.managedObjectContext performBlock: ^{
                NSError * saveError = nil;
                if ( [self.managedObjectContext save: &saveError] == NO )
                    [NSApp presentError: saveError];
            }];
        }
    }];
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
    NSFetchRequest *request = [[NSFetchRequest alloc] initWithEntityName:@"Person"];
    // simple request: we just want all Person objects, so no predicates
    
    // we actually only want to know how many there are, so we use this special
    // method on NSManagedObjectContext:
    NSManagedObjectContext * context = [self managedObjectContext];
    [context performBlock: ^{
        // we don't care about the error-- if something goes wrong, we still
        // need to pull in some data
        NSUInteger count = [context countForFetchRequest: request error: NULL];
#if 0
        if ( count != 0 )
        {
            for ( NSManagedObject * object in [context executeFetchRequest: request error: NULL] )
            {
                [context deleteObject: object];
            }
            
            [context save: NULL];
            count = 0;
        }
#endif
        if ( count == 0 )
        {
            // back out to the main thread-- don't hog the context's queue
            dispatch_async(dispatch_get_main_queue(), ^{
                [self importAddressBookData];
            });
        }
    }];
}

// Returns the directory the application uses to store the Core Data store file. This code uses a directory named "com.apress.beginning-objective-c.Core_Data_Contacts" in the user's Application Support directory.
- (NSURL *)applicationFilesDirectory
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSURL *appSupportURL = [[fileManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask] lastObject];
    return [appSupportURL URLByAppendingPathComponent:@"com.apress.beginning-objective-c.Core_Data_Contacts"];
}

// Creates if necessary and returns the managed object model for the application.
- (NSManagedObjectModel *)managedObjectModel
{
    if (_managedObjectModel) {
        return _managedObjectModel;
    }
	
    NSURL *modelURL = [[NSBundle mainBundle] URLForResource:@"Core_Data_Contacts" withExtension:@"momd"];
    _managedObjectModel = [[NSManagedObjectModel alloc] initWithContentsOfURL:modelURL];
    return _managedObjectModel;
}

// Returns the persistent store coordinator for the application. This implementation creates and return a coordinator, having added the store for the application to it. (The directory for the store is created, if necessary.)
- (NSPersistentStoreCoordinator *)persistentStoreCoordinator
{
    if (_persistentStoreCoordinator) {
        return _persistentStoreCoordinator;
    }
    
    NSManagedObjectModel *mom = [self managedObjectModel];
    if (!mom) {
        NSLog(@"%@:%@ No model to generate a store from", [self class], NSStringFromSelector(_cmd));
        return nil;
    }
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSURL *applicationFilesDirectory = [self applicationFilesDirectory];
    NSError *error = nil;
    
    NSDictionary *properties = [applicationFilesDirectory resourceValuesForKeys:@[NSURLIsDirectoryKey] error:&error];
    
    if (!properties) {
        BOOL ok = NO;
        if ([error code] == NSFileReadNoSuchFileError) {
            ok = [fileManager createDirectoryAtPath:[applicationFilesDirectory path] withIntermediateDirectories:YES attributes:nil error:&error];
        }
        if (!ok) {
            [[NSApplication sharedApplication] presentError:error];
            return nil;
        }
    } else {
        if (![properties[NSURLIsDirectoryKey] boolValue]) {
            // Customize and localize this error.
            NSString *failureDescription = [NSString stringWithFormat:@"Expected a folder to store application data, found a file (%@).", [applicationFilesDirectory path]];
            
            NSMutableDictionary *dict = [NSMutableDictionary dictionary];
            [dict setValue:failureDescription forKey:NSLocalizedDescriptionKey];
            error = [NSError errorWithDomain:@"YOUR_ERROR_DOMAIN" code:101 userInfo:dict];
            
            [[NSApplication sharedApplication] presentError:error];
            return nil;
        }
    }
    
    NSURL *url = [applicationFilesDirectory URLByAppendingPathComponent:@"Core_Data_Contacts.storedata"];
    NSPersistentStoreCoordinator *coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:mom];
    
    // enable iCloud storage support
    // passing nil here uses the first iCloud container identifier from
    // our Info.plist
    NSURL * iURL = [[NSFileManager defaultManager] URLForUbiquityContainerIdentifier: nil];
    NSDictionary * options = @{
        NSPersistentStoreUbiquitousContentNameKey : @"CoreDataContacts",
        NSPersistentStoreUbiquitousContentURLKey : iURL
    };
    
    if (![coordinator addPersistentStoreWithType: NSSQLiteStoreType
                                   configuration: nil
                                             URL: url
                                         options: options
                                           error: &error]) {
        [[NSApplication sharedApplication] presentError:error];
        return nil;
    }
    _persistentStoreCoordinator = coordinator;
    
    return _persistentStoreCoordinator;
}

// Returns the managed object context for the application (which is already bound to the persistent store coordinator for the application.) 
- (NSManagedObjectContext *)managedObjectContext
{
    if (_managedObjectContext) {
        return _managedObjectContext;
    }
    
    NSPersistentStoreCoordinator *coordinator = [self persistentStoreCoordinator];
    if (!coordinator) {
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        [dict setValue:@"Failed to initialize the store" forKey:NSLocalizedDescriptionKey];
        [dict setValue:@"There was an error building up the data file." forKey:NSLocalizedFailureReasonErrorKey];
        NSError *error = [NSError errorWithDomain:@"YOUR_ERROR_DOMAIN" code:9999 userInfo:dict];
        [[NSApplication sharedApplication] presentError:error];
        return nil;
    }
    _managedObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType: NSMainQueueConcurrencyType];
    [_managedObjectContext setPersistentStoreCoordinator:coordinator];

    return _managedObjectContext;
}

// Returns the NSUndoManager for the application. In this case, the manager returned is that of the managed object context for the application.
- (NSUndoManager *)windowWillReturnUndoManager:(NSWindow *)window
{
    return [[self managedObjectContext] undoManager];
}

// Performs the save action for the application, which is to send the save: message to the application's managed object context. Any encountered errors are presented to the user.
- (IBAction)saveAction:(id)sender
{
    [[self managedObjectContext] performBlock:^{
        NSError *error = nil;
        
        if (![[self managedObjectContext] commitEditing]) {
            NSLog(@"%@:%@ unable to commit editing before saving", [self class], NSStringFromSelector(_cmd));
        }
        
        if (![[self managedObjectContext] save:&error]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSApplication sharedApplication] presentError:error];
            });
        }
    }];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
    return ( YES );
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender
{
    // Save changes in the application's managed object context before the application terminates.
    
    if (!_managedObjectContext) {
        return NSTerminateNow;
    }
    
    __block NSApplicationTerminateReply reply = NSTerminateLater;
    [[self managedObjectContext] performBlockAndWait: ^{
        if (![[self managedObjectContext] commitEditing]) {
            NSLog(@"%@:%@ unable to commit editing to terminate", [self class], NSStringFromSelector(_cmd));
            reply = NSTerminateCancel;
        }
    }];
    
    if ( reply != NSTerminateLater )
        return reply;
    
    [[self managedObjectContext] performBlockAndWait: ^{
        if (![[self managedObjectContext] hasChanges]) {
            reply = NSTerminateNow;
        }
    }];
    
    if ( reply != NSTerminateLater )
        return reply;
    
    [[self managedObjectContext] performBlock: ^{
        NSError *error = nil;
        if (![[self managedObjectContext] save:&error]) {
            // failed to save the context-- jump back to the main thread
            // to perform UI work to make the decision. This can be either sync
            // or async, but async is generally a better idea.
            dispatch_async(dispatch_get_main_queue(), ^{
                // Customize this code block to include application-specific recovery steps.
                BOOL result = [sender presentError:error];
                if (result) {
                    // cancel termination, as before
                    [sender replyToApplicationShouldTerminate: NO];
                    return;
                }
                
                // Present a confirmation dialog to the user, and let them
                // make the decision for us.
                NSString *question = NSLocalizedString(@"Could not save changes while quitting. Quit anyway?", @"Quit without saves error question message");
                NSString *info = NSLocalizedString(@"Quitting now will lose any changes you have made since the last successful save", @"Quit without saves error question info");
                NSString *quitButton = NSLocalizedString(@"Quit anyway", @"Quit anyway button title");
                NSString *cancelButton = NSLocalizedString(@"Cancel", @"Cancel button title");
                NSAlert *alert = [[NSAlert alloc] init];
                [alert setMessageText:question];
                [alert setInformativeText:info];
                [alert addButtonWithTitle:quitButton];
                [alert addButtonWithTitle:cancelButton];
                
                NSInteger answer = [alert runModal];
                
                // if the answer is NSAlertDefaultReturn then they clicked
                // the Quit button.
                [sender replyToApplicationShouldTerminate: (answer == NSAlertDefaultReturn)];
            });
        } else {
            // the context saved successfully, so we can terminate
            [sender replyToApplicationShouldTerminate: YES];
        }
    }];

    // we've dispatched an async save operation-- we'll decide if we can terminate
    // once we know how that turns out.
    return NSTerminateLater;
}

#pragma mark - NSTableView Delegation

- (NSView *) tableView: (NSTableView *) tableView viewForTableColumn: (NSTableColumn *) tableColumn row: (NSInteger) row
{
    // this is the only way I can find to be able to look at the bound values here...
    NSDictionary * bindingInfo = [tableView infoForBinding: @"content"];
    id valueObject = bindingInfo[NSObservedObjectKey][row];
    if ( valueObject == nil )
        return ( nil );
    
    if ( [valueObject isKindOfClass: [MailingAddress class]] )
    {
        return ( [tableView makeViewWithIdentifier: @"Address" owner: self] );
    }
    else if ( [valueObject isKindOfClass: [EmailAddress class]] )
    {
        return ( [tableView makeViewWithIdentifier: @"Email" owner: self] );
    }
    else if ( [valueObject isKindOfClass: [PhoneNumber class]] )
    {
        return ( [tableView makeViewWithIdentifier: @"Phone" owner: self] );
    }
    
    return ( nil );
}

#pragma mark - Networked Stores

- (void) _initializeNetworker
{
    NSXPCInterface * interface = [NSXPCInterface interfaceWithProtocol: @protocol(APRemoteAddressBookBrowser)];
    
    // add proxy details for the return value of -connectToServiceWithName:
    NSXPCInterface * bookInterface = [NSXPCInterface interfaceWithProtocol: @protocol(APRemoteAddressBook)];
    // first argument of the reply block is to be sent as a proxy
    [interface setInterface: bookInterface
                forSelector: @selector(connectToServiceWithName:replyHandler:)
              argumentIndex: 0
                    ofReply: YES];
    
    // proxy details for the commandHandler object sent to -setCommandHandler:
    NSXPCInterface * commandHandlerInterface = [NSXPCInterface interfaceWithProtocol: @protocol(APRemoteCommandHandler)];
    // first argument to the function is a proxy object
    [interface setInterface: commandHandlerInterface
                forSelector: @selector(setCommandHandler:errorHandler:)
              argumentIndex: 0
                    ofReply: NO];
    
    _xpcConnection = [[NSXPCConnection alloc] initWithServiceName: @"com.apress.beginning-objective-c.Networker"];
    [_xpcConnection setRemoteObjectInterface: interface];
    [_xpcConnection resume];
    _browser = [_xpcConnection remoteObjectProxyWithErrorHandler: ^(NSError * error) {
        [NSApp presentError: error];
    }];
}

- (IBAction)vendAddressBook:(id)sender
{
    if ( _browser == nil )
        [self _initializeNetworker];
    
    // this will vend us on the network
    [_browser setCommandHandler: self errorHandler: ^(NSError *error) {
        if ( error != nil )
        {
            dispatch_async(dispatch_get_main_queue(), ^{
                [NSApp presentError: error];
            });
        }
    }];
}

- (IBAction)browseRemoteStores:(id)sender
{
    if ( _browser == nil )
        [self _initializeNetworker];
    
    [_browser availableServiceNames: ^(id result, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if ( error != nil )
            {
                [NSApp presentError: error];
            }
            else
            {
                _browserWindow = [[APRemoteBrowserWindowController alloc] initWithServiceNames: result
                                                                                      delegate: self];
                [_browserWindow showWindow: self];
            }
        });
    }];
}

- (void) remoteBrowser: (APRemoteBrowserWindowController *) browser
 connectToServiceNamed: (NSString *) serviceName
{
    [self attachToRemoteAddressBookWithName: serviceName handler: ^(id<APRemoteAddressBook> book, NSError *error) {
        // we're modifying the UI, so do everything on the main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            if ( error != nil )
            {
                [NSApp presentError: error];
                return;
            }
            
            APRemoteAddressBookWindowController * remote = nil;
            remote = [[APRemoteAddressBookWindowController alloc] initWithRemoteAddressBook: book
                                                                                       name: serviceName];
            
            // close the browser window once we connect
            if ( remote != nil )
            {
                [browser close];
                if ( _browserWindow == browser )
                    _browserWindow = nil;
            }
            
            // show the remote window
            [remote showWindow: self];
            
            __weak APAppDelegate * weakSelf = self;
            id observer = [[NSNotificationCenter defaultCenter] addObserverForName: NSWindowWillCloseNotification object: [remote window] queue: [NSOperationQueue mainQueue] usingBlock: ^(NSNotification *note) {
                APAppDelegate * strongSelf = weakSelf;
                if ( strongSelf == nil )
                    return;
                
                [strongSelf->_remoteBookObservers removeObjectForKey: serviceName];
                [_remoteBookWindows removeObject: remote];
            }];
            
            // keep these alive
            [_remoteBookWindows addObject: remote];
            _remoteBookObservers[serviceName] = observer;
        });
    }];
}

- (void)attachToRemoteAddressBookWithName:(NSString *)name
                                  handler:(void (^)(id<APRemoteAddressBook>, NSError *)) handler;
{
    if ( _browser == nil )
        [self _initializeNetworker];
    
    [_browser connectToServiceWithName: name replyHandler: handler];
}

- (NSDictionary *) buildReplyForCommand: (NSDictionary *) command
                                 values: (id<NSSecureCoding>) values
                                  error: (NSError *) error
{
    NSMutableDictionary * result = [NSMutableDictionary new];
    NSUUID * uuid = command[APRemoteAddressBookCommandUUIDKey];
    result[APRemoteAddressBookCommandNameKey] = APRemoteAddressBookCommandReply;
    result[APRemoteAddressBookCommandUUIDKey] = uuid;
    if ( values != nil )
        result[APRemoteAddressBookCommandValueKey] = values;
    if ( error != nil )
        result[APRemoteAddressBookCommandErrorKey] = error;
    return ( result );
}

- (void) handleCommand: (NSDictionary *) command
       returningResult: (void (^)(NSDictionary *)) handler
{
    NSString * name = command[APRemoteAddressBookCommandNameKey];
    NSError * error = nil;
    id result = nil;
    
    if ( [name isEqualToString: APRemoteAddressBookCommandAllPeople] )
    {
        result = [self allPeople: &error];
    }
    else if ( [name isEqualToString: APRemoteAddressBookCommandGetMailingAddresses] )
    {
        NSString * identifier = command[APRemoteAddressBookCommandPersonIDKey];
        result = [self allAddressesForPersonWithIdentifier: identifier
                                                        error: &error];
    }
    else if ( [name isEqualToString: APRemoteAddressBookCommandGetEmailAddresses] )
    {
        NSString * identifier = command[APRemoteAddressBookCommandPersonIDKey];
        result = [self allEmailsForPersonWithIdentifier: identifier
                                                  error: &error];
    }
    else if ( [name isEqualToString: APRemoteAddressBookCommandGetPhoneNumbers] )
    {
        NSString * identifier = command[APRemoteAddressBookCommandPersonIDKey];
        result = [self allPhoneNumbersForPersonWithIdentifier: identifier
                                                        error: &error];
    }
    else
    {
        id userInfo = @{ NSLocalizedDescriptionKey : @"Unknown command" };
        error = [NSError errorWithDomain: @"APRemoteAddressBookErrorDomain"
                                    code: 101
                                userInfo: userInfo];
    }
    
    handler([self buildReplyForCommand: command values: result error: error]);
}

- (NSArray *) allPeople: (NSError **) error
{
    NSMutableArray * result = [NSMutableArray new];
    NSFetchRequest * req = [NSFetchRequest fetchRequestWithEntityName: @"Person"];
    
    // no ordering, etc-- just fetch every Person instance
    [[self managedObjectContext] performBlockAndWait: ^{
        NSArray * people = [[self managedObjectContext] executeFetchRequest: req
                                                                      error: error];
        if ( people == nil )
            return;     // error is already set
        
        for ( Person * person in people )
        {
            NSMutableDictionary * personInfo = [NSMutableDictionary new];
            personInfo[APRemoteAddressBookCommandPersonIDKey] = [[[person objectID] URIRepresentation] absoluteString];
            if ( person.firstName != nil )
                personInfo[@"firstName"] = person.firstName;
            if ( person.lastName != nil )
                personInfo[@"lastName"] = person.lastName;
            [result addObject: personInfo];
        }
    }];
    
    return ( result );
}

- (NSManagedObjectID *) objectIDFromIdentifier: (NSString *) identifier
                                         error: (NSError **) error
{
    NSURL * objectURI = [[NSURL alloc] initWithString: identifier];
    if ( objectURI == nil )
    {
        if ( error != nil )
        {
            *error = [NSError errorWithDomain: NSCocoaErrorDomain
                                         code: NSCoreDataError
                                     userInfo: nil];
        }
        
        return ( nil );
    }
    
    NSManagedObjectID * objectID = [[self persistentStoreCoordinator] managedObjectIDForURIRepresentation: objectURI];
    if ( objectID == nil )
    {
        if ( error != nil )
        {
            *error = [NSError errorWithDomain: NSCocoaErrorDomain
                                         code: NSManagedObjectReferentialIntegrityError
                                     userInfo: nil];
        }
        
        return ( nil );
    }
    
    return ( objectID );
}

- (NSArray *) allAddressesForPersonWithIdentifier: (NSString *) identifier
                                            error: (NSError **) error
{
    NSManagedObjectID * objectID = [self objectIDFromIdentifier: identifier
                                                          error: error];
    if ( objectID == nil )
        return ( nil );
    
    NSMutableArray * result = [NSMutableArray new];
    [[self managedObjectContext] performBlockAndWait: ^{
        Person * person = (Person *)[[self managedObjectContext] existingObjectWithID: objectID
                                                                                error: error];
        if ( person == nil )
            return;
        
        for ( MailingAddress * address in person.mailingAddresses )
        {
            NSMutableDictionary * info = [NSMutableDictionary new];
            info[@"label"] = address.label;
            info[@"street"] = address.street;
            info[@"city"] = address.city;
            info[@"region"] = address.region;
            info[@"country"] = address.country;
            info[@"postalCode"] = address.postalCode;
            [result addObject: info];
        }
    }];
    
    return ( result );
}

- (NSArray *) allEmailsForPersonWithIdentifier: (NSString *) identifier
                                         error: (NSError **) error
{
    NSManagedObjectID * objectID = [self objectIDFromIdentifier: identifier
                                                          error: error];
    if ( objectID == nil )
        return ( nil );
    
    NSMutableArray * result = [NSMutableArray new];
    [[self managedObjectContext] performBlockAndWait: ^{
        Person * person = (Person *)[[self managedObjectContext] existingObjectWithID: objectID
                                                                                error: error];
        if ( person == nil )
            return;
        
        for ( EmailAddress * email in person.emailAddresses )
        {
            [result addObject: @{
                @"label" : email.label,
                @"email" : email.email
             }];
        }
    }];
    
    return ( result );
}

- (NSArray *) allPhoneNumbersForPersonWithIdentifier: (NSString *) identifier
                                               error: (NSError **) error
{
    NSManagedObjectID * objectID = [self objectIDFromIdentifier: identifier
                                                          error: error];
    if ( objectID == nil )
        return ( nil );
    
    NSMutableArray * result = [NSMutableArray new];
    [[self managedObjectContext] performBlockAndWait: ^{
        Person * person = (Person *)[[self managedObjectContext] existingObjectWithID: objectID
                                                                                error: error];
        if ( person == nil )
            return;
        
        for ( PhoneNumber * phone in person.phoneNumbers )
        {
            [result addObject: @{
                @"label" : phone.label,
                @"phoneNumber" : phone.phoneNumber
             }];
        }
    }];
    
    return ( result );
}

@end
