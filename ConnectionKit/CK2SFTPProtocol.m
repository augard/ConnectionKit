//
//  CK2SFTPProtocol.m
//  Connection
//
//  Created by Mike on 15/10/2012.
//
//

#import "CK2SFTPProtocol.h"
#import "CK2Authentication.h"

#import <CURLHandle/CK2SSHCredential.h>

#import <AppKit/AppKit.h>
#import <CURLHandle/CURLHandle.h>
#import <libssh2_sftp.h>

@implementation CK2SFTPProtocol

+ (BOOL)canHandleURL:(NSURL *)url;
{
    NSString *scheme = [url scheme];
    return ([@"scp" caseInsensitiveCompare:scheme] == NSOrderedSame || [@"sftp" caseInsensitiveCompare:scheme] == NSOrderedSame);
}

+ (NSURL *)URLWithPath:(NSString *)path relativeToURL:(NSURL *)baseURL;
{
    // SCP and SFTP represent the home directory using ~/ at the start of the path <http://curl.haxx.se/libcurl/c/curl_easy_setopt.html#CURLOPTURL>
    if (![path isAbsolutePath] && [[baseURL path] length] <= 1)
    {
        path = [@"/~" stringByAppendingPathComponent:path];
    }
    
    return [super URLWithPath:path relativeToURL:baseURL];
}

+ (NSString *)pathOfURLRelativeToHomeDirectory:(NSURL *)URL;
{
    NSString *result = [super pathOfURLRelativeToHomeDirectory:URL];
    
    // SCP and SFTP represent the home directory using ~/ at the start of the path
    if ([result hasPrefix:@"/~/"])
    {
        result = [result substringFromIndex:3];
    }
    else if ([result isEqualToString:@"/~"])
    {
        result = @"";   // seems a bit weird to have empty path, but enumeration acts badly if we return @"." instead
    }
    
    return result;
}

#pragma mark Operations

- (id)initForCreatingDirectoryWithRequest:(NSURLRequest *)request withIntermediateDirectories:(BOOL)createIntermediates openingAttributes:(NSDictionary *)attributes client:(id<CK2ProtocolClient>)client;
{
    NSMutableURLRequest *mutableRequest = [request mutableCopy];
    [mutableRequest curl_setNewDirectoryPermissions:[attributes objectForKey:NSFilePosixPermissions]];

    NSString* path = [self.class pathOfURLRelativeToHomeDirectory:[request URL]];

    NSString* command = [@"mkdir " stringByAppendingString:path];
    self = [self initWithCustomCommands:[NSArray arrayWithObject:command]
                                request:mutableRequest
          createIntermediateDirectories:createIntermediates
                                 client:client
                      completionHandler:^(NSError *error) {
                          if (error)
                          {
                              // if the mkdir command failed, try to extract a more meaningful error
                              if ([error code] == CURLE_QUOTE_ERROR && [[error domain] isEqualToString:CURLcodeErrorDomain])
                              {
                                  error = [self standardCouldntWriteErrorWithUnderlyingError:error];
                                  // TODO: can we distinguish here between failure because the directory exists, and failure for some other reason?
                              }
                          }

                          [self reportToProtocolWithError:error];
                      }];
    
    _transcriptMessage = [[NSString alloc] initWithFormat:@"Making directory %@\n", path];
    
    [mutableRequest release];
    return self;
}

- (id)initForCreatingFileWithRequest:(NSURLRequest *)request withIntermediateDirectories:(BOOL)createIntermediates openingAttributes:(NSDictionary *)attributes client:(id<CK2ProtocolClient>)client progressBlock:(CK2ProgressBlock)progressBlock;
{
    NSMutableURLRequest *mutableRequest = [request mutableCopy];
    [mutableRequest curl_setCreateIntermediateDirectories:createIntermediates];
    [mutableRequest curl_setNewFilePermissions:[attributes objectForKey:NSFilePosixPermissions]];
    
    NSString* path = [self.class pathOfURLRelativeToHomeDirectory:[request URL]];
    NSString* name = [path lastPathComponent];

    self = [self initWithRequest:mutableRequest client:client progressBlock:progressBlock completionHandler:nil];
    
    _transcriptMessage = [[NSString alloc] initWithFormat:@"Uploading %@ to %@\n", name, path];
    
    [mutableRequest release];
    
    return self;
}

- (id)initForRenamingItemWithRequest:(NSURLRequest *)request newName:(NSString *)newName client:(id<CK2ProtocolClient>)client
{
    NSString* srcPath = [self.class pathOfURLRelativeToHomeDirectory:[request URL]];
    NSString* dstPath = [[srcPath stringByDeletingLastPathComponent] stringByAppendingPathComponent:newName];

    return [self initWithCustomCommands:[NSArray arrayWithObject:[NSString stringWithFormat:@"rename %@ %@", srcPath, dstPath]]
                                request:request
          createIntermediateDirectories:NO
                                 client:client
                      completionHandler:^(NSError *error) {
                          if (error)
                          {
                              if ([error code] == CURLE_QUOTE_ERROR && [[error domain] isEqualToString:CURLcodeErrorDomain])
                              {
                                  error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteUnknownError userInfo:@{ NSUnderlyingErrorKey : error }];
                              }
                          }

                          [self reportToProtocolWithError:error];
                      }];
}

