
#import "GEAspects.h"
#import <libkern/OSAtomic.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define GEAspectLog(...)
//#define GEAspectLog(...) do { NSLog(__VA_ARGS__); }while(0)
#define GEAspectLogError(...) do { NSLog(__VA_ARGS__); }while(0)

// Block internals.
typedef NS_OPTIONS(int, GEAspectBlockFlags) {
	GEAspectBlockFlagsHasCopyDisposeHelpers = (1 << 25),
	GEAspectBlockFlagsHasSignature          = (1 << 30)
};
typedef struct _GEAspectBlock {
	__unused Class isa;
	GEAspectBlockFlags flags;
	__unused int reserved;
	void (__unused *invoke)(struct _GEAspectBlock *block, ...);
	struct {
		unsigned long int reserved;
		unsigned long int size;
		void (*copy)(void *dst, const void *src);
		void (*dispose)(const void *);
		const char *signature;
		const char *layout;
	} *descriptor;
} *GEAspectBlockRef;

@interface GEAspectInfo : NSObject <GEAspectInfo>
- (id)initWithInstance:(__unsafe_unretained id)instance invocation:(NSInvocation *)invocation;
@property (nonatomic, unsafe_unretained, readonly) id instance;
@property (nonatomic, strong, readonly) NSArray *arguments;
@property (nonatomic, strong, readonly) NSInvocation *originalInvocation;
@end

@interface GEAspectIdentifier : NSObject
+ (instancetype)identifierWithSelector:(SEL)selector object:(id)object options:(GEAspectOptions)options block:(id)block error:(NSError **)error;
- (BOOL)invokeWithInfo:(id<GEAspectInfo>)info;
@property (nonatomic, assign) SEL selector;
@property (nonatomic, strong) id block;
@property (nonatomic, strong) NSMethodSignature *blockSignature;
@property (nonatomic, weak) id object;
@property (nonatomic, assign) GEAspectOptions options;
@end

@interface GEAspectsContainer : NSObject
- (void)addAspect:(GEAspectIdentifier *)aspect withOptions:(GEAspectOptions)injectPosition;
- (BOOL)removeAspect:(id)aspect;
- (BOOL)hasAspects;
@property (atomic, copy) NSArray *beforeAspects;
@property (atomic, copy) NSArray *insteadAspects;
@property (atomic, copy) NSArray *afterAspects;
@end

@interface GEAspectTracker : NSObject
- (id)initWithTrackedClass:(Class)trackedClass;
@property (nonatomic, strong) Class trackedClass;
@property (nonatomic, readonly) NSString *trackedClassName;
@property (nonatomic, strong) NSMutableSet *selectorNames;
@property (nonatomic, strong) NSMutableDictionary *selectorNamesToSubclassTrackers;
- (void)ta_addSubclassTracker:(GEAspectTracker *)subclassTracker hookingSelectorName:(NSString *)selectorName;
- (void)ta_removeSubclassTracker:(GEAspectTracker *)subclassTracker hookingSelectorName:(NSString *)selectorName;
- (BOOL)ta_subclassHasHookedSelectorName:(NSString *)selectorName;
- (NSSet *)ta_subclassTrackersHookingSelectorName:(NSString *)selectorName;
@end

@interface NSInvocation (GEAspects)
- (NSArray *)ta_aspects_arguments;
@end

#define GEAspectPositionFilter 0x07

#define GEAspectError(errorCode, errorDescription) do { \
GEAspectLogError(@"GEAspects: %@", errorDescription); \
if (error) { *error = [NSError errorWithDomain:GEAspectErrorDomain code:errorCode userInfo:@{NSLocalizedDescriptionKey: errorDescription}]; }}while(0)

NSString *const GEAspectErrorDomain = @"GEAspectErrorDomain";
static NSString *const GEAspectsSubclassSuffix = @"GE_Aspects_";
static NSString *const GEAspectsMessagePrefix = @"ge_aspects_";

@implementation NSObject (GEAspects)

#pragma mark - Public Aspects API

+ (id<GEAspectToken>)ta_aspect_hookSelector:(SEL)selector
                      withOptions:(GEAspectOptions)options
                       usingBlock:(id)block
                            error:(NSError **)error {
    return ta_aspect_add((id)self, selector, options, block, error);
}

- (id<GEAspectToken>)ta_aspect_hookSelector:(SEL)selector
                      withOptions:(GEAspectOptions)options
                       usingBlock:(id)block
                            error:(NSError **)error {
    return ta_aspect_add(self, selector, options, block, error);
}

#pragma mark - Private Helper

static id ta_aspect_add(id self, SEL selector, GEAspectOptions options, id block, NSError **error) {
    NSCParameterAssert(self);
    NSCParameterAssert(selector);
    NSCParameterAssert(block);

    __block GEAspectIdentifier *identifier = nil;
    ta_aspect_performLocked(^{
        if (ta_aspect_isSelectorAllowedAndTrack(self, selector, options, error)) {
            GEAspectsContainer *aspectContainer = ta_aspect_getContainerForObject(self, selector);
            identifier = [GEAspectIdentifier identifierWithSelector:selector object:self options:options block:block error:error];
            if (identifier) {
                [aspectContainer addAspect:identifier withOptions:options];

                // Modify the class to allow message interception.
                ta_aspect_prepareClassAndHookSelector(self, selector, error);
            }
        }
    });
    return identifier;
}

