//
//  GEAppLaunchReason.m
//  GravityEngineSDK
//
//  Copyright © 2021 gravityengine. All rights reserved.
//

#import "GEAppLaunchReason.h"
#import <objc/runtime.h>
#import "GECommonUtil.h"
#import "GEPresetProperties+GEDisProperties.h"
#import "GEAspects.h"
#import "GEAppState.h"
#import "GravityEngineSDKPrivate.h"

#define ge_force_inline __inline__ __attribute__((always_inline))


static id __ge_get_userNotificationCenter() {
    Class cls = NSClassFromString(@"UNUserNotificationCenter");
    SEL sel = NSSelectorFromString(@"currentNotificationCenter");
    if ([cls respondsToSelector:sel]) {
        id (*getUserNotificationCenterIMP)(id, SEL) = (NSString * (*)(id, SEL))[cls methodForSelector:sel];
        return getUserNotificationCenterIMP(cls, sel);
    }
    return nil;
}

static id __ge_get_userNotificationCenter_delegate() {
    Class cls = NSClassFromString(@"UNUserNotificationCenter");
    SEL sel = NSSelectorFromString(@"currentNotificationCenter");
    SEL delegateSel = NSSelectorFromString(@"delegate");
    if ([cls respondsToSelector:sel]) {
        id (*getUserNotificationCenterIMP)(id, SEL) = (id (*)(id, SEL))[cls methodForSelector:sel];
        id center = getUserNotificationCenterIMP(cls, sel);
        if (center) {
            id (*getUserNotificationCenterDelegateIMP)(id, SEL) = (id (*)(id, SEL))[center methodForSelector:delegateSel];
            id delegate = getUserNotificationCenterDelegateIMP(center, delegateSel);
            return delegate;
        }
    }
    return nil;
}

static NSDictionary * __ge_get_userNotificationCenterResponse(id response) {
    
    @try {
        if ([response isKindOfClass:[NSClassFromString(@"UNNotificationResponse") class]]) {
            return [response valueForKeyPath:@"notification.request.content.userInfo"];
        }
    } @catch (NSException *exception) {
        
    }
    return nil;
}

static NSString * __ge_get_userNotificationCenterRequestContentTitle(id response) {
    
    @try {
        if ([response isKindOfClass:[NSClassFromString(@"UNNotificationResponse") class]]) {
            return [response valueForKeyPath:@"notification.request.content.title"];
        }
    } @catch (NSException *exception) {
        
    }
    return nil;
}

static NSString * __ge_get_userNotificationCenterRequestContentBody(id response) {
    
    @try {
        if ([response isKindOfClass:[NSClassFromString(@"UNNotificationResponse") class]]) {
            return [response valueForKeyPath:@"notification.request.content.body"];
        }
    } @catch (NSException *exception) {
        
    }
    return nil;
}

//static ge_force_inline void __td_ge_swizzleWithOriSELStr(id target, NSString *oriSELStr, SEL newSEL, IMP newIMP) {
//    SEL origSEL = NSSelectorFromString(oriSELStr);
//    Method origMethod = class_getInstanceMethod([target class], origSEL);
//
//    if ([target respondsToSelector:origSEL]) {
//        // 给当前类添加新方法(newSEL, newIMP)
//        class_addMethod([target class], newSEL, newIMP, method_getTypeEncoding(origMethod));
//
//        // 获取原始方法实现，方法实现可能是当前类，也可能是父类
//        Method origMethod = class_getInstanceMethod([target class], origSEL);
//        // 新方法实现
//        Method newMethod = class_getInstanceMethod([target class], newSEL);
//
//        // 判断当前类是否实现原始方法
//        if(class_addMethod([target class], origSEL, method_getImplementation(newMethod), method_getTypeEncoding(newMethod))) {
//            // 当前类没有实现原始方法，父类实现了原始方法
//            // 给当前类添加原始方法(origSEL, newIMP)，调用class_replaceMethod后，当前类的新方法和原始方法的IMP交换了
//            // 不会污染父类
//            class_replaceMethod([target class], newSEL, method_getImplementation(origMethod), method_getTypeEncoding(origMethod));
//        } else {
//            // 当前类实现了原始方法，只会交换当前类，不会污染父类
//            method_exchangeImplementations(origMethod, newMethod);
//        }
//    } else {
//        // 类和父类都没有实现，给当前类添加新方法，不会污染父类
//        class_addMethod([target class], origSEL, newIMP, method_getTypeEncoding(origMethod));
//    }
//}
//

@implementation GEAppLaunchReason