- (id)initForRemovingItemWithRequest:(NSURLRequest *)request client:(id<CK2ProtocolClient>)client;
{
    NSURL *url = request.URL;
    
    // Pick an appropriate command
    NSString *command = @"rm ";
    
    NSNumber *isDirectory;
    if ([url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:NULL] && isDirectory.boolValue)
    {
        command = @"rmdir ";
    }
    else if (CFURLHasDirectoryPath((CFURLRef)url))
    {
        command = @"rmdir ";
    }
    
    
    NSString* path = [self.class pathOfURLRelativeToHomeDirectory:url];
    
    self = [self initWithCustomCommands:[NSArray arrayWithObject:[command stringByAppendingString:path]]
                                request:request
          createIntermediateDirectories:NO
                                 client:client
                      completionHandler:^(NSError *error) {
                          if (error)
                          {
                              if ([error code] == CURLE_QUOTE_ERROR && [[error domain] isEqualToString:CURLcodeErrorDomain])
                              {
                                  //NSUInteger sshError = [error curlResponseCode];
                                  error = [self standardCouldntWriteErrorWithUnderlyingError:error];
                              }
                          }

                          [self reportToProtocolWithError:error];
                      }];
    
    _transcriptMessage = [[NSString alloc] initWithFormat:@"Removing %@\n", path];
    
    return self;
}

- (id)initForSettingAttributes:(NSDictionary *)keyedValues ofItemWithRequest:(NSURLRequest *)request client:(id<CK2ProtocolClient>)client;
{
    NSNumber *permissions = [keyedValues objectForKey:NSFilePosixPermissions];
    if (permissions)
    {
        NSString* path = [self.class pathOfURLRelativeToHomeDirectory:[request URL]];

        NSArray *commands = [NSArray arrayWithObject:[NSString stringWithFormat:
                                                      @"chmod %lo %@",
                                                      [permissions unsignedLongValue],
                                                      path]];
        
        self = [self initWithCustomCommands:commands
                                    request:request
              createIntermediateDirectories:NO
                                     client:client
                          completionHandler:^(NSError *error) {
                              if (error)
                              {
                                  if ([error code] == CURLE_QUOTE_ERROR && [[error domain] isEqualToString:CURLcodeErrorDomain])
                                  {
                                      NSUInteger sshError = [error curlResponseCode];
                                      switch (sshError)
                                      {
                                          case LIBSSH2_FX_NO_SUCH_FILE:
                                              error = [self standardFileNotFoundErrorWithUnderlyingError:error];
                                              break;

                                          default:
                                              error = [self standardCouldntWriteErrorWithUnderlyingError:error];
                                              break;
                                      }
                                  }
                              }
                              
                              [self reportToProtocolWithError:error];
                          }];
        
        _transcriptMessage = [[NSString alloc] initWithFormat:@"Changing mode on %@\n", path];
    }
    else
    {
        self = [self initWithRequest:nil client:client];
    }
    
    return self;
}

#pragma mark Lifecycle

- (void)start;
{
    // If there's no request, that means we were asked to do nothing possible over SFTP. Most likely, storing attributes that aren't POSIX permissions
    // So jump straight to completion
    if (![self request])
    {
        [[self client] protocolDidFinish:self];
        return;
    }
    
    
    // Note what we're up to
    if (_transcriptMessage)
    {
        [self.client protocol:self appendString:_transcriptMessage toTranscript:CK2TranscriptHeaderOut];
        [_transcriptMessage release]; _transcriptMessage = nil;
    }
    
    
    // Grab the login credential
    NSURL *url = [[self request] URL];
    
    NSURLProtectionSpace *space = [[CK2SSHProtectionSpace alloc] initWithHost:[url host]
                                                                         port:[[url port] integerValue]
                                                                     protocol:@"ssh"
                                                                        realm:nil
                                                         authenticationMethod:NSURLAuthenticationMethodDefault];
    
    NSURLAuthenticationChallenge *challenge = [[NSURLAuthenticationChallenge alloc] initWithProtectionSpace:space
                                                                                         proposedCredential:nil // client will fill it in for us
                                                                                       previousFailureCount:0
                                                                                            failureResponse:nil
                                                                                                      error:nil
                                                                                                     sender:self];
    
    
    [space release];
    
    [[self client] protocol:self didReceiveAuthenticationChallenge:challenge];
    [challenge release];
}

- (void)dealloc;
{
    [_fingerprintChallenge release];
    if (_fingerprintSemaphore) dispatch_release(_fingerprintSemaphore);
    [_transcriptMessage release];
    
    [super dealloc];
}

#pragma mark Auth

