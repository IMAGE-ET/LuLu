//
//  file: Utilities.m
//  project: lulu (shared)
//  description: various helper/utility functions
//
//  created by Patrick Wardle
//  copyright (c) 2017 Objective-See. All rights reserved.
//

#import "consts.h"
#import "logging.h"
#import "utilities.h"

#import <signal.h>
#import <unistd.h>
#import <libproc.h>
#import <sys/stat.h>
#import <arpa/inet.h>
#import <sys/socket.h>
#import <sys/sysctl.h>
#import <Security/Security.h>
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <SystemConfiguration/SystemConfiguration.h>

//get app's version
// ->extracted from Info.plist
NSString* getAppVersion()
{
    //read and return 'CFBundleVersion' from bundle
    return [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleVersion"];
}

//get path to (main) app
// login item is in app bundle, so parse up to get main app
NSString* getMainAppPath()
{
    //path components
    NSArray *pathComponents = nil;
    
    //path to config (main) app
    NSString* mainApp = nil;
    
    //get path components
    // then build full path to main app
    pathComponents = [[[NSBundle mainBundle] bundlePath] pathComponents];
    if(pathComponents.count > 4)
    {
        //init path to full (main) app
        mainApp = [NSString pathWithComponents:[pathComponents subarrayWithRange:NSMakeRange(0, pathComponents.count - 4)]];
    }
    
    //when (still) nil
    // use default path
    if(nil == mainApp)
    {
        //default
        mainApp = [@"/Applications" stringByAppendingPathComponent:APP_NAME];
    }
    
    return mainApp;
}

//give path to app
// ->get full path to its binary
NSString* getAppBinary(NSString* appPath)
{
    //binary path
    NSString* binaryPath = nil;
    
    //app bundle
    NSBundle* appBundle = nil;
    
    //load app bundle
    appBundle = [NSBundle bundleWithPath:appPath];
    if(nil == appBundle)
    {
        //err msg
        logMsg(LOG_ERR, [NSString stringWithFormat:@"failed to load app bundle for %@", appPath]);
        
        //bail
        goto bail;
    }
    
    //extract executable
    binaryPath = appBundle.executablePath;
    
bail:
    
    return binaryPath;
}

//verify that an app bundle is
// a) signed
// b) signed with signing auth
OSStatus verifyApp(NSString* path, NSString* signingAuth)
{
    //status
    OSStatus status = !noErr;
    
    //signing req string
    NSString *requirementString = nil;
    
    //code
    SecStaticCodeRef staticCode = NULL;
    
    //signing reqs
    SecRequirementRef requirementRef = NULL;
    
    //init requirement string
    requirementString = [NSString stringWithFormat:@"anchor trusted and certificate leaf [subject.CN] = \"%@\"", signingAuth];
    
    //create static code
    status = SecStaticCodeCreateWithPath((__bridge CFURLRef)([NSURL fileURLWithPath:path]), kSecCSDefaultFlags, &staticCode);
    if(noErr != status)
    {
        //err msg
        logMsg(LOG_ERR, [NSString stringWithFormat:@"SecStaticCodeCreateWithPath failed w/ %d", status]);
        
        //bail
        goto bail;
    }
    
    //create req string
    status = SecRequirementCreateWithString((__bridge CFStringRef _Nonnull)(requirementString), kSecCSDefaultFlags, &requirementRef);
    if( (noErr != status) ||
       (requirementRef == NULL) )
    {
        //err msg
        logMsg(LOG_ERR, [NSString stringWithFormat:@"SecRequirementCreateWithString failed w/ %d", status]);
        
        //bail
        goto bail;
    }
    
    //check if file is signed w/ apple dev id by checking if it conforms to req string
    status = SecStaticCodeCheckValidity(staticCode, kSecCSDefaultFlags, requirementRef);
    if(noErr != status)
    {
        logMsg(LOG_ERR, [NSString stringWithFormat:@"SecStaticCodeCheckValidity failed w/ %d", status]);
        
        //bail
        goto bail;
    }
    
    //happy
    status = noErr;
    
bail:
    
    //free req reference
    if(NULL != requirementRef)
    {
        //free
        CFRelease(requirementRef);
        requirementRef = NULL;
        
    }
    
    //free static code
    if(NULL != staticCode)
    {
        //free
        CFRelease(staticCode);
        staticCode = NULL;
    }
    
    return status;
}


//get process name
// ->either via app bundle, or path
NSString* getProcessName(NSString* path)
{
    //process name
    NSString* processName = nil;
    
    //app bundle
    NSBundle* appBundle = nil;
    
    //try find an app bundle
    appBundle = findAppBundle(path);
    if(nil != appBundle)
    {
        //grab name from app's bundle
        processName = [appBundle infoDictionary][@"CFBundleName"];
    }
    
    //still nil?
    // ->just grab from path
    if(nil == processName)
    {
        //from path
        processName = [path lastPathComponent];
    }
    
    return processName;
}

//given a path to binary
// parse it back up to find app's bundle
NSBundle* findAppBundle(NSString* binaryPath)
{
    //app's bundle
    NSBundle* appBundle = nil;
    
    //app's path
    NSString* appPath = nil;
    
    //first just try full path
    appPath = binaryPath;
    
    //try to find the app's bundle/info dictionary
    do
    {
        //try to load app's bundle
        appBundle = [NSBundle bundleWithPath:appPath];
        
        //check for match
        // ->binary path's match
        if( (nil != appBundle) &&
            (YES == [appBundle.executablePath isEqualToString:binaryPath]))
        {
            //all done
            break;
        }
        
        //always unset bundle var since it's being returned
        // ->and at this point, its not a match
        appBundle = nil;
        
        //remove last part
        // ->will try this next
        appPath = [appPath stringByDeletingLastPathComponent];
        
    //scan until we get to root
    // ->of course, loop will exit if app info dictionary is found/loaded
    } while( (nil != appPath) &&
             (YES != [appPath isEqualToString:@"/"]) &&
             (YES != [appPath isEqualToString:@""]) );
    
    return appBundle;
}

//set dir's|file's group/owner
BOOL setFileOwner(NSString* path, NSNumber* groupID, NSNumber* ownerID, BOOL recursive)
{
    //ret var
    BOOL bSetOwner = NO;
    
    //owner dictionary
    NSDictionary* fileOwner = nil;
    
    //sub paths
    NSArray* subPaths = nil;
    
    //full path
    // ->for recursive
    NSString* fullPath = nil;
    
    //init permissions dictionary
    fileOwner = @{NSFileGroupOwnerAccountID:groupID, NSFileOwnerAccountID:ownerID};
    
    //set group/owner
    if(YES != [[NSFileManager defaultManager] setAttributes:fileOwner ofItemAtPath:path error:NULL])
    {
        //err msg
        logMsg(LOG_ERR, [NSString stringWithFormat:@"failed to set ownership for %@ (%@)", path, fileOwner]);
        
        //bail
        goto bail;
    }
    
    //dbg msg
    logMsg(LOG_DEBUG, [NSString stringWithFormat:@"set ownership for %@ (%@)", path, fileOwner]);
    
    //do it recursively
    if(YES == recursive)
    {
        //sanity check
        // ->make sure root starts with '/'
        if(YES != [path hasSuffix:@"/"])
        {
            //add '/'
            path = [NSString stringWithFormat:@"%@/", path];
        }
        
        //get all subpaths
        subPaths = [[NSFileManager defaultManager] subpathsAtPath:path];
        for(NSString *subPath in subPaths)
        {
            //init full path
            fullPath = [path stringByAppendingString:subPath];
            
            //set group/owner
            if(YES != [[NSFileManager defaultManager] setAttributes:fileOwner ofItemAtPath:fullPath error:NULL])
            {
                //err msg
                logMsg(LOG_ERR, [NSString stringWithFormat:@"failed to set ownership for %@ (%@)", fullPath, fileOwner]);
                
                //bail
                goto bail;
            }
        }
    }
    
    //no errors
    bSetOwner = YES;
    
//bail
bail:
    
    return bSetOwner;
}

//set permissions for file
BOOL setFilePermissions(NSString* file, int permissions, BOOL recursive)
{
    //ret var
    BOOL bSetPermissions = NO;
    
    //file permissions
    NSDictionary* filePermissions = nil;
    
    //root directory
    NSURL* root = nil;
    
    //directory enumerator
    NSDirectoryEnumerator* enumerator = nil;
    
    //error
    NSError* error = nil;
    
    //init dictionary
    filePermissions = @{NSFilePosixPermissions: [NSNumber numberWithInt:permissions]};
    
    //apply file permissions recursively
    if(YES == recursive)
    {
        //init root
        root = [NSURL fileURLWithPath:file];
        
        //init enumerator
        enumerator = [[NSFileManager defaultManager] enumeratorAtURL:root includingPropertiesForKeys:[NSArray arrayWithObject:NSURLIsDirectoryKey] options:0 errorHandler:nil];
    
        //set file permissions on each
        for(NSURL* currentFile in enumerator)
        {
            //set permissions
            if(YES != [[NSFileManager defaultManager] setAttributes:filePermissions ofItemAtPath:currentFile.path error:&error])
            {
                //err msg
                logMsg(LOG_ERR, [NSString stringWithFormat:@"failed to set permissions for %@ (%@), %@", currentFile.path, filePermissions, error]);
                
                //bail
                goto bail;
            }
        }
    }
    
    //always set permissions on passed in file (or top-level directory)
    // ->note: recursive enumerator skips root directory, so execute this always
    if(YES != [[NSFileManager defaultManager] setAttributes:filePermissions ofItemAtPath:file error:NULL])
    {
        //err msg
        logMsg(LOG_ERR, [NSString stringWithFormat:@"failed to set permissions for %@ (%@)", file, filePermissions]);
        
        //bail
        goto bail;
    }
    
    //happy
    bSetPermissions = YES;
    
bail:
    
    return bSetPermissions;
}

//get process's path
NSString* getProcessPath(pid_t pid)
{
    //task path
    NSString* processPath = nil;
    
    //buffer for process path
    char pathBuffer[PROC_PIDPATHINFO_MAXSIZE] = {0};
    
    //status
    int status = -1;
    
    //'management info base' array
    int mib[3] = {0};
    
    //system's size for max args
    unsigned long systemMaxArgs = 0;
    
    //process's args
    char* taskArgs = NULL;
    
    //# of args
    int numberOfArgs = 0;
    
    //size of buffers, etc
    size_t size = 0;
    
    //reset buffer
    bzero(pathBuffer, PROC_PIDPATHINFO_MAXSIZE);
    
    //first attempt to get path via 'proc_pidpath()'
    status = proc_pidpath(pid, pathBuffer, sizeof(pathBuffer));
    if(0 != status)
    {
        //init task's name
        processPath = [NSString stringWithUTF8String:pathBuffer];
    }
    //otherwise
    // try via task's args ('KERN_PROCARGS2')
    else
    {
        //init mib
        // ->want system's size for max args
        mib[0] = CTL_KERN;
        mib[1] = KERN_ARGMAX;
        
        //set size
        size = sizeof(systemMaxArgs);
        
        //get system's size for max args
        if(-1 == sysctl(mib, 2, &systemMaxArgs, &size, NULL, 0))
        {
            //bail
            goto bail;
        }
        
        //alloc space for args
        taskArgs = malloc(systemMaxArgs);
        if(NULL == taskArgs)
        {
            //bail
            goto bail;
        }
        
        //init mib
        // ->want process args
        mib[0] = CTL_KERN;
        mib[1] = KERN_PROCARGS2;
        mib[2] = pid;
        
        //set size
        size = (size_t)systemMaxArgs;
        
        //get process's args
        if(-1 == sysctl(mib, 3, taskArgs, &size, NULL, 0))
        {
            //bail
            goto bail;
        }
        
        //sanity check
        // ensure buffer is somewhat sane
        if(size <= sizeof(int))
        {
            //bail
            goto bail;
        }
        
        //extract number of args
        memcpy(&numberOfArgs, taskArgs, sizeof(numberOfArgs));
        
        //extract task's name
        // follows # of args (int) and is NULL-terminated
        processPath = [NSString stringWithUTF8String:taskArgs + sizeof(int)];
    }
    
bail:
    
    //free process args
    if(NULL != taskArgs)
    {
        //free
        free(taskArgs);
        
        //reset
        taskArgs = NULL;
    }
    
    return processPath;
}

//given a process path and user
// ->return array of all matching pids
NSMutableArray* getProcessIDs(NSString* processPath, int userID)
{
    //status
    int status = -1;
    
    //process IDs
    NSMutableArray* processIDs = nil;
    
    //# of procs
    int numberOfProcesses = 0;
        
    //array of pids
    pid_t* pids = NULL;
    
    //process info struct
    struct kinfo_proc procInfo = {0};
    
    //size of struct
    size_t procInfoSize = sizeof(procInfo);
    
    //mib
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, -1};
    
    //get # of procs
    numberOfProcesses = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if(-1 == numberOfProcesses)
    {
        //bail
        goto bail;
    }
    
    //alloc buffer for pids
    pids = calloc((unsigned long)numberOfProcesses, sizeof(pid_t));
    
    //alloc
    processIDs = [NSMutableArray array];
    
    //get list of pids
    status = proc_listpids(PROC_ALL_PIDS, 0, pids, numberOfProcesses * (int)sizeof(pid_t));
    if(status < 0)
    {
        //bail
        goto bail;
    }
        
    //iterate over all pids
    // ->get name for each process
    for(int i = 0; i < (int)numberOfProcesses; i++)
    {
        //skip blank pids
        if(0 == pids[i])
        {
            //skip
            continue;
        }
        
        //skip if path doesn't match
        if(YES != [processPath isEqualToString:getProcessPath(pids[i])])
        {
            //next
            continue;
        }
        
        //need to also match on user?
        // caller can pass in -1 to skip this check
        if(-1 != userID)
        {
            //init mib
            mib[0x3] = pids[i];
            
            //make syscall to get proc info for user
            if( (0 != sysctl(mib, 0x4, &procInfo, &procInfoSize, NULL, 0)) ||
                (0 == procInfoSize) )
            {
                //skip
                continue;
            }

            //skip if user id doesn't match
            if(userID != (int)procInfo.kp_eproc.e_ucred.cr_uid)
            {
                //skip
                continue;
            }
        }
        
        //got match
        // add to list
        [processIDs addObject:[NSNumber numberWithInt:pids[i]]];
    }
    
bail:
        
    //free buffer
    if(NULL != pids)
    {
        //free
        free(pids);
        
        //reset
        pids = NULL;
    }

    return processIDs;
}

