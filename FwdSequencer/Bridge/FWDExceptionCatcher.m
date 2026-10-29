#import "FWDExceptionCatcher.h"

@implementation FWDExceptionCatcher

+ (NSError *)catching:(NS_NOESCAPE void (^)(void))block {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        NSString *reason = exception.reason ?: exception.name;
        return [NSError errorWithDomain:@"FWDException" code:1
                               userInfo:@{NSLocalizedDescriptionKey: reason}];
    }
}

@end
