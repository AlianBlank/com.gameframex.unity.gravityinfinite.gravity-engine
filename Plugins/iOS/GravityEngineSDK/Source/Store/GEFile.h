//
//  GEFile.h
//  GravityEngineSDK
//
//  Copyright © 2020 gravityengine. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface GEFile : NSObject

@property(strong,nonatomic) NSString* appid;

- (instancetype)initWithAppid:(NSString*)appid;

- (void)archiveSessionID:(long long)sessionid;
- (long long)unarchiveSessionID ;

- (void)archiveIdentifyId:(nullable NSString *)identifyId;
- (NSString*)unarchiveIdentifyID ;

- (void)archiveAccountID:(nullable NSString *)accountID;
- (NSString*)unarchiveAccountID ;

- (void)archiveUploadSize:(NSNumber *)uploadSize;
- (NSNumber*)unarchiveUploadSize;

- (void)archiveUploadInterval:(NSNumber *)uploadInterval;
- (NSNumber*)unarchiveUploadInterval;


- (void)archiveSuperProperties:(nullable NSDictionary *)superProperties;
- (NSDictionary*)unarchiveSuperProperties;

- (void)archiveTrackPause:(BOOL)trackPause;
- (BOOL)unarchiveTrackPause;

- (void)archiveOptOut:(BOOL)optOut;
- (BOOL)unarchiveOptOut;

- (void)archiveIsEnabled:(BOOL)isEnabled;
- (BOOL)unarchiveEnabled;

- (void)archiveDeviceId:(NSString *)deviceId;
- (NSString *)unarchiveDeviceId;

- (void)archiveInstallTimes:(NSString *)installTimes;
- (NSString *)unarchiveInstallTimes;

- (void)archiveUserAgent:(NSString *)userAgent;
- (NSString *)unarchiveUserAgent;

- (void)archiveClientId:(nullable NSString *)clientId;
- (NSString *)unarchiveClientId;

- (BOOL)archiveObject:(id)object withFilePath:(NSString *)filePath;

- (BOOL)addSkipBackupAttributeToItemAtPath:(NSString *)filePathString;

- (NSString *)description;

@end;

NS_ASSUME_NONNULL_END
