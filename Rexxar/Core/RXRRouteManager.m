//
//  RXRRouteManager.m
//  Rexxar
//
//  Created by GUO Lin on 5/11/16.
//  Copyright © 2016 Douban.Inc. All rights reserved.
//

#import <UIKit/UIKit.h>

#import "RXRRouteManager.h"
#import "RXRRouteFileCache.h"
#import "RXRConfig.h"
#import "RXRConfig+Rexxar.h"
#import "RXRRoute.h"
#import "RXRLogger.h"

@interface RXRRouteManager ()

@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionConfiguration *sessionConfiguration;
@property (nonatomic, strong) NSOperationQueue *sessionDelegateQueue;

@property (nonatomic, copy) NSArray<RXRRoute *> *routes;
@property (nonatomic, assign) BOOL updatingRoutes;
@property (nonatomic, strong) NSMutableArray *updateRoutesCompletions;

@end


@implementation RXRRouteManager

+ (RXRRouteManager *)sharedInstance
{
  static RXRRouteManager *instance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    instance = [[RXRRouteManager alloc] init];
    instance.routesMapURL = [RXRConfig routesMapURL];
  });
  return instance;
}

- (instancetype)init
{
  self = [super init];
  if (self) {
    NSString *sessionName = [NSString stringWithFormat:@"%@.%@.%p.URLSession", [[NSBundle mainBundle] bundleIdentifier], NSStringFromClass([self class]), self];
    NSString *delegateQueueName = [NSString stringWithFormat:@"%@.delegateQueue", sessionName];
    _sessionConfiguration = [[RXRConfig requestsURLSessionConfiguration] copy];
    _sessionDelegateQueue = [[NSOperationQueue alloc] init];
    _sessionDelegateQueue.maxConcurrentOperationCount = 1;
    _sessionDelegateQueue.name = delegateQueueName;
    _session = [NSURLSession sessionWithConfiguration:_sessionConfiguration delegate:nil delegateQueue:_sessionDelegateQueue];
    _session.sessionDescription = sessionName;
    _updateRoutesCompletions = [NSMutableArray array];
  }
  return self;
}

- (void)setRoutesMapURL:(NSURL *)routesMapURL
{
  if (_routesMapURL != routesMapURL) {
    _routesMapURL = [routesMapURL copy];
    self.routes = [self _rxr_routesWithData:[[RXRRouteFileCache sharedInstance] routesMapFile]];
  }
}

- (void)setCachePath:(NSString *)cachePath
{
  RXRRouteFileCache *routeFileCache = [RXRRouteFileCache sharedInstance];
  routeFileCache.cachePath = cachePath;
  self.routes = [self _rxr_routesWithData:[routeFileCache routesMapFile]];
}

- (void)setResoucePath:(NSString *)resourcePath
{
  RXRRouteFileCache *routeFileCache = [RXRRouteFileCache sharedInstance];
  routeFileCache.resourcePath = resourcePath;
  self.routes = [self _rxr_routesWithData:[routeFileCache routesMapFile]];
}