+ (void)load {
    
    // 是否需要采集启动原因
    [GEPresetProperties disPresetProperties];
    if ([GEPresetProperties disableStartReason] && [GEPresetProperties disableOpsReceiptProperties]) return;

#if defined(__IPHONE_13_0) && __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
    if (@available(iOS 13.0, *)) {
        [[NSNotificationCenter defaultCenter] addObserver:[GEAppLaunchReason sharedInstance]
                                                 selector:@selector(_sceneWillConnectToSession:)
                                                     name:UISceneWillConnectNotification
                                                   object:nil];
    }

#endif
    
    [[NSNotificationCenter defaultCenter] addObserver:[GEAppLaunchReason sharedInstance]
                                             selector:@selector(_applicationDidFinishLaunchingNotification:)
                                                 name:UIApplicationDidFinishLaunchingNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:[GEAppLaunchReason sharedInstance]
                                             selector:@selector(_applicationDidEnterBackgroundNotification:)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];
    
}



+ (void)ge_hookUserNotificationCenterMethod {
    if (@available(iOS 10.0, *)) {
        // 要求推送的代理需要在application:didFinishLaunchingWithOptions:设置
        // 如果不是在application:didFinishLaunchingWithOptions:设置，那么冷启动时推送的消息会收集不到
        if (__ge_get_userNotificationCenter_delegate()) {
            [self ge_hookUserNotificationCenterDelegateMethod];
        } else {
            [self addDelegateObserverToUserNotificationCenter:__ge_get_userNotificationCenter()];
        }
    }
}


#pragma mark - KVO for UNUserNotificationCenter

+ (void)addDelegateObserverToUserNotificationCenter:(id)userNotificationCenter {

    if (userNotificationCenter != nil) {
        @try {
          [userNotificationCenter addObserver:[GEAppLaunchReason sharedInstance]
                                   forKeyPath:NSStringFromSelector(@selector(delegate))
                                      options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld
                                      context:@"UserNotificationObserverContext"];
        } @catch (NSException *exception) {
        } @finally {
        }
    }

}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change
                       context:(void *)context {
  if (context == @"UserNotificationObserverContext") {
    if ([keyPath isEqualToString:NSStringFromSelector(@selector(delegate))]) {
//      id oldDelegate = change[NSKeyValueChangeOldKey];
//      if (oldDelegate && oldDelegate != [NSNull null]) {
//      }
      id newDelegate = change[NSKeyValueChangeNewKey];
      if (newDelegate && newDelegate != [NSNull null]) {
          [GEAppLaunchReason ge_hookUserNotificationCenterDelegateMethod];
      }
    }
  } else {
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
  }
}

#pragma mark - NSProxy methods


+ (void)ge_hookUserNotificationCenterDelegateMethod {
    
    @try {
        NSString *pushSel = @"userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:";
        [__ge_get_userNotificationCenter_delegate() ta_aspect_hookSelector:NSSelectorFromString(pushSel) withOptions:GEAspectPositionAfter usingBlock:^(id<GEAspectInfo> aspectInfo, id center ,id response ,id completionHandler) {
            
            if (![GEPresetProperties disableStartReason]) {
                NSMutableDictionary *properties = [[NSMutableDictionary alloc] init];
                NSDictionary *userInfo = __ge_get_userNotificationCenterResponse(response);
                if (userInfo) {
                    [properties addEntriesFromDictionary:userInfo];
                }
                properties[@"title"] = __ge_get_userNotificationCenterRequestContentTitle(response);
                properties[@"body"] = __ge_get_userNotificationCenterRequestContentBody(response);
                
                [[GEAppLaunchReason sharedInstance] clearAppLaunchParams];
                [GEAppLaunchReason sharedInstance].appLaunchParams = @{@"url": @"",
                                                                       @"data": [GECommonUtil dictionary:properties]};
            }
            
            if (![GEPresetProperties disableOpsReceiptProperties]) {
                @try {
                    if ([response isKindOfClass:[NSClassFromString(@"UNNotificationResponse") class]]) {
                        NSDictionary *userInfo = [response valueForKeyPath:@"notification.request.content.userInfo"];
                        [self ge_ops_push_click:userInfo];
                    }
                } @catch (NSException *exception) {
                    
                }
            }
        } error:NULL];
    } @catch (NSException *exception) {
        
    }
}