//get an icon for a process
// ->for apps, this will be app's icon, otherwise just a standard system one
NSImage* getIconForProcess(NSString* path)
{
    //icon's file name
    NSString* iconFile = nil;
    
    //icon's path
    NSString* iconPath = nil;
    
    //icon's path extension
    NSString* iconExtension = nil;
    
    //icon
    NSImage* icon = nil;
    
    //system's document icon
    static NSData* documentIcon = nil;
    
    //bundle
    NSBundle* appBundle = nil;
    
    //first try grab bundle
    // ->then extact icon from this
    appBundle = findAppBundle(path);
    if(nil != appBundle)
    {
        //get file
        iconFile = appBundle.infoDictionary[@"CFBundleIconFile"];
        
        //get path extension
        iconExtension = [iconFile pathExtension];
        
        //if its blank (i.e. not specified)
        // ->go with 'icns'
        if(YES == [iconExtension isEqualTo:@""])
        {
            //set type
            iconExtension = @"icns";
        }
        
        //set full path
        iconPath = [appBundle pathForResource:[iconFile stringByDeletingPathExtension] ofType:iconExtension];
        
        //load it
        icon = [[NSImage alloc] initWithContentsOfFile:iconPath];
    }
    
    //process is not an app or couldn't get icon
    // ->try to get it via shared workspace
    if( (nil == appBundle) ||
        (nil == icon) )
    {
        //extract icon
        icon = [[NSWorkspace sharedWorkspace] iconForFile:path];
        
        //load system document icon
        // ->static var, so only load once
        if(nil == documentIcon)
        {
            //load
            documentIcon = [[[NSWorkspace sharedWorkspace] iconForFileType:
                             NSFileTypeForHFSTypeCode(kGenericDocumentIcon)] TIFFRepresentation];
        }
        
        //if 'iconForFile' method doesn't find and icon, it returns the system 'document' icon
        // ->the system 'application' icon seems more applicable, so use that here...
        if(YES == [[icon TIFFRepresentation] isEqual:documentIcon])
        {
            //set icon to system 'applicaiton' icon
            icon = [[NSWorkspace sharedWorkspace]
                    iconForFileType: NSFileTypeForHFSTypeCode(kGenericApplicationIcon)];
        }
        
        //'iconForFileType' returns small icons
        // ->so set size to 64
        [icon setSize:NSMakeSize(128, 128)];
    }
    
    return icon;
}


