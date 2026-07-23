#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>

NS_ASSUME_NONNULL_BEGIN

/// Bridges requestViewControllerWithCompletionHandler to Swift.
/// The Swift SDK incorrectly marks this API_UNAVAILABLE(ios) but it works fine at runtime.
@interface AUViewControllerHelper : NSObject
+ (void)requestViewControllerForUnit:(AUAudioUnit *)audioUnit
                   completionHandler:(void (^)(UIViewController * _Nullable viewController))handler;
@end

NS_ASSUME_NONNULL_END
