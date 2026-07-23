#import "AUViewControllerHelper.h"

// Re-declare the selector that AudioToolbox marks API_UNAVAILABLE(ios) so the
// compiler can resolve it. The implementation is present at runtime on iOS.
@interface AUAudioUnit (ViewControllerBridge)
- (void)requestViewControllerWithCompletionHandler:(void (^)(UIViewController * _Nullable))completionHandler;
@end

@implementation AUViewControllerHelper

+ (void)requestViewControllerForUnit:(AUAudioUnit *)audioUnit
                   completionHandler:(void (^)(UIViewController * _Nullable))handler {
    [audioUnit requestViewControllerWithCompletionHandler:handler];
}

@end