//check if a kext is loaded
BOOL kextIsLoaded(NSString* kext)
{
    //flag
    BOOL isLoaded = NO;
    
    //service object
    io_service_t serviceObject = 0;
    
    //get matching service
    serviceObject = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching(kext.UTF8String));
    
    //set flag
    isLoaded = !!serviceObject;
    
    //release matching service
    if(0 != serviceObject)
    {
        //release
        IOObjectRelease(serviceObject);
    }
    
    return isLoaded;
}

//wait until kext is loaded
void wait4kext(NSString* kext)
{
    //forever
    // wait for kext to load
    while(YES)
    {
        //check
       if(YES == kextIsLoaded(kext))
       {
           //ok loaded
           break;
       }
        
        //nap
        [NSThread sleepForTimeInterval:0.5];
    }
    
    return;
}

//wait until a window is non nil
// then make it modal
void makeModal(NSWindowController* windowController)
{
    //wait up to 1 second window to be non-nil
    // ->then make modal
    for(int i=0; i<20; i++)
    {
        //can make it modal once we have a window
        if(nil != windowController.window)
        {
            //make modal on main thread
            dispatch_sync(dispatch_get_main_queue(), ^{
                
                //modal
                [[NSApplication sharedApplication] runModalForWindow:windowController.window];
                
            });
            
            //all done
            break;
        }
        
        //nap
        [NSThread sleepForTimeInterval:0.05f];
        
    }//until 1 second
    
    return;
}