static BOOL ta_aspect_remove(GEAspectIdentifier *aspect, NSError **error) {
    NSCAssert([aspect isKindOfClass:GEAspectIdentifier.class], @"Must have correct type.");

    __block BOOL success = NO;
    ta_aspect_performLocked(^{
        id self = aspect.object; // strongify
        if (self) {
            GEAspectsContainer *aspectContainer = ta_aspect_getContainerForObject(self, aspect.selector);
            success = [aspectContainer removeAspect:aspect];

            ta_aspect_cleanupHookedClassAndSelector(self, aspect.selector);
            // destroy token
            aspect.object = nil;
            aspect.block = nil;
            aspect.selector = NULL;
        }else {
//            NSString *errrorDesc = [NSString stringWithFormat:@"Unable to deregister hook. Object already deallocated: %@", aspect];
//            GEAspectError(GEAspectErrorRemoveObjectAlreadyDeallocated, errrorDesc);
        }
    });
    return success;
}

static void ta_aspect_performLocked(dispatch_block_t block) {
    static OSSpinLock aspect_lock = OS_SPINLOCK_INIT;
    OSSpinLockLock(&aspect_lock);
    block();
    OSSpinLockUnlock(&aspect_lock);
}

static SEL ta_aspect_aliasForSelector(SEL selector) {
    NSCParameterAssert(selector);
	return NSSelectorFromString([GEAspectsMessagePrefix stringByAppendingFormat:@"_%@", NSStringFromSelector(selector)]);
}

static NSMethodSignature *ta_aspect_blockMethodSignature(id block, NSError **error) {
    GEAspectBlockRef layout = (__bridge void *)block;
	if (!(layout->flags & GEAspectBlockFlagsHasSignature)) {
        NSString *description = [NSString stringWithFormat:@"The block %@ doesn't contain a type signature.", block];
        GEAspectError(GEAspectErrorMissingBlockSignature, description);
        return nil;
    }
	void *desc = layout->descriptor;
	desc += 2 * sizeof(unsigned long int);
	if (layout->flags & GEAspectBlockFlagsHasCopyDisposeHelpers) {
		desc += 2 * sizeof(void *);
    }
	if (!desc) {
        NSString *description = [NSString stringWithFormat:@"The block %@ doesn't has a type signature.", block];
        GEAspectError(GEAspectErrorMissingBlockSignature, description);
        return nil;
    }
	const char *signature = (*(const char **)desc);
	return [NSMethodSignature signatureWithObjCTypes:signature];
}

static BOOL ta_aspect_isCompatibleBlockSignature(NSMethodSignature *blockSignature, id object, SEL selector, NSError **error) {
    NSCParameterAssert(blockSignature);
    NSCParameterAssert(object);
    NSCParameterAssert(selector);

    BOOL signaturesMatch = YES;
    NSMethodSignature *methodSignature = [[object class] instanceMethodSignatureForSelector:selector];
    if (blockSignature.numberOfArguments > methodSignature.numberOfArguments) {
        signaturesMatch = NO;
    }else {
        if (blockSignature.numberOfArguments > 1) {
            const char *blockType = [blockSignature getArgumentTypeAtIndex:1];
            if (blockType[0] != '@') {
                signaturesMatch = NO;
            }
        }
        // Argument 0 is self/block, argument 1 is SEL or id<GEAspectInfo>. We start comparing at argument 2.
        // The block can have less arguments than the method, that's ok.
        if (signaturesMatch) {
            for (NSUInteger idx = 2; idx < blockSignature.numberOfArguments; idx++) {
                const char *methodType = [methodSignature getArgumentTypeAtIndex:idx];
                const char *blockType = [blockSignature getArgumentTypeAtIndex:idx];
                // Only compare parameter, not the optional type data.
                if (!methodType || !blockType || methodType[0] != blockType[0]) {
                    signaturesMatch = NO; break;
                }
            }
        }
    }

    if (!signaturesMatch) {
        NSString *description = [NSString stringWithFormat:@"Block signature %@ doesn't match %@.", blockSignature, methodSignature];
        GEAspectError(GEAspectErrorIncompatibleBlockSignature, description);
        return NO;
    }
    return YES;
}

#pragma mark - Class + Selector Preparation

static BOOL ta_aspect_isMsgForwardIMP(IMP impl) {
    return impl == _objc_msgForward
#if !defined(__arm64__)
    || impl == (IMP)_objc_msgForward_stret
#endif
    ;
}

