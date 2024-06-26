//
//  GESuperProperty.h
//  GravityEngineSDK
//
//
//  Methods related to static public properties of this class are not thread-safe; methods related to dynamic public properties are thread-safe.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface GESuperProperty : NSObject

#pragma mark - UNAVAILABLE
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

- (instancetype)initWithAppid:(NSString *)appid isLight:(BOOL)isLight;

- (void)registerSuperProperties:(NSDictionary *)properties;

- (void)unregisterSuperProperty:(NSString *)property;

- (void)clearSuperProperties;

- (NSDictionary *)currentSuperProperties;

- (void)registerDynamicSuperProperties:(NSDictionary<NSString *, id> *(^ _Nullable)(void))dynamicSuperProperties;

- (NSDictionary *)obtainDynamicSuperProperties;

@end

NS_ASSUME_NONNULL_END
