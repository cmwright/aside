#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs a block inside an Objective-C @try. AVFAudio reports some failures by raising an
/// NSException rather than returning an error, and Swift cannot catch those: uncaught,
/// they abort the process. See ObjCException.swift for the Swift side.
@interface AsideExceptionCatcher : NSObject
+ (nullable NSException *)catchExceptionIn:(void (NS_NOESCAPE ^)(void))block;
@end

NS_ASSUME_NONNULL_END
