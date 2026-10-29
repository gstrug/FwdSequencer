#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs a block and turns an Objective-C exception into an error.
///
/// AVAudioEngine reports a connection it cannot make — an effect that will not take
/// the format it is offered, such as a mono-only guitar amp given stereo — by raising
/// an NSException, which Swift cannot catch and which ends the app on the spot.
@interface FWDExceptionCatcher : NSObject
+ (nullable NSError *)catching:(NS_NOESCAPE void (^)(void))block;
@end

NS_ASSUME_NONNULL_END