+ (void)ge_ops_push_click:(NSDictionary *)userInfo {
    
    @try {
        if ([userInfo.allKeys containsObject:@"te_extras"] && [userInfo[@"te_extras"] isKindOfClass:[NSString class]]) {
            NSData *jsonData = [userInfo[@"te_extras"] dataUsingEncoding:NSUTF8StringEncoding];
            NSError *err;
            NSDictionary *responseDic = [NSJSONSerialization JSONObjectWithData:jsonData options:NSJSONReadingMutableContainers error:&err];
            NSDictionary *opsReceiptProperties = responseDic[@"ops_receipt_properties"];
            if (opsReceiptProperties && [opsReceiptProperties isKindOfClass:[NSDictionary class]]) {
                NSMutableDictionary *dic = [GravityEngineSDK _getAllInstances];
                for (NSString *instanceToken in dic.allKeys) {
                    GravityEngineSDK *instance = dic[instanceToken];
                    [instance track:@"ops_push_click" properties:responseDic];
                    [instance flush];
                }
            }
        }
    } @catch (NSException *exception) {
        
    }
}


+ (GEAppLaunchReason *)sharedInstance {
    static dispatch_once_t onceToken;
    static GEAppLaunchReason *appLaunchManager;
    
    dispatch_once(&onceToken, ^{
        appLaunchManager = [GEAppLaunchReason new];
    });
    
    return appLaunchManager;
}

- (void)clearAppLaunchParams {
    self.appLaunchParams = @{@"url":@"",
                             @"data":@{}};
}

- (void)_applicationDidEnterBackgroundNotification:(NSNotification *)notification {
    [self clearAppLaunchParams];
}