//find a process by name
pid_t findProcess(NSString* processName)
{
    //pid
    pid_t processID = 0;
    
    //status
    int status = -1;
    
    //# of procs
    int numberOfProcesses = 0;
    
    //array of pids
    pid_t* pids = NULL;
    
    //process path
    NSString* processPath = nil;
    
    //get # of procs
    numberOfProcesses = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if(-1 == numberOfProcesses)
    {
        //bail
        goto bail;
    }
    
    //alloc buffer for pids
    pids = calloc((unsigned long)numberOfProcesses, sizeof(pid_t));
    
    //get list of pids
    status = proc_listpids(PROC_ALL_PIDS, 0, pids, numberOfProcesses * (int)sizeof(pid_t));
    if(status < 0)
    {
        //bail
        goto bail;
    }
    
    //iterate over all pids
    // ->get name for each via helper function
    for(int i = 0; i < numberOfProcesses; ++i)
    {
        //skip blank pids
        if(0 == pids[i])
        {
            //skip
            continue;
        }
        
        //get name
        processPath = getProcessPath(pids[i]);
        if( (nil == processPath) ||
           (0 == processPath.length) )
        {
            //skip
            continue;
        }
        
        //match?
        if(YES == [processPath isEqualToString:processName])
        {
            //save
            processID = pids[i];
            
            //pau
            break;
        }
        
    }//all procs
    
bail:
    
    //free buffer
    if(NULL != pids)
    {
        //free
        free(pids);
    }
    
    return processID;
}

