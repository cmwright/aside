#import "ExceptionCatcher.h"

@implementation AsideExceptionCatcher

+ (NSException *)catchExceptionIn:(void (NS_NOESCAPE ^)(void))block {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return exception;
    }
}

@end
