#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface GEJSONUtil : NSObject

+ (NSString *)JSONStringForObject:(id)object;

+ (NSData *)JSONSerializeForObject:(id)object;

@end

NS_ASSUME_NONNULL_END