//generate list of all installed applications
NSArray* enumerateInstalledApplications()
{
    //installed apps
    NSArray* installedApplications = nil;
    
    //results from system profiler
    NSDictionary* taskResults = nil;
    
    //serialized task output
    NSArray* serializedOutput = nil;
    
    //alloc array for installed apps
    installedApplications = [NSMutableArray array];
    
    //exec system profiler
    taskResults = execTask(SYSTEM_PROFILER, @[@"SPApplicationsDataType", @"-xml"], YES);
    if( (nil == taskResults) ||
        (0 != [taskResults[EXIT_CODE] intValue]) )
    {
        //bail
        goto bail;
    }
    
    //serialize output to array
    serializedOutput = [NSPropertyListSerialization propertyListWithData:taskResults[STDOUT] options:kNilOptions format:NULL error:NULL];
    if( (nil == serializedOutput) ||
        (YES != [serializedOutput[0] isKindOfClass:[NSDictionary class]]))
    {
        //bail
        goto bail;
    }
    
    //extract installed apps
    installedApplications = serializedOutput[0][@"_items"];
    
bail:
    
    return installedApplications;
}

//for login item enable/disable
// we use the launch services APIs, since replacements don't always work :(
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

//toggle login item
// either add (install) or remove (uninstall)
BOOL toggleLoginItem(NSURL* loginItem, int toggleFlag)
{
    //flag
    BOOL wasToggled = NO;
    
    //login item ref
    LSSharedFileListRef loginItemsRef = NULL;
    
    //login items
    CFArrayRef loginItems = NULL;
    
    //current login item
    CFURLRef currentLoginItem = NULL;
    
    //get reference to login items
    loginItemsRef = LSSharedFileListCreate(NULL, kLSSharedFileListSessionLoginItems, NULL);
    
    //add (install)
    if(ACTION_INSTALL_FLAG == toggleFlag)
    {
        //dbg msg
        logMsg(LOG_DEBUG, [NSString stringWithFormat:@"adding login item %@", loginItem]);
        
        //add
        LSSharedFileListItemRef itemRef = LSSharedFileListInsertItemURL(loginItemsRef, kLSSharedFileListItemLast, NULL, NULL, (__bridge CFURLRef)(loginItem), NULL, NULL);
        
        //release item ref
        if(NULL != itemRef)
        {
            //dbg msg
            logMsg(LOG_DEBUG, [NSString stringWithFormat:@"added %@/%@", loginItem, itemRef]);
            
            //release
            CFRelease(itemRef);
            
            //reset
            itemRef = NULL;
        }
        //failed
        else
        {
            //err msg
            logMsg(LOG_ERR, @"failed to add login item");
            
            //bail
            goto bail;
        }
        
        //happy
        wasToggled = YES;
    }
    //remove (uninstall)
    else
    {
        //dbg msg
        logMsg(LOG_DEBUG, [NSString stringWithFormat:@"removing login item %@", loginItem]);
        
        //grab existing login items
        loginItems = LSSharedFileListCopySnapshot(loginItemsRef, nil);
        
        //iterate over all login items
        // look for self, then remove it
        for(id item in (__bridge NSArray *)loginItems)
        {
            //get current login item
            currentLoginItem = LSSharedFileListItemCopyResolvedURL((__bridge LSSharedFileListItemRef)item, 0, NULL);
            if(NULL == currentLoginItem)
            {
                //skip
                continue;
            }
            
            //current login item match self?
            if(YES == [(__bridge NSURL *)currentLoginItem isEqual:loginItem])
            {
                //remove
                if(noErr != LSSharedFileListItemRemove(loginItemsRef, (__bridge LSSharedFileListItemRef)item))
                {
                    //err msg
                    logMsg(LOG_ERR, @"failed to remove login item");
                    
                    //bail
                    goto bail;
                    
                }
                
                //dbg msg
                logMsg(LOG_DEBUG, [NSString stringWithFormat:@"removed login item: %@", loginItem]);
                
                //happy
                wasToggled = YES;
                
                //all done
                goto bail;
            }
            
            //release
            CFRelease(currentLoginItem);
            
            //reset
            currentLoginItem = NULL;
            
        }//all login items
        
    }//remove/uninstall
    
bail:
    
    //release login items
    if(NULL != loginItems)
    {
        //release
        CFRelease(loginItems);
        
        //reset
        loginItems = NULL;
    }
    
    //release login ref
    if(NULL != loginItemsRef)
    {
        //release
        CFRelease(loginItemsRef);
        
        //reset
        loginItemsRef = NULL;
    }
    
    //release url
    if(NULL != currentLoginItem)
    {
        //release
        CFRelease(currentLoginItem);
        
        //reset
        currentLoginItem = NULL;
    }
    
    return wasToggled;
}