static IMP ta_aspect_getMsgForwardIMP(NSObject *self, SEL selector) {
    IMP msgForwardIMP = _objc_msgForward;
#if !defined(__arm64__)
    // As an ugly internal runtime implementation detail in the 32bit runtime, we need to determine of the method we hook returns a struct or anything larger than id.
    // https://developer.apple.com/library/mac/documentation/DeveloperTools/Conceptual/LowLevelABI/000-Introduction/introduction.html
    // https://github.com/ReactiveCocoa/ReactiveCocoa/issues/783
    // http://infocenter.arm.com/help/topic/com.arm.doc.ihi0042e/IHI0042E_aapcs.pdf (Section 5.4)
    Method method = class_getInstanceMethod(self.class, selector);
    const char *encoding = method_getTypeEncoding(method);
    BOOL methodReturnsStructValue = encoding[0] == _C_STRUCT_B;
    if (methodReturnsStructValue) {
        @try {
            NSUInteger valueSize = 0;
            NSGetSizeAndAlignment(encoding, &valueSize, NULL);

            if (valueSize == 1 || valueSize == 2 || valueSize == 4 || valueSize == 8) {
                methodReturnsStructValue = NO;
            }
        } @catch (__unused NSException *e) {}
    }
    if (methodReturnsStructValue) {
        msgForwardIMP = (IMP)_objc_msgForward_stret;
    }
#endif
    return msgForwardIMP;
}

static void ta_aspect_prepareClassAndHookSelector(NSObject *self, SEL selector, NSError **error) {
    NSCParameterAssert(selector);
    Class klass = ta_aspect_hookClass(self, error);
    Method targetMethod = class_getInstanceMethod(klass, selector);
    IMP targetMethodIMP = method_getImplementation(targetMethod);
    if (!ta_aspect_isMsgForwardIMP(targetMethodIMP)) {
        // Make a method alias for the existing method implementation, it not already copied.
        const char *typeEncoding = method_getTypeEncoding(targetMethod);
        SEL aliasSelector = ta_aspect_aliasForSelector(selector);
        if (![klass instancesRespondToSelector:aliasSelector]) {
            __unused BOOL addedAlias = class_addMethod(klass, aliasSelector, method_getImplementation(targetMethod), typeEncoding);
            NSCAssert(addedAlias, @"Original implementation for %@ is already copied to %@ on %@", NSStringFromSelector(selector), NSStringFromSelector(aliasSelector), klass);
        }

        // We use forwardInvocation to hook in.
        class_replaceMethod(klass, selector, ta_aspect_getMsgForwardIMP(self, selector), typeEncoding);
        GEAspectLog(@"GEAspects: Installed hook for -[%@ %@].", klass, NSStringFromSelector(selector));
    }
}