// 拦截冷启动和热启动的参数
- (void)_applicationDidFinishLaunchingNotification:(NSNotification *)notification {
    
    __weak GEAppLaunchReason *weakSelf = self;
    
    NSDictionary *launchOptions = notification.userInfo;
    NSString *url = [self getInitDeeplink:launchOptions];
    NSDictionary *data = [self getInitData:launchOptions];
    
    [GEAppLaunchReason ge_hookUserNotificationCenterMethod];
    
    // 发送推送事件
    if (![GEPresetProperties disableOpsReceiptProperties] && launchOptions) {
        NSDictionary *remoteNotification = [launchOptions objectForKey:@"UIApplicationLaunchOptionsRemoteNotificationKey"];
        [GEAppLaunchReason ge_ops_push_click:remoteNotification];
    }
    
    // 记录冷启动启动原因
    if (![GEPresetProperties disableStartReason]) {
        
        if (!launchOptions) {
            [weakSelf clearAppLaunchParams];
        } else if ([url isKindOfClass:[NSString class]] && url.length) {
            self.appLaunchParams = @{@"url": [GECommonUtil string:url],
                                     @"data": @{}};
        } else {
            self.appLaunchParams = @{@"url": @"",
                                     @"data": [GECommonUtil dictionary:data]};
        }
    }
    
    
    
    UIApplication *application = [GEAppState sharedApplication];
    id applicationDelegate = [application delegate];
    if (applicationDelegate == nil)
    {
        return;
    }
    
 
    // 未开启启动原因
    if ([GEPresetProperties disableStartReason]) return;
    
    // hook 点击推送方法
    NSString *localPushSelString = @"application:didReceiveLocalNotification:";
    [applicationDelegate ta_aspect_hookSelector:NSSelectorFromString(localPushSelString) withOptions:GEAspectPositionAfter usingBlock:^(id<GEAspectInfo> aspectInfo, UIApplication *application ,UILocalNotification *notification) {
        
        BOOL isValidPushClick = NO;
        if (application.applicationState == UIApplicationStateInactive) {
            isValidPushClick = YES;
        }
        if (!isValidPushClick) {
            //            GELogDebug(@"Invalid app push callback, PushClick was ignored.");
            return;
        }
        NSMutableDictionary *properties = [[NSMutableDictionary alloc] init];
        properties[@"alertBody"] = notification.alertBody;
        if (@available(iOS 8.2, *)) {
            properties[@"alertTitle"] = notification.alertTitle;
        }
        [weakSelf clearAppLaunchParams];
        weakSelf.appLaunchParams = @{@"url": @"",
                                     @"data": [GECommonUtil dictionary:properties]};
        
    } error:NULL];
    
    
    NSString *remotePushSelString = @"application:didReceiveRemoteNotification:fetchCompletionHandler:";
    [applicationDelegate ta_aspect_hookSelector:NSSelectorFromString(remotePushSelString) withOptions:GEAspectPositionAfter usingBlock:^(id<GEAspectInfo> aspectInfo, UIApplication *application, NSDictionary *userInfo, id fetchCompletionHandler) {
        
        BOOL isValidPushClick = NO;
        if (application.applicationState == UIApplicationStateInactive) {
            isValidPushClick = YES;
        }
        if (!isValidPushClick) {
            //            GELogDebug(@"Invalid app push callback, PushClick was ignored.");
            return;
        }
        [weakSelf clearAppLaunchParams];
        weakSelf.appLaunchParams = @{@"url": @"",
                                     @"data": [GECommonUtil dictionary:userInfo]};
        
    } error:NULL];
    
    
    
    // hook deeplink回调方法
    NSString *deeplinkStr1 = @"application:handleOpenURL:";// ios(2.0, 9.0)
    [applicationDelegate ta_aspect_hookSelector:NSSelectorFromString(deeplinkStr1) withOptions:GEAspectPositionAfter usingBlock:^(id<GEAspectInfo> aspectInfo, UIApplication *application, NSURL *url) {
        
        [weakSelf clearAppLaunchParams];
        weakSelf.appLaunchParams = @{@"url": [GECommonUtil string:url.absoluteString],
                                     @"data":@{}};
    } error:NULL];
    
    
    
    NSString *deeplinkStr2 = @"application:openURL:options:";// ios(9.0)
    [applicationDelegate ta_aspect_hookSelector:NSSelectorFromString(deeplinkStr2) withOptions:GEAspectPositionAfter usingBlock:^(id<GEAspectInfo> aspectInfo, UIApplication *app, NSURL *url, id options) {
        
        [weakSelf clearAppLaunchParams];
        weakSelf.appLaunchParams = @{@"url": [GECommonUtil string:url.absoluteString],
                                     @"data":@{}};
    } error:NULL];
    
    
    NSString *deeplinkStr3 = @"application:continueUserActivity:restorationHandler:";// ios(8.0)
    [applicationDelegate ta_aspect_hookSelector:NSSelectorFromString(deeplinkStr3) withOptions:GEAspectPositionAfter usingBlock:^(id<GEAspectInfo> aspectInfo, UIApplication *application, NSUserActivity *userActivity, id restorationHandler) {
        
        [weakSelf clearAppLaunchParams];
        weakSelf.appLaunchParams = @{@"url": [GECommonUtil string: userActivity.webpageURL.absoluteString],
                                     @"data":@{}};
    } error:NULL];
    
    
    
    // hook 3d touch回调方法
    if (@available(iOS 9.0, *)) {
        NSString *touch3dSel = @"application:performActionForShortcutItem:completionHandler:";
        [applicationDelegate ta_aspect_hookSelector:NSSelectorFromString(touch3dSel) withOptions:GEAspectPositionAfter usingBlock:^(id<GEAspectInfo> aspectInfo, UIApplication *application, UIApplicationShortcutItem *shortcutItem, id completionHandler) {
            
            [weakSelf clearAppLaunchParams];
            weakSelf.appLaunchParams = @{@"url": @"",
                                         @"data": [GECommonUtil dictionary:shortcutItem.userInfo]};
            
        } error:NULL];
    }
    

#if defined(__IPHONE_13_0) && __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
    // UISceneConfiguration回调方法
    if (@available(iOS 13.0, *)) {
        NSString *connectingSceneSessionSel = @"application:configurationForConnectingSceneSession:options:";
        [applicationDelegate ta_aspect_hookSelector:NSSelectorFromString(connectingSceneSessionSel) withOptions:GEAspectPositionAfter usingBlock:^(id<GEAspectInfo> aspectInfo, UIApplication *application, id connectingSceneSession, id options) {
            
            @try {
                if ([options isKindOfClass:NSClassFromString(@"UISceneConnectionOptions")]) {
                    
                    NSURL *openURL = [[(NSSet *)[options valueForKey:@"URLContexts"] allObjects].lastObject valueForKey:@"URL"];
                    NSURL *userURL = [[(NSSet *)[options valueForKey:@"userActivities"] allObjects].lastObject valueForKey:@"webpageURL"];
                    id response = [options valueForKey:@"notificationResponse"];

                    if (openURL && openURL.absoluteString.length) {
                        [weakSelf clearAppLaunchParams];
                        weakSelf.appLaunchParams = @{@"url": openURL.absoluteString,
                                                     @"data":@{}};
                    } else if (userURL && userURL.absoluteString.length) {
                        [weakSelf clearAppLaunchParams];
                        weakSelf.appLaunchParams = @{@"url": userURL.absoluteString,
                                                     @"data":@{}};
                    }
                    else if (response) {
                        NSDictionary *userInfo = __ge_get_userNotificationCenterResponse(response);
                        NSMutableDictionary *properties = [[NSMutableDictionary alloc] init];
                        if (userInfo) {
                            [properties addEntriesFromDictionary:userInfo];
                        }
                        properties[@"title"] = __ge_get_userNotificationCenterRequestContentTitle(response);
                        properties[@"body"] = __ge_get_userNotificationCenterRequestContentBody(response);

                        [[GEAppLaunchReason sharedInstance] clearAppLaunchParams];
                        [GEAppLaunchReason sharedInstance].appLaunchParams = @{@"url": @"",
                                                                               @"data": [GECommonUtil dictionary:properties]};
                    }
                }
            } @catch (NSException *exception) {}
            
        } error:NULL];
    }
#endif
    
}