#pragma clang diagnostic pop

//convert IP addr to (ns)string
// from: https://stackoverflow.com/a/29147085/3854841
NSString* convertIPAddr(unsigned char* ipAddr, __uint8_t socketFamily)
{
    //string
    NSString* socketDescription = nil;
    
    //socket address
    unsigned char socketAddress[INET6_ADDRSTRLEN+1] = {0};
    
    //what family?
    switch(socketFamily)
    {
        //IPv4
        case AF_INET:
        {
            //convert
            inet_ntop(AF_INET, ipAddr, (char*)&socketAddress, INET_ADDRSTRLEN);
            
            break;
        }
            
        //IPV6
        case AF_INET6:
        {
            //convert
            inet_ntop(AF_INET6, ipAddr, (char*)&socketAddress, INET6_ADDRSTRLEN);
            
            break;
        }
            
        default:
            break;
    }
    
    //convert to obj-c string
    if(0 != strlen((const char*)socketAddress))
    {
        //convert
        socketDescription = [NSString stringWithUTF8String:(const char*)socketAddress];
    }
    
    return socketDescription;
}

//convert socket numeric address to (ns)string
NSString* convertSocketAddr(struct sockaddr* socket)
{
    //string
    NSString* socketDescription = nil;
    
    //what family?
    switch(socket->sa_family)
    {
        //IPv4
        case AF_INET:
        {
            //typecast
            struct sockaddr_in *addr_in = (struct sockaddr_in *)socket;
            
            //convert
            socketDescription = convertIPAddr((unsigned char*)&addr_in->sin_addr, AF_INET);
            
            break;
        }
        
        //IPV6
        case AF_INET6:
        {
            //typecast
            struct sockaddr_in6 *addr_in6 = (struct sockaddr_in6 *)socket;

            //convert
            socketDescription = convertIPAddr((unsigned char*)&addr_in6->sin6_addr, AF_INET6);

            break;
        }
            
        default:
            break;
    }
    
    return socketDescription;
}