- (void)updateRoutesWithCompletion:(void (^)(BOOL success))completion
{
  NSParameterAssert([NSThread isMainThread]);

  if (self.routesMapURL == nil) {
    RXRDebugLog(@"[Warning] `routesRemoteURL` not set.");

    if ([RXRConfig rxr_canLog]) {
      RXRLogObject *logObj = [[RXRLogObject alloc] initWithLogType:RXRLogTypeNoRoutesMapURLError
                                                             error:nil
                                                        requestURL:nil
                                                     localFilePath:nil
                                                  otherInformation:nil];
      [RXRConfig rxr_logWithLogObject:logObj];
    }

    return;
  }

  if (completion) {
    [self.updateRoutesCompletions addObject:completion];
  }

  if (self.updatingRoutes) {
    return;
  }

  self.updatingRoutes = YES;

  void (^APICompletion)(BOOL) = ^(BOOL success){
    dispatch_async(dispatch_get_main_queue(), ^{
      for (void (^item)(BOOL) in self.updateRoutesCompletions) {
        item(success);
      }
      [self.updateRoutesCompletions removeAllObjects];
      self.updatingRoutes = NO;
    });
  };

  // 请求路由表 API
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:self.routesMapURL
                                                         cachePolicy:NSURLRequestReloadIgnoringLocalAndRemoteCacheData
                                                     timeoutInterval:60];
  // 更新 Http UserAgent Header
  NSString *externalUserAgent = [RXRConfig externalUserAgent];
  if (externalUserAgent) {
    NSString *userAgent = [request.allHTTPHeaderFields objectForKey:@"User-Agent"];
    NSMutableArray *components = [NSMutableArray array];
    if (userAgent) {
      [components addObject:userAgent];
    }
    NSArray *externalUAItems = [externalUserAgent componentsSeparatedByString:@" "];
    for (NSString *item in externalUAItems) {
      if (![userAgent containsString:item]) {
        [components addObject:item];
      }
    }
    NSString *newUserAgent = [components componentsJoinedByString:@" "];
    [request setValue:newUserAgent forHTTPHeaderField:@"User-Agent"];
  }

  [[self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
    RXRDebugLog(@"Download %@", response.URL);
    RXRDebugLog(@"Response: %@", response);

    if (((NSHTTPURLResponse *)response).statusCode != 200) {
      APICompletion(NO);
      if ([RXRConfig rxr_canLog]) {

        RXRLogObject *logObj = [[RXRLogObject alloc] initWithLogType:RXRLogTypeDownloadingRoutesError
                                                               error:error
                                                          requestURL:request.URL
                                                       localFilePath:nil
                                                    otherInformation:@{logOtherInfoStatusCodeKey: @(((NSHTTPURLResponse *)response).statusCode)}];
        [RXRConfig rxr_logWithLogObject:logObj];
      }

      return;
    }

    // 下载最新 routes 中的资源文件，只有成功后，才更新 `routes.json` 及内存中的 `routes`。
    NSArray *routes = [self _rxr_routesWithData:data];
    [self _rxr_downloadFilesWithinRoutes:routes completion:^(BOOL success) {
      if (success) {
        self.routes = routes;
        RXRRouteFileCache *routeFileCache = [RXRRouteFileCache sharedInstance];
        [routeFileCache saveRoutesMapFile:data];
      }

      APICompletion(success);
    }];
  }] resume];
}

- (NSURL *)localHtmlURLForURI:(NSURL *)uri
{
  NSURL *remoteHtmlURL = [self remoteHtmlURLForURI:uri];
  RXRRouteFileCache *routeFileCache = [RXRRouteFileCache sharedInstance];
  return [routeFileCache routeFileURLForRemoteURL:remoteHtmlURL];
}

- (NSURL *)remoteHtmlURLForURI:(NSURL *)uri
{
  RXRRoute *route = [self _rxr_routeForURI:uri];
  if (route) {
    return  route.remoteHTML;
  }
  return nil;
}

#pragma mark - Private Methods

- (RXRRoute *)_rxr_routeForURI:(NSURL *)uri
{
  NSString *uriString = uri.absoluteString;
  if (uriString.length == 0) {
    return nil;
  }

  // 从路由表中找到符合 URI 的 Route。
  for (RXRRoute *route in self.routes) {
    if ([route.URIRegex numberOfMatchesInString:uriString options:0 range:NSMakeRange(0, uriString.length)] > 0) {
      return route;
    }
  }
  return nil;
}