#if defined(__IPHONE_13_0) && __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000

- (void)_sceneWillConnectToSession:(id)param {
    
    @try {
        static BOOL isHookconnectedScenes;
        if (isHookconnectedScenes) {
            return;
        }
        
        __weak GEAppLaunchReason *weakSelf = self;
        id scenes = [param valueForKey:@"object"];
        id windowSceneDelegate = [scenes valueForKeyPath:@"delegate"];
        [windowSceneDelegate ta_aspect_hookSelector:NSSelectorFromString(@"scene:continueUserActivity:") withOptions:GEAspectPositionAfter usingBlock:^(id<GEAspectInfo> aspectInfo, id scene ,id userActivity) {
           
            @try {
                if ([userActivity isKindOfClass:NSClassFromString(@"NSUserActivity")]) {
                    NSURL *URL = [(NSUserActivity *)userActivity webpageURL];
                    if (URL && URL.absoluteString) {
                        [weakSelf clearAppLaunchParams];
                        weakSelf.appLaunchParams = @{@"url": URL.absoluteString,
                                                     @"data":@{}};
                    }
                }
            } @catch (NSException *exception) {
                
            }
            
        }  error:NULL];
        
        
        [windowSceneDelegate ta_aspect_hookSelector:NSSelectorFromString(@"scene:openURLContexts:") withOptions:GEAspectPositionAfter usingBlock:^(id<GEAspectInfo> aspectInfo,  id scene ,id urlContexts) {
            
            @try {
                if ([urlContexts isKindOfClass:[NSSet class]]) {
                    NSURL *URL = [[(NSSet *)urlContexts allObjects].lastObject valueForKey:@"URL"];
                    if (URL && URL.absoluteString) {
                        [weakSelf clearAppLaunchParams];
                        weakSelf.appLaunchParams = @{@"url": URL.absoluteString,
                                                     @"data":@{}};
                    }
                }
            } @catch (NSException *exception) {
                
            }
            
        }  error:NULL];
           
        isHookconnectedScenes = YES;
    } @catch (NSException *exception) {
        
    }
  
}

#endif


- (NSString *)getInitDeeplink:(NSDictionary *)launchOptions {
    
    if (!launchOptions || ![launchOptions isKindOfClass:[NSDictionary class]]) {
        return @"";
    }
    
    if ([launchOptions isKindOfClass:[NSDictionary class]] &&
        [launchOptions.allKeys containsObject:UIApplicationLaunchOptionsURLKey]) {
        
        return launchOptions[UIApplicationLaunchOptionsURLKey];
        
    } else if ([launchOptions isKindOfClass:[NSDictionary class]] &&
               [launchOptions.allKeys containsObject:UIApplicationLaunchOptionsUserActivityDictionaryKey]) {
        
        NSDictionary *userActivityDictionary = launchOptions[UIApplicationLaunchOptionsUserActivityDictionaryKey];
        NSString *type = userActivityDictionary[UIApplicationLaunchOptionsUserActivityTypeKey];
        if ([type isEqualToString:NSUserActivityTypeBrowsingWeb]) {
            NSUserActivity *userActivity = userActivityDictionary[@"UIApplicationLaunchOptionsUserActivityKey"];
            return userActivity.webpageURL.absoluteString;
        }
    }
    return @"";
}

- (NSDictionary *)getInitData:(NSDictionary *)launchOptions {
    
    if (!launchOptions || ![launchOptions isKindOfClass:[NSDictionary class]]) {
        return @{};
    }
    
    if ([launchOptions.allKeys containsObject:UIApplicationLaunchOptionsLocalNotificationKey]) {
        // 本地推送可能会解析不出alertbody，这里特殊处理一下
        UILocalNotification *notification = launchOptions[UIApplicationLaunchOptionsLocalNotificationKey];
        NSMutableDictionary *properties = [[NSMutableDictionary alloc] init];
        properties[@"alertBody"] = notification.alertBody;
        if (@available(iOS 8.2, *)) {
            properties[@"alertTitle"] = notification.alertTitle;
        }
        return properties;
    }
    
    return launchOptions;
}

@end
