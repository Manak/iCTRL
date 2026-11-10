#import <Foundation/Foundation.h>
#import <objc/message.h>

// Adds an element's state to its line in iCTRL's UI tree text.
//
// iCTRL prints type, label, value, identifier and frame. The accessibility
// snapshot also knows whether the element is enabled and selected, which is
// what tells a greyed-out button from a live one and the active tab from the
// others. Only the non-default states are printed (", disabled" and
// ", selected"), just before the frame, so the frame stays last on the line.
//
// Called from one hook in iCTRLUITests/ForegroundApp.m.

static BOOL ClaudeBridgeBoolValue(id node, NSString *first, NSString *second, BOOL fallback) {
    for (NSString *name in @[first, second]) {
        SEL selector = NSSelectorFromString(name);
        if ([node respondsToSelector:selector]) {
            BOOL (*call)(id, SEL) = (BOOL (*)(id, SEL))objc_msgSend;
            return call(node, selector);
        }
    }
    return fallback;
}

void ClaudeBridgeAppendState(NSMutableString *line, id node) {
    if (line == nil || node == nil) { return; }
    @try {
        BOOL enabled = ClaudeBridgeBoolValue(node, @"isEnabled", @"enabled", YES);
        BOOL selected = ClaudeBridgeBoolValue(node, @"isSelected", @"selected", NO);
        if (enabled && !selected) { return; }
        NSMutableString *state = [NSMutableString string];
        if (!enabled) { [state appendString:@", disabled"]; }
        if (selected) { [state appendString:@", selected"]; }
        // The frame is the last ", {{…}}" on the line.
        NSRange frame = [line rangeOfString:@", {{" options:NSBackwardsSearch];
        if (frame.location == NSNotFound) { return; }
        [line insertString:state atIndex:frame.location];
    } @catch (__unused NSException *e) {}
}