- (void)useCredential:(NSURLCredential *)credential forAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge;
{
    if (challenge == _fingerprintChallenge && _fingerprintChallenge)
    {
        [self useKnownHostsStat:([credential persistence] == NSURLCredentialPersistencePermanent ? CURLKHSTAT_FINE_ADD_TO_FILE : CURLKHSTAT_FINE)];
    }
    else
    {
        [super useCredential:credential forAuthenticationChallenge:challenge];
    }
}

- (void)continueWithoutCredentialForAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge;
{
    if (challenge == _fingerprintChallenge && _fingerprintChallenge)
    {
        [self useKnownHostsStat:CURLKHSTAT_REJECT];
    }
    else
    {
        [super continueWithoutCredentialForAuthenticationChallenge:challenge];
    }
}

- (void)cancelAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge;
{
    if (challenge == _fingerprintChallenge && _fingerprintChallenge)
    {
        [self useKnownHostsStat:CURLKHSTAT_REJECT];
    }
    else
    {
        [super cancelAuthenticationChallenge:challenge];
    }
}

- (id)initWithRequest:(NSURLRequest *)request client:(id<CK2ProtocolClient>)client;
{
    // Add the known hosts file setting to the request
    NSMutableURLRequest *mutableRequest = [request mutableCopy];
    [mutableRequest curl_setSSHKnownHostsFileURL:[NSURL fileURLWithPath:[@"~/.ssh/known_hosts" stringByExpandingTildeInPath] isDirectory:NO]];
    
    self = [super initWithRequest:request client:client];
    [mutableRequest release];
    return self;
}

- (void)popCompletionHandlerByExecutingWithError:(NSError *)error;
{
    if (error)
    {
        // adjust the reported URL so that it's actually the full one (libcurl only got given one with the last component removed)
        NSURL* url = [self.request URL];
        if (![[error.userInfo objectForKey:NSURLErrorFailingURLErrorKey] isEqual:url])
        {
            NSMutableDictionary* modifiedInfo = [NSMutableDictionary dictionaryWithDictionary:error.userInfo];
            [modifiedInfo setObject:url forKey:NSURLErrorFailingURLErrorKey];
            [modifiedInfo setObject:[url absoluteString] forKey:NSURLErrorFailingURLStringErrorKey];
            error = [NSError errorWithDomain:error.domain code:error.code userInfo:modifiedInfo];
        }

        // Re-package host key failures as something more in the vein of NSURLConnection
        if (error.code == CURLE_PEER_FAILED_VERIFICATION && [error.domain isEqualToString:CURLcodeErrorDomain])
        {
            error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorServerCertificateUntrusted userInfo:[error userInfo]];
        }
    }

    [super popCompletionHandlerByExecutingWithError:error];
}

#pragma mark Host Fingerprint

- (enum curl_khstat)transfer:(CURLTransfer *)transfer didFindHostFingerprint:(const struct curl_khkey *)foundKey knownFingerprint:(const struct curl_khkey *)knownkey match:(enum curl_khmatch)match;
{
    if (!_fingerprintSemaphore)
    {
        // Report the key back to delegate to see how it feels about this. Unfortunately have to uglily use a semaphore to do so
        NSURLProtectionSpace *space = [NSURLProtectionSpace ck2_protectionSpaceWithHost:self.request.URL.host
                                                                                                    knownHostMatch:match];
        
        NSURLCredential *credential = nil;
        if (match != CURLKHMATCH_MISMATCH) credential = [NSURLCredential ck2_credentialForKnownHostWithPersistence:NSURLCredentialPersistencePermanent];
        
        _fingerprintChallenge = [[NSURLAuthenticationChallenge alloc] initWithProtectionSpace:space
                                                                           proposedCredential:credential
                                                                         previousFailureCount:0
                                                                              failureResponse:nil
                                                                                        error:nil
                                                                                       sender:self];
        
        _fingerprintSemaphore = dispatch_semaphore_create(0);   // must be setup before handing off to client
        [[self client] protocol:self didReceiveAuthenticationChallenge:_fingerprintChallenge];
    }
    
    // Until the client replies, give libcurl a chance to process anything else. Ugly isn't it?
    if (dispatch_semaphore_wait(_fingerprintSemaphore, 100 * NSEC_PER_MSEC))
    {
        return CURLKHSTAT_DEFER;
    }
    
    // Finished waiting; cleanup
    dispatch_release(_fingerprintSemaphore); _fingerprintSemaphore = NULL;
    
    return _knownHostsStat;
}

- (void)useKnownHostsStat:(enum curl_khstat)stat;
{
    NSAssert(_fingerprintChallenge, @"Somehow been told to use curl_khstat without having issued a challenge");
    [_fingerprintChallenge release]; _fingerprintChallenge = nil;
    
    // Use semaphore to signal we know have a result
    _knownHostsStat = stat;
    dispatch_semaphore_signal(_fingerprintSemaphore);   // can't dispose of yet, as might not be currently waiting on it
}

@end