//check if process is alive
BOOL isProcessAlive(pid_t processID)
{
    //ret var
    BOOL bIsAlive = NO;
    
    //signal status
    int signalStatus = -1;
    
    //send kill with 0 to determine if alive
    signalStatus = kill(processID, 0);
    
    //is alive?
    if( (0 == signalStatus) ||
        ((0 != signalStatus) && (errno != ESRCH)) )
    {
        //alive!
        bIsAlive = YES;
    }
    
    return bIsAlive;
}


//hash a file (sha1)
NSMutableString* hashFile(NSString* filePath)
{
    //file's contents
    NSData* fileContents = nil;
    
    //hash digest (sha1)
    uint8_t digestSHA1[CC_SHA1_DIGEST_LENGTH] = {0};
    
    //sha1 hash as string
    NSMutableString* sha1 = nil;
    
    //index var
    NSUInteger index = 0;
    
    //init sha1 hash string
    sha1 = [NSMutableString string];
    
    //sanity check
    if(nil == filePath)
    {
        //bail
        goto bail;
    }
    
    //load file
    if(nil == (fileContents = [NSData dataWithContentsOfFile:filePath]))
    {
        //err msg
        logMsg(LOG_ERR, [NSString stringWithFormat:@"failed to load %@ to hash", filePath]);
        
        //bail
        goto bail;
    }
    
    //sha1 it
    CC_SHA1(fileContents.bytes, (unsigned int)fileContents.length, digestSHA1);
    
    //convert to NSString
    // ->iterate over each bytes in computed digest and format
    for(index=0; index < CC_SHA1_DIGEST_LENGTH; index++)
    {
        //format/append
        [sha1 appendFormat:@"%02lX", (unsigned long)digestSHA1[index]];
    }
    
    
bail:
    
    return sha1;
}

//given a pid, get its parent (ppid)
pid_t getParentID(int pid)
{
    //parent id
    pid_t parentID = -1;
    
    //kinfo_proc struct
    struct kinfo_proc processStruct = {0};
    
    //size
    size_t procBufferSize = sizeof(processStruct);
    
    //mib
    const u_int mibLength = 4;
    
    //syscall result
    int sysctlResult = -1;
    
    //init mib
    int mib[mibLength] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
    
    //make syscall
    sysctlResult = sysctl(mib, mibLength, &processStruct, &procBufferSize, NULL, 0);
    
    //check if got ppid
    if( (noErr == sysctlResult) &&
        (0 != procBufferSize) )
    {
        //save ppid
        parentID = processStruct.kp_eproc.e_ppid;
        
        //dbg msg
        logMsg(LOG_DEBUG, [NSString stringWithFormat:@"extracted parent ID %d for process: %d", parentID, pid]);
    }
    
    return parentID;
}

//check if an instance of an app is already running
BOOL isAppRunning(NSString* bundleID)
{
    //flag
    BOOL alreadyRunning = NO;
    
    //aleady an instance?
    // make that instance active and then bail
    for(NSRunningApplication* runningApp in [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleID])
    {
        //another instance that's not this?
        if(YES != [runningApp isEqual:[NSRunningApplication currentApplication]])
        {
            //set flag
            alreadyRunning = YES;
            
            //make (already) running instance first
            [runningApp activateWithOptions:NSApplicationActivateAllWindows|NSApplicationActivateIgnoringOtherApps];
            
            //done looking
            break;
        }
    }
    
    return alreadyRunning;
}