- (NSArray *)_rxr_routesWithData:(NSData *)data
{
  if (data == nil) {
    return nil;
  }

  NSDictionary *JSON = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (JSON == nil) {
    return nil;
  }

  NSMutableArray *items = [[NSMutableArray alloc] init];
  // 页面级别的 route
  for (NSDictionary *item in JSON[@"items"]) {
    [items addObject:[[RXRRoute alloc] initWithDictionary:item]];
  }

  // 局部页面的 route
  for (NSDictionary *item in JSON[@"partial_items"]) {
    [items addObject:[[RXRRoute alloc] initWithDictionary:item]];
  }

  NSString *routesDepolyTime = JSON[@"deploy_time"];
  if (routesDepolyTime) {
    _routesDeployTime = [routesDepolyTime copy];
  }
  else {
    _routesDeployTime = nil;
  }

  return items;
}

/**
 *  下载 `routes` 中的资源文件。
 */
- (void)_rxr_downloadFilesWithinRoutes:(NSArray *)routes completion:(void (^)(BOOL success))completion
{
  dispatch_group_t downloadGroup = nil;
  if (completion) {
    downloadGroup = dispatch_group_create();
  }

  BOOL __block success = YES;

  for (RXRRoute *route in routes) {

    // 如果文件在本地文件存在（要么在缓存，要么在资源文件夹），什么都不需要做
    if ([[RXRRouteFileCache sharedInstance] routeFileURLForRemoteURL:route.remoteHTML]) {
      continue;
    }

    if (downloadGroup) { dispatch_group_enter(downloadGroup); }

    // 文件不存在，下载下来。
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:route.remoteHTML
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalAndRemoteCacheData
                                                       timeoutInterval:60];
    [[self.session downloadTaskWithRequest:request completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {

      RXRDebugLog(@"Download %@", response.URL);
      RXRDebugLog(@"Response: %@", response);

      if (error || ((NSHTTPURLResponse *)response).statusCode != 200) {
        // Log
        if ([RXRConfig rxr_canLog]) {
          RXRLogObject *logObj = [[RXRLogObject alloc] initWithLogType:RXRLogTypeDownloadingHTMLFileError
                                                                 error:error
                                                            requestURL:request.URL
                                                         localFilePath:nil
                                                      otherInformation:@{logOtherInfoStatusCodeKey: @(((NSHTTPURLResponse *)response).statusCode)}];
          [RXRConfig rxr_logWithLogObject:logObj];
        }

        success = NO;
        if (downloadGroup) { dispatch_group_leave(downloadGroup); }

        RXRDebugLog(@"Fail to move download remote html: %@", error);
        return;
      }

      NSData *data = [NSData dataWithContentsOfURL:location];

      // Validate data
      if (_dataValidator
          && [_dataValidator respondsToSelector:@selector(validateRemoteHTMLFile:fileData:)]
          && ![_dataValidator validateRemoteHTMLFile:route.remoteHTML fileData:data]) {

        // Log
        if ([RXRConfig rxr_canLog]) {
          NSDictionary *otherInfo;
          if (RXRRouteManager.sharedInstance.routesDeployTime) {
            otherInfo = @{logOtherInfoRoutesDepolyTimeKey: RXRRouteManager.sharedInstance.routesDeployTime};
          }
          RXRLogObject *logObj = [[RXRLogObject alloc] initWithLogType:RXRLogTypeValidatingHTMLFileError
                                                                 error:nil
                                                            requestURL:route.remoteHTML
                                                         localFilePath:nil
                                                      otherInformation:otherInfo];
          [RXRConfig rxr_logWithLogObject:logObj];
        }

        if ([_dataValidator respondsToSelector:@selector(stopDownloadingIfValidationFailed)]
            && [_dataValidator stopDownloadingIfValidationFailed]) {
          success = NO;
          if (downloadGroup) {
            dispatch_group_leave(downloadGroup);
          }
          return;
        }
      }

      [[RXRRouteFileCache sharedInstance] saveRouteFileData:data withRemoteURL:response.URL];

      if (downloadGroup) { dispatch_group_leave(downloadGroup); }
    }] resume];
  }

  if (downloadGroup) {
    dispatch_group_notify(downloadGroup, dispatch_get_main_queue(), ^{
      completion(success);
    });
  }
}

@end
