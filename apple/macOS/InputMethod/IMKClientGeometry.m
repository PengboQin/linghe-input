#import "IMKClientGeometry.h"
#import <InputMethodKit/InputMethodKit.h>
#import <math.h>
static BOOL valid(NSRect r) {
    return isfinite(r.origin.x) && isfinite(r.origin.y) && isfinite(r.size.width) && isfinite(r.size.height) && fabs(r.size.height)>=1 && fabs(r.size.height)<=512 && fabs(r.size.width)<=2048 && !(r.origin.x==0 && r.origin.y==0);
}
BOOL PIReadIMKCaret(id client, NSRect *rectangle) {
    *rectangle=NSZeroRect;
    if (!client) return NO;
    @try {
        if ([client respondsToSelector:@selector(attributesForCharacterIndex:lineHeightRectangle:)]) {
            NSRect r=NSZeroRect;
            // IMK indices are relative to the marked session. Zero is the
            // compatible insertion anchor, not the document/preedit end.
            [(id<IMKTextInput>)client attributesForCharacterIndex:0 lineHeightRectangle:&r];
            if(valid(r)) {*rectangle=CGRectStandardize(r);return YES;}
        }
        if ([client respondsToSelector:@selector(firstRectForCharacterRange:actualRange:)]) {
            NSRange range=[(id<IMKTextInput>)client markedRange];
            if(range.location==NSNotFound) range=[(id<IMKTextInput>)client selectedRange];
            if(range.location!=NSNotFound) {
                NSRect r=[(id<IMKTextInput>)client firstRectForCharacterRange:NSMakeRange(range.location,0) actualRange:NULL];
                if(valid(r)) {*rectangle=CGRectStandardize(r);return YES;}
            }
        }
    } @catch (__unused NSException *exception) { *rectangle=NSZeroRect; }
    return NO;
}