//exec a process with args
// if 'shouldWait' is set, wait and return stdout/in and termination status
NSMutableDictionary* execTask(NSString* binaryPath, NSArray* arguments, BOOL shouldWait)
{
    //task
    NSTask* task = nil;
    
    //output pipe for stdout
    NSPipe* stdOutPipe = nil;
    
    //output pipe for stderr
    NSPipe* stdErrPipe = nil;
    
    //read handle for stdout
    NSFileHandle* stdOutReadHandle = nil;
    
    //read handle for stderr
    NSFileHandle* stdErrReadHandle = nil;
    
    //results dictionary
    NSMutableDictionary* results = nil;
    
    //output for stdout
    NSMutableData *stdOutData = nil;
    
    //output for stderr
    NSMutableData *stdErrData = nil;
    
    //init dictionary for results
    results = [NSMutableDictionary dictionary];
    
    //init task
    task = [NSTask new];
    
    //only setup pipes if wait flag is set
    if(YES == shouldWait)
    {
        //init stdout pipe
        stdOutPipe = [NSPipe pipe];
        
        //init stderr pipe
        stdErrPipe = [NSPipe pipe];
        
        //init stdout read handle
        stdOutReadHandle = [stdOutPipe fileHandleForReading];
        
        //init stderr read handle
        stdErrReadHandle = [stdErrPipe fileHandleForReading];
        
        //init stdout output buffer
        stdOutData = [NSMutableData data];
        
        //init stderr output buffer
        stdErrData = [NSMutableData data];
        
        //set task's stdout
        task.standardOutput = stdOutPipe;
        
        //set task's stderr
        task.standardError = stdErrPipe;
    }
    
    //set task's path
    task.launchPath = binaryPath;
    
    //set task's args
    if(nil != arguments)
    {
        //set
        task.arguments = arguments;
    }
    
    //dbg msg
    logMsg(LOG_DEBUG, [NSString stringWithFormat:@"execing task, %@ (arguments: %@)", task.launchPath, task.arguments]);
    
    //wrap task launch
    @try
    {
        //launch
        [task launch];
    }
    @catch(NSException *exception)
    {
        //err msg
        logMsg(LOG_ERR, [NSString stringWithFormat:@"failed to launch task (%@)", exception]);
        
        //bail
        goto bail;
    }
    
    //no need to wait
    // can just bail w/ no output
    if(YES != shouldWait)
    {
        //bail
        goto bail;
    }
    
    //read in stdout/stderr
    while(YES == [task isRunning])
    {
        //accumulate stdout
        [stdOutData appendData:[stdOutReadHandle readDataToEndOfFile]];
        
        //accumulate stderr
        [stdErrData appendData:[stdErrReadHandle readDataToEndOfFile]];
    }
    
    //grab any leftover stdout
    [stdOutData appendData:[stdOutReadHandle readDataToEndOfFile]];
    
    //grab any leftover stderr
    [stdErrData appendData:[stdErrReadHandle readDataToEndOfFile]];
    
    //add stdout
    if(0 != stdOutData.length)
    {
        //add
        results[STDOUT] = stdOutData;
    }
    
    //add stderr
    if(0 != stdErrData.length)
    {
        //add
        results[STDERR] = stdErrData;
    }
    
    //add exit code
    results[EXIT_CODE] = [NSNumber numberWithInteger:task.terminationStatus];
    
bail:
    
    return results;
}

//extract a DNS url
// per spec, format is: [len]bytes[len][bytes]0x0
NSMutableString* extractDNSURL(unsigned char* dnsData, unsigned char* dnsDataEnd)
{
    //size of chunk
    NSUInteger chunkSize = 0;
    
    //url
    NSMutableString* url = nil;
    
    //alloc
    url = [NSMutableString string];
    
    //until we hit a NULL
    while(0x0 != *dnsData)
    {
        //grab size & check
        chunkSize = *dnsData++ & 0xFF;
        if(dnsData+chunkSize >= dnsDataEnd)
        {
            //bail
            goto bail;
        }
        
        //append each byte of url chunk
        for(NSUInteger i = 0; i < chunkSize; i++)
        {
            //sanity check
            if(0 == (dnsData[i] & 0xFF))
            {
                //bail
                goto bail;
            }
            
            //add byte
            [url appendFormat:@"%c", dnsData[i]];
        }
        
        //next chunk
        dnsData += chunkSize;
        
        //not last chunk?
        // add a '.' to url
        if( (dnsData < dnsDataEnd) &&
            (0x0 != *dnsData) )
        {
            //append dot
            [url appendString:@"."];
        }
    }
    
bail:
    
    return url;
}

//restart
void restart()
{
    //first quit self
    // then reboot the box...nicely!
    execTask(OSASCRIPT, @[@"-e", @"tell application \"LuLu Installer\" to quit", @"-e", @"delay 0.1", @"-e", @"tell application \"Finder\" to restart"], NO);

    return;
}