// Will undo the runtime changes made.
static void ta_aspect_cleanupHookedClassAndSelector(NSObject *self, SEL selector) {
    NSCParameterAssert(self);
    NSCParameterAssert(selector);

	Class klass = object_getClass(self);
    BOOL isMetaClass = class_isMetaClass(klass);
    if (isMetaClass) {
        klass = (Class)self;
    }

    // Check if the method is marked as forwarded and undo that.
    Method targetMethod = class_getInstanceMethod(klass, selector);
    IMP targetMethodIMP = method_getImplementation(targetMethod);
    if (ta_aspect_isMsgForwardIMP(targetMethodIMP)) {
        // Restore the original method implementation.
        const char *typeEncoding = method_getTypeEncoding(targetMethod);
        SEL aliasSelector = ta_aspect_aliasForSelector(selector);
        Method originalMethod = class_getInstanceMethod(klass, aliasSelector);
        IMP originalIMP = method_getImplementation(originalMethod);
        NSCAssert(originalMethod, @"Original implementation for %@ not found %@ on %@", NSStringFromSelector(selector), NSStringFromSelector(aliasSelector), klass);

        class_replaceMethod(klass, selector, originalIMP, typeEncoding);
        GEAspectLog(@"GEAspects: Removed hook for -[%@ %@].", klass, NSStringFromSelector(selector));
    }

    // Deregister global tracked selector
    ta_aspect_deregisterTrackedSelector(self, selector);

    // Get the aspect container and check if there are any hooks remaining. Clean up if there are not.
    GEAspectsContainer *container = ta_aspect_getContainerForObject(self, selector);
    if (!container.hasAspects) {
        // Destroy the container
        ta_aspect_destroyContainerForObject(self, selector);

        // Figure out how the class was modified to undo the changes.
        NSString *className = NSStringFromClass(klass);
        if ([className hasSuffix:GEAspectsSubclassSuffix]) {
            Class originalClass = NSClassFromString([className stringByReplacingOccurrencesOfString:GEAspectsSubclassSuffix withString:@""]);
            NSCAssert(originalClass != nil, @"Original class must exist");
            object_setClass(self, originalClass);
            GEAspectLog(@"GEAspects: %@ has been restored.", NSStringFromClass(originalClass));

            // We can only dispose the class pair if we can ensure that no instances exist using our subclass.
            // Since we don't globally track this, we can't ensure this - but there's also not much overhead in keeping it around.
            //objc_disposeClassPair(object.class);
        }else {
            // Class is most likely swizzled in place. Undo that.
            if (isMetaClass) {
                ta_aspect_undoSwizzleClassInPlace((Class)self);
            }else if (self.class != klass) {
            	ta_aspect_undoSwizzleClassInPlace(klass);
            }
        }
    }
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Hook Class

static Class ta_aspect_hookClass(NSObject *self, NSError **error) {
    NSCParameterAssert(self);
	Class statedClass = self.class;
	Class baseClass = object_getClass(self);
	NSString *className = NSStringFromClass(baseClass);

    // Already subclassed
	if ([className hasSuffix:GEAspectsSubclassSuffix]) {
		return baseClass;

        // We swizzle a class object, not a single object.
	}else if (class_isMetaClass(baseClass)) {
        return ta_aspect_swizzleClassInPlace((Class)self);
        // Probably a KVO'ed class. Swizzle in place. Also swizzle meta classes in place.
    }else if (statedClass != baseClass) {
        return ta_aspect_swizzleClassInPlace(baseClass);
    }

    // Default case. Create dynamic subclass.
	const char *subclassName = [className stringByAppendingString:GEAspectsSubclassSuffix].UTF8String;
	Class subclass = objc_getClass(subclassName);

	if (subclass == nil) {
		subclass = objc_allocateClassPair(baseClass, subclassName, 0);
		if (subclass == nil) {
            NSString *errrorDesc = [NSString stringWithFormat:@"objc_allocateClassPair failed to allocate class %s.", subclassName];
            GEAspectError(GEAspectErrorFailedToAllocateClassPair, errrorDesc);
            return nil;
        }

		ta_aspect_swizzleForwardInvocation(subclass);
		ta_aspect_hookedGetClass(subclass, statedClass);
		ta_aspect_hookedGetClass(object_getClass(subclass), statedClass);
		objc_registerClassPair(subclass);
	}

	object_setClass(self, subclass);
	return subclass;
}

static NSString *const GEAspectsForwardInvocationSelectorName = @"_ge_aspects_forwardInvocation:";
static void ta_aspect_swizzleForwardInvocation(Class klass) {
    NSCParameterAssert(klass);
    // If there is no method, replace will act like class_addMethod.
    IMP originalImplementation = class_replaceMethod(klass, @selector(forwardInvocation:), (IMP)__GE_ASPECTS_ARE_BEING_CALLED__, "v@:@");
    if (originalImplementation) {
        class_addMethod(klass, NSSelectorFromString(GEAspectsForwardInvocationSelectorName), originalImplementation, "v@:@");
    }
    GEAspectLog(@"GEAspects: %@ is now aspect aware.", NSStringFromClass(klass));
}

static void ta_aspect_undoSwizzleForwardInvocation(Class klass) {
    NSCParameterAssert(klass);
    Method originalMethod = class_getInstanceMethod(klass, NSSelectorFromString(GEAspectsForwardInvocationSelectorName));
    Method objectMethod = class_getInstanceMethod(NSObject.class, @selector(forwardInvocation:));
    // There is no class_removeMethod, so the best we can do is to retore the original implementation, or use a dummy.
    IMP originalImplementation = method_getImplementation(originalMethod ?: objectMethod);
    class_replaceMethod(klass, @selector(forwardInvocation:), originalImplementation, "v@:@");

    GEAspectLog(@"GEAspects: %@ has been restored.", NSStringFromClass(klass));
}

static void ta_aspect_hookedGetClass(Class class, Class statedClass) {
    NSCParameterAssert(class);
    NSCParameterAssert(statedClass);
	Method method = class_getInstanceMethod(class, @selector(class));
	IMP newIMP = imp_implementationWithBlock(^(id self) {
		return statedClass;
	});
	class_replaceMethod(class, @selector(class), newIMP, method_getTypeEncoding(method));
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Swizzle Class In Place

static void _ge_aspect_modifySwizzledClasses(void (^block)(NSMutableSet *swizzledClasses)) {
    static NSMutableSet *swizzledClasses;
    static dispatch_once_t pred;
    dispatch_once(&pred, ^{
        swizzledClasses = [NSMutableSet new];
    });
    @synchronized(swizzledClasses) {
        block(swizzledClasses);
    }
}

static Class ta_aspect_swizzleClassInPlace(Class klass) {
    NSCParameterAssert(klass);
    NSString *className = NSStringFromClass(klass);

    _ge_aspect_modifySwizzledClasses(^(NSMutableSet *swizzledClasses) {
        if (![swizzledClasses containsObject:className]) {
            ta_aspect_swizzleForwardInvocation(klass);
            [swizzledClasses addObject:className];
        }
    });
    return klass;
}

static void ta_aspect_undoSwizzleClassInPlace(Class klass) {
    NSCParameterAssert(klass);
    NSString *className = NSStringFromClass(klass);

    _ge_aspect_modifySwizzledClasses(^(NSMutableSet *swizzledClasses) {
        if ([swizzledClasses containsObject:className]) {
            ta_aspect_undoSwizzleForwardInvocation(klass);
            [swizzledClasses removeObject:className];
        }
    });
}

// This is a macro so we get a cleaner stack trace.
#define ta_aspect_invoke(aspects, info) \
for (GEAspectIdentifier *aspect in aspects) {\
    [aspect invokeWithInfo:info];\
    if (aspect.options & GEAspectOptionAutomaticRemoval) { \
        aspectsToRemove = [aspectsToRemove?:@[] arrayByAddingObject:aspect]; \
    } \
}

// This is the swizzled forwardInvocation: method.
static void __GE_ASPECTS_ARE_BEING_CALLED__(__unsafe_unretained NSObject *self, SEL selector, NSInvocation *invocation) {
    @try {
        NSCParameterAssert(self);
        NSCParameterAssert(invocation);
        SEL originalSelector = invocation.selector;
        SEL aliasSelector = ta_aspect_aliasForSelector(invocation.selector);
        invocation.selector = aliasSelector;
        GEAspectsContainer *objectContainer = objc_getAssociatedObject(self, aliasSelector);
        GEAspectsContainer *classContainer = ta_aspect_getContainerForClass(object_getClass(self), aliasSelector);
        GEAspectInfo *info = [[GEAspectInfo alloc] initWithInstance:self invocation:invocation];
        NSArray *aspectsToRemove = nil;

        // Before hooks.
        ta_aspect_invoke(classContainer.beforeAspects, info);
        ta_aspect_invoke(objectContainer.beforeAspects, info);

        // Instead hooks.
        BOOL respondsToAlias = YES;
        if (objectContainer.insteadAspects.count || classContainer.insteadAspects.count) {
            ta_aspect_invoke(classContainer.insteadAspects, info);
            ta_aspect_invoke(objectContainer.insteadAspects, info);
        }else {
            Class klass = object_getClass(invocation.target);
            do {
                if ((respondsToAlias = [klass instancesRespondToSelector:aliasSelector])) {
                    @try {
                        [invocation invoke];
                    } @catch (NSException *exception) {
                        NSLog(@" [GravityEngine] %@", exception);
                    }
                    break;
                }
            }while (!respondsToAlias && (klass = class_getSuperclass(klass)));
        }

        // After hooks.
        ta_aspect_invoke(classContainer.afterAspects, info);
        ta_aspect_invoke(objectContainer.afterAspects, info);

        // If no hooks are installed, call original implementation (usually to throw an exception)
        if (!respondsToAlias) {
            invocation.selector = originalSelector;
            SEL originalForwardInvocationSEL = NSSelectorFromString(GEAspectsForwardInvocationSelectorName);
            if ([self respondsToSelector:originalForwardInvocationSEL]) {
                ((void( *)(id, SEL, NSInvocation *))objc_msgSend)(self, originalForwardInvocationSEL, invocation);
            }else {
                [self doesNotRecognizeSelector:invocation.selector];
            }
        }

        // Remove any hooks that are queued for deregistration.
        [aspectsToRemove makeObjectsPerformSelector:@selector(remove)];
    } @catch (NSException *exception) {
        
    }
}
#undef aspect_invoke

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Aspect Container Management

// Loads or creates the aspect container.
static GEAspectsContainer *ta_aspect_getContainerForObject(NSObject *self, SEL selector) {
    NSCParameterAssert(self);
    SEL aliasSelector = ta_aspect_aliasForSelector(selector);
    GEAspectsContainer *aspectContainer = objc_getAssociatedObject(self, aliasSelector);
    if (!aspectContainer) {
        aspectContainer = [GEAspectsContainer new];
        objc_setAssociatedObject(self, aliasSelector, aspectContainer, OBJC_ASSOCIATION_RETAIN);
    }
    return aspectContainer;
}

static GEAspectsContainer *ta_aspect_getContainerForClass(Class klass, SEL selector) {
    NSCParameterAssert(klass);
    GEAspectsContainer *classContainer = nil;
    do {
        classContainer = objc_getAssociatedObject(klass, selector);
        if (classContainer.hasAspects) break;
    }while ((klass = class_getSuperclass(klass)));

    return classContainer;
}

static void ta_aspect_destroyContainerForObject(id<NSObject> self, SEL selector) {
    NSCParameterAssert(self);
    SEL aliasSelector = ta_aspect_aliasForSelector(selector);
    objc_setAssociatedObject(self, aliasSelector, nil, OBJC_ASSOCIATION_RETAIN);
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Selector Blacklist Checking

static NSMutableDictionary *ta_aspect_getSwizzledClassesDict() {
    static NSMutableDictionary *swizzledClassesDict;
    static dispatch_once_t pred;
    dispatch_once(&pred, ^{
        swizzledClassesDict = [NSMutableDictionary new];
    });
    return swizzledClassesDict;
}

static BOOL ta_aspect_isSelectorAllowedAndTrack(NSObject *self, SEL selector, GEAspectOptions options, NSError **error) {
    static NSSet *disallowedSelectorList;
    static dispatch_once_t pred;
    dispatch_once(&pred, ^{
        disallowedSelectorList = [NSSet setWithObjects:@"retain", @"release", @"autorelease", @"forwardInvocation:", nil];
    });

    // Check against the blacklist.
    NSString *selectorName = NSStringFromSelector(selector);
    if ([disallowedSelectorList containsObject:selectorName]) {
        NSString *errorDescription = [NSString stringWithFormat:@"Selector %@ is blacklisted.", selectorName];
        GEAspectError(GEAspectErrorSelectorBlacklisted, errorDescription);
        return NO;
    }

    // Additional checks.
    GEAspectOptions position = options&GEAspectPositionFilter;
    if ([selectorName isEqualToString:@"dealloc"] && position != GEAspectPositionBefore) {
        NSString *errorDesc = @"GEAspectPositionBefore is the only valid position when hooking dealloc.";
        GEAspectError(GEAspectErrorSelectorDeallocPosition, errorDesc);
        return NO;
    }

    if (![self respondsToSelector:selector] && ![self.class instancesRespondToSelector:selector]) {
        NSString *errorDesc = [NSString stringWithFormat:@"Unable to find selector -[%@ %@].", NSStringFromClass(self.class), selectorName];
        GEAspectError(GEAspectErrorDoesNotRespondToSelector, errorDesc);
        return NO;
    }

    // Search for the current class and the class hierarchy IF we are modifying a class object
    if (class_isMetaClass(object_getClass(self))) {
        Class klass = [self class];
        NSMutableDictionary *swizzledClassesDict = ta_aspect_getSwizzledClassesDict();
        Class currentClass = [self class];

        GEAspectTracker *tracker = swizzledClassesDict[currentClass];
        if ([tracker ta_subclassHasHookedSelectorName:selectorName]) {
            NSSet *subclassTracker = [tracker ta_subclassTrackersHookingSelectorName:selectorName];
            NSSet *subclassNames = [subclassTracker valueForKey:@"trackedClassName"];
            NSString *errorDescription = [NSString stringWithFormat:@"Error: %@ already hooked subclasses: %@. A method can only be hooked once per class hierarchy.", selectorName, subclassNames];
            GEAspectError(GEAspectErrorSelectorAlreadyHookedInClassHierarchy, errorDescription);
            return NO;
        }

        do {
            tracker = swizzledClassesDict[currentClass];
            if ([tracker.selectorNames containsObject:selectorName]) {
                if (klass == currentClass) {
                    // Already modified and topmost!
                    return YES;
                }
                NSString *errorDescription = [NSString stringWithFormat:@"Error: %@ already hooked in %@. A method can only be hooked once per class hierarchy.", selectorName, NSStringFromClass(currentClass)];
                GEAspectError(GEAspectErrorSelectorAlreadyHookedInClassHierarchy, errorDescription);
                return NO;
            }
        } while ((currentClass = class_getSuperclass(currentClass)));

        // Add the selector as being modified.
        currentClass = klass;
        GEAspectTracker *subclassTracker = nil;
        do {
            tracker = swizzledClassesDict[currentClass];
            if (!tracker) {
                tracker = [[GEAspectTracker alloc] initWithTrackedClass:currentClass];
                swizzledClassesDict[(id<NSCopying>)currentClass] = tracker;
            }
            if (subclassTracker) {
                [tracker ta_addSubclassTracker:subclassTracker hookingSelectorName:selectorName];
            } else {
                [tracker.selectorNames addObject:selectorName];
            }

            // All superclasses get marked as having a subclass that is modified.
            subclassTracker = tracker;
        }while ((currentClass = class_getSuperclass(currentClass)));
	} else {
		return YES;
	}

    return YES;
}

static void ta_aspect_deregisterTrackedSelector(id self, SEL selector) {
    if (!class_isMetaClass(object_getClass(self))) return;

    NSMutableDictionary *swizzledClassesDict = ta_aspect_getSwizzledClassesDict();
    NSString *selectorName = NSStringFromSelector(selector);
    Class currentClass = [self class];
    GEAspectTracker *subclassTracker = nil;
    do {
        GEAspectTracker *tracker = swizzledClassesDict[currentClass];
        if (subclassTracker) {
            [tracker ta_removeSubclassTracker:subclassTracker hookingSelectorName:selectorName];
        } else {
            [tracker.selectorNames removeObject:selectorName];
        }
        if (tracker.selectorNames.count == 0 && tracker.selectorNamesToSubclassTrackers) {
            [swizzledClassesDict removeObjectForKey:currentClass];
        }
        subclassTracker = tracker;
    }while ((currentClass = class_getSuperclass(currentClass)));
}

@end

@implementation GEAspectTracker

- (id)initWithTrackedClass:(Class)trackedClass {
    if (self = [super init]) {
        _trackedClass = trackedClass;
        _selectorNames = [NSMutableSet new];
        _selectorNamesToSubclassTrackers = [NSMutableDictionary new];
    }
    return self;
}

- (BOOL)ta_subclassHasHookedSelectorName:(NSString *)selectorName {
    return self.selectorNamesToSubclassTrackers[selectorName] != nil;
}

- (void)ta_addSubclassTracker:(GEAspectTracker *)subclassTracker hookingSelectorName:(NSString *)selectorName {
    NSMutableSet *trackerSet = self.selectorNamesToSubclassTrackers[selectorName];
    if (!trackerSet) {
        trackerSet = [NSMutableSet new];
        self.selectorNamesToSubclassTrackers[selectorName] = trackerSet;
    }
    [trackerSet addObject:subclassTracker];
}
- (void)ta_removeSubclassTracker:(GEAspectTracker *)subclassTracker hookingSelectorName:(NSString *)selectorName {
    NSMutableSet *trackerSet = self.selectorNamesToSubclassTrackers[selectorName];
    [trackerSet removeObject:subclassTracker];
    if (trackerSet.count == 0) {
        [self.selectorNamesToSubclassTrackers removeObjectForKey:selectorName];
    }
}
- (NSSet *)ta_subclassTrackersHookingSelectorName:(NSString *)selectorName {
    NSMutableSet *hookingSubclassTrackers = [NSMutableSet new];
    for (GEAspectTracker *tracker in self.selectorNamesToSubclassTrackers[selectorName]) {
        if ([tracker.selectorNames containsObject:selectorName]) {
            [hookingSubclassTrackers addObject:tracker];
        }
        [hookingSubclassTrackers unionSet:[tracker ta_subclassTrackersHookingSelectorName:selectorName]];
    }
    return hookingSubclassTrackers;
}
- (NSString *)trackedClassName {
    return NSStringFromClass(self.trackedClass);
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %@, trackedClass: %@, selectorNames:%@, subclass selector names: %@>", self.class, self, NSStringFromClass(self.trackedClass), self.selectorNames, self.selectorNamesToSubclassTrackers.allKeys];
}

@end

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - NSInvocation (GEAspects)

@implementation NSInvocation (GEAspects)

// Thanks to the ReactiveCocoa team for providing a generic solution for this.
- (id)ta_aspect_argumentAtIndex:(NSUInteger)index {
	const char *argType = [self.methodSignature getArgumentTypeAtIndex:index];
	// Skip const type qualifier.
	if (argType[0] == _C_CONST) argType++;

#define WRAP_AND_RETURN(type) do { type val = 0; [self getArgument:&val atIndex:(NSInteger)index]; return @(val); } while (0)
	if (strcmp(argType, @encode(id)) == 0 || strcmp(argType, @encode(Class)) == 0) {
		__autoreleasing id returnObj;
		[self getArgument:&returnObj atIndex:(NSInteger)index];
		return returnObj;
	} else if (strcmp(argType, @encode(SEL)) == 0) {
        SEL selector = 0;
        [self getArgument:&selector atIndex:(NSInteger)index];
        return NSStringFromSelector(selector);
    } else if (strcmp(argType, @encode(Class)) == 0) {
        __autoreleasing Class theClass = Nil;
        [self getArgument:&theClass atIndex:(NSInteger)index];
        return theClass;
        // Using this list will box the number with the appropriate constructor, instead of the generic NSValue.
	} else if (strcmp(argType, @encode(char)) == 0) {
		WRAP_AND_RETURN(char);
	} else if (strcmp(argType, @encode(int)) == 0) {
		WRAP_AND_RETURN(int);
	} else if (strcmp(argType, @encode(short)) == 0) {
		WRAP_AND_RETURN(short);
	} else if (strcmp(argType, @encode(long)) == 0) {
		WRAP_AND_RETURN(long);
	} else if (strcmp(argType, @encode(long long)) == 0) {
		WRAP_AND_RETURN(long long);
	} else if (strcmp(argType, @encode(unsigned char)) == 0) {
		WRAP_AND_RETURN(unsigned char);
	} else if (strcmp(argType, @encode(unsigned int)) == 0) {
		WRAP_AND_RETURN(unsigned int);
	} else if (strcmp(argType, @encode(unsigned short)) == 0) {
		WRAP_AND_RETURN(unsigned short);
	} else if (strcmp(argType, @encode(unsigned long)) == 0) {
		WRAP_AND_RETURN(unsigned long);
	} else if (strcmp(argType, @encode(unsigned long long)) == 0) {
		WRAP_AND_RETURN(unsigned long long);
	} else if (strcmp(argType, @encode(float)) == 0) {
		WRAP_AND_RETURN(float);
	} else if (strcmp(argType, @encode(double)) == 0) {
		WRAP_AND_RETURN(double);
	} else if (strcmp(argType, @encode(BOOL)) == 0) {
		WRAP_AND_RETURN(BOOL);
	} else if (strcmp(argType, @encode(bool)) == 0) {
		WRAP_AND_RETURN(BOOL);
	} else if (strcmp(argType, @encode(char *)) == 0) {
		WRAP_AND_RETURN(const char *);
	} else if (strcmp(argType, @encode(void (^)(void))) == 0) {
		__unsafe_unretained id block = nil;
		[self getArgument:&block atIndex:(NSInteger)index];
		return [block copy];
	} else {
		NSUInteger valueSize = 0;
		NSGetSizeAndAlignment(argType, &valueSize, NULL);

		unsigned char valueBytes[valueSize];
		[self getArgument:valueBytes atIndex:(NSInteger)index];

		return [NSValue valueWithBytes:valueBytes objCType:argType];
	}
	return nil;
#undef WRAP_AND_RETURN
}

- (NSArray *)ta_aspects_arguments {
	NSMutableArray *argumentsArray = [NSMutableArray array];
	for (NSUInteger idx = 2; idx < self.methodSignature.numberOfArguments; idx++) {
		[argumentsArray addObject:[self ta_aspect_argumentAtIndex:idx] ?: NSNull.null];
	}
	return [argumentsArray copy];
}

@end

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - GEAspectIdentifier

@implementation GEAspectIdentifier

+ (instancetype)identifierWithSelector:(SEL)selector object:(id)object options:(GEAspectOptions)options block:(id)block error:(NSError **)error {
    NSCParameterAssert(block);
    NSCParameterAssert(selector);
    NSMethodSignature *blockSignature = ta_aspect_blockMethodSignature(block, error); // TODO: check signature compatibility, etc.
    if (!ta_aspect_isCompatibleBlockSignature(blockSignature, object, selector, error)) {
        return nil;
    }

    GEAspectIdentifier *identifier = nil;
    if (blockSignature) {
        identifier = [GEAspectIdentifier new];
        identifier.selector = selector;
        identifier.block = block;
        identifier.blockSignature = blockSignature;
        identifier.options = options;
        identifier.object = object; // weak
    }
    return identifier;
}

- (BOOL)invokeWithInfo:(id<GEAspectInfo>)info {

    NSInvocation *blockInvocation = [NSInvocation invocationWithMethodSignature:self.blockSignature];
    NSInvocation *originalInvocation = info.originalInvocation;
    NSUInteger numberOfArguments = self.blockSignature.numberOfArguments;

    // Be extra paranoid. We already check that on hook registration.
    if (numberOfArguments > originalInvocation.methodSignature.numberOfArguments) {
        GEAspectLogError(@"Block has too many arguments. Not calling %@", info);
        return NO;
    }

    // The `self` of the block will be the GEAspectInfo. Optional.
    @try {
        if (numberOfArguments > 1) {
            [blockInvocation setArgument:&info atIndex:1];
        }
    } @catch (NSException *exception) {
        
    }
    
    
	void *argBuf = NULL;
    for (NSUInteger idx = 2; idx < numberOfArguments; idx++) {
        const char *type = [originalInvocation.methodSignature getArgumentTypeAtIndex:idx];
		NSUInteger argSize;
		NSGetSizeAndAlignment(type, &argSize, NULL);
        
		if (!(argBuf = reallocf(argBuf, argSize))) {
            GEAspectLogError(@"Failed to allocate memory for block invocation.");
			return NO;
		}
        
        @try {
            [originalInvocation getArgument:argBuf atIndex:idx];
            [blockInvocation setArgument:argBuf atIndex:idx];
        } @catch (NSException *exception) {
            
        }
    }
    
    @try {
        [blockInvocation invokeWithTarget:self.block];
    } @catch (NSException *exception) {
        
    }
    
    if (argBuf != NULL) {
        free(argBuf);
    }
    return YES;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %p, SEL:%@ object:%@ options:%tu block:%@ (#%tu args)>", self.class, self, NSStringFromSelector(self.selector), self.object, self.options, self.block, self.blockSignature.numberOfArguments];
}

- (BOOL)remove {
    return ta_aspect_remove(self, NULL);
}

@end

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - GEAspectsContainer

@implementation GEAspectsContainer

- (BOOL)hasAspects {
    return self.beforeAspects.count > 0 || self.insteadAspects.count > 0 || self.afterAspects.count > 0;
}

- (void)addAspect:(GEAspectIdentifier *)aspect withOptions:(GEAspectOptions)options {
    NSParameterAssert(aspect);
    NSUInteger position = options&GEAspectPositionFilter;
    switch (position) {
        case GEAspectPositionBefore:  self.beforeAspects  = [(self.beforeAspects ?:@[]) arrayByAddingObject:aspect]; break;
        case GEAspectPositionInstead: self.insteadAspects = [(self.insteadAspects?:@[]) arrayByAddingObject:aspect]; break;
        case GEAspectPositionAfter:   self.afterAspects   = [(self.afterAspects  ?:@[]) arrayByAddingObject:aspect]; break;
    }
}

- (BOOL)removeAspect:(id)aspect {
    for (NSString *aspectArrayName in @[NSStringFromSelector(@selector(beforeAspects)),
                                        NSStringFromSelector(@selector(insteadAspects)),
                                        NSStringFromSelector(@selector(afterAspects))]) {
        NSArray *array = [self valueForKey:aspectArrayName];
        NSUInteger index = [array indexOfObjectIdenticalTo:aspect];
        if (array && index != NSNotFound) {
            NSMutableArray *newArray = [NSMutableArray arrayWithArray:array];
            [newArray removeObjectAtIndex:index];
            [self setValue:newArray forKey:aspectArrayName];
            return YES;
        }
    }
    return NO;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %p, before:%@, instead:%@, after:%@>", self.class, self, self.beforeAspects, self.insteadAspects, self.afterAspects];
}

@end

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - GEAspectInfo

@implementation GEAspectInfo

@synthesize arguments = _arguments;

- (id)initWithInstance:(__unsafe_unretained id)instance invocation:(NSInvocation *)invocation {
    NSCParameterAssert(instance);
    NSCParameterAssert(invocation);
    if (self = [super init]) {
        _instance = instance;
        _originalInvocation = invocation;
    }
    return self;
}

- (NSArray *)arguments {
    // Lazily evaluate arguments, boxing is expensive.
    if (!_arguments) {
        _arguments = self.originalInvocation.ta_aspects_arguments;
    }
    return _arguments;
}

@end
