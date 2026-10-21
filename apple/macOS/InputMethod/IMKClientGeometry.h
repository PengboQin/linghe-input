#import <AppKit/AppKit.h>
NS_ASSUME_NONNULL_BEGIN
/// Public IMK geometry only; an unsupported/throwing host is an ordinary miss.
BOOL PIReadIMKCaret(id client, NSRect *rectangle);
NS_ASSUME_NONNULL_END
