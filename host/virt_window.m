#import <Cocoa/Cocoa.h>
#import <QuartzCore/CAMetalLayer.h>
#include "virt_window.h"
#include "vm.h"

/* macOS virtual key codes (kVK_*) to USB HID keyboard usages. */
static const uint8_t hid_of[128] = {
    [0x00] = 0x04, [0x01] = 0x16, [0x02] = 0x07, [0x03] = 0x09, [0x04] = 0x0b, [0x05] = 0x0a, [0x06] = 0x1d, [0x07] = 0x1b,
    [0x08] = 0x06, [0x09] = 0x19, [0x0a] = 0x64, [0x0b] = 0x05, [0x0c] = 0x14, [0x0d] = 0x1a, [0x0e] = 0x08, [0x0f] = 0x15,
    [0x10] = 0x1c, [0x11] = 0x17, [0x12] = 0x1e, [0x13] = 0x1f, [0x14] = 0x20, [0x15] = 0x21, [0x16] = 0x23, [0x17] = 0x22,
    [0x18] = 0x2e, [0x19] = 0x26, [0x1a] = 0x24, [0x1b] = 0x2d, [0x1c] = 0x25, [0x1d] = 0x27, [0x1e] = 0x30, [0x1f] = 0x12,
    [0x20] = 0x18, [0x21] = 0x2f, [0x22] = 0x0c, [0x23] = 0x13, [0x24] = 0x28, [0x25] = 0x0f, [0x26] = 0x0d, [0x27] = 0x34,
    [0x28] = 0x0e, [0x29] = 0x33, [0x2a] = 0x31, [0x2b] = 0x36, [0x2c] = 0x38, [0x2d] = 0x11, [0x2e] = 0x10, [0x2f] = 0x37,
    [0x30] = 0x2b, [0x31] = 0x2c, [0x32] = 0x35, [0x33] = 0x2a, [0x35] = 0x29, [0x36] = 0xe7, [0x37] = 0xe3, [0x38] = 0xe1,
    [0x39] = 0x39, [0x3a] = 0xe2, [0x3b] = 0xe0, [0x3c] = 0xe5, [0x3d] = 0xe6, [0x3e] = 0xe4,
    [0x60] = 0x3e, [0x61] = 0x3f, [0x62] = 0x40, [0x63] = 0x3c, [0x64] = 0x41, [0x65] = 0x42, [0x67] = 0x44, [0x6d] = 0x43,
    [0x6f] = 0x45, [0x73] = 0x4a, [0x74] = 0x4b, [0x75] = 0x4c, [0x76] = 0x3d, [0x77] = 0x4d, [0x78] = 0x3b, [0x79] = 0x4e,
    [0x7a] = 0x3a, [0x7b] = 0x50, [0x7c] = 0x4f, [0x7d] = 0x51, [0x7e] = 0x52,
};

static void key(uint16_t mac, int down) {
    if (mac < 128 && hid_of[mac]) hv_vm_key_hid(hid_of[mac], down);
}

@interface VWView : NSView
@property BOOL captured;
@end

@implementation VWView {
    NSUInteger held; /* bit per modifier key code, to tell presses from releases */
    CAMetalLayer *screen;
}
- (instancetype)initWithFrame:(NSRect)f layer:(CAMetalLayer *)l {
    if ((self = [super initWithFrame:f])) screen = l;
    return self;
}
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)wantsUpdateLayer { return YES; }
- (CALayer *)makeBackingLayer { return screen; }

- (void)setCapture:(BOOL)on {
    if (on == self.captured) return;
    self.captured = on;
    CGAssociateMouseAndMouseCursorPosition(!on);
    if (on) {
        [NSCursor hide];
        NSRect r = [self.window convertRectToScreen:[self convertRect:self.bounds toView:nil]];
        CGFloat top = NSScreen.screens.firstObject.frame.size.height;
        CGWarpMouseCursorPosition(CGPointMake(NSMidX(r), top - NSMidY(r)));
    } else {
        [NSCursor unhide];
    }
    self.window.title = on ? @"HengeVM Linux — press Control+Option to release the mouse" : @"HengeVM Linux — click to use the mouse";
}

- (void)keyDown:(NSEvent *)e { if (!e.isARepeat) key(e.keyCode, 1); }
- (void)keyUp:(NSEvent *)e { key(e.keyCode, 0); }
- (void)flagsChanged:(NSEvent *)e {
    uint16_t k = e.keyCode;
    if (k == 0x39) { /* Caps Lock reports each toggle: tap it */
        key(k, 1);
        key(k, 0);
    } else if (k < 64) {
        NSUInteger bit = (NSUInteger)1 << k;
        int down = !(held & bit);
        held ^= bit;
        key(k, down);
    }
    NSEventModifierFlags f = e.modifierFlags;
    if (self.captured && (f & NSEventModifierFlagControl) && (f & NSEventModifierFlagOption)) {
        for (uint16_t mk = 0x3a; mk <= 0x3e; mk++) /* so the guest does not keep them down */
            if (held & ((NSUInteger)1 << mk)) {
                held &= ~((NSUInteger)1 << mk);
                key(mk, 0);
            }
        [self setCapture:NO];
    }
}

- (void)moved:(NSEvent *)e {
    if (!self.captured) return;
    int dx = (int)lround(e.deltaX), dy = (int)lround(e.deltaY);
    if (dx || dy) hv_vm_mouse_move(dx, dy);
}
- (void)mouseMoved:(NSEvent *)e { [self moved:e]; }
- (void)mouseDragged:(NSEvent *)e { [self moved:e]; }
- (void)rightMouseDragged:(NSEvent *)e { [self moved:e]; }
- (void)otherMouseDragged:(NSEvent *)e { [self moved:e]; }
- (void)mouseDown:(NSEvent *)e {
    if (!self.captured) { /* the first click only takes the mouse */
        [self setCapture:YES];
        return;
    }
    hv_vm_mouse_button(0, 1);
}
- (void)mouseUp:(NSEvent *)e { if (self.captured) hv_vm_mouse_button(0, 0); }
- (void)rightMouseDown:(NSEvent *)e { if (self.captured) hv_vm_mouse_button(1, 1); }
- (void)rightMouseUp:(NSEvent *)e { if (self.captured) hv_vm_mouse_button(1, 0); }
- (void)otherMouseDown:(NSEvent *)e { if (self.captured) hv_vm_mouse_button(2, 1); }
- (void)otherMouseUp:(NSEvent *)e { if (self.captured) hv_vm_mouse_button(2, 0); }
- (void)scrollWheel:(NSEvent *)e {
    if (!self.captured) return;
    static double acc_y, acc_x; /* trackpads give fine deltas: gather whole steps */
    acc_y += e.hasPreciseScrollingDeltas ? e.scrollingDeltaY / 10.0 : e.scrollingDeltaY;
    acc_x += e.hasPreciseScrollingDeltas ? e.scrollingDeltaX / 10.0 : e.scrollingDeltaX;
    int sy = (int)acc_y, sx = (int)acc_x;
    acc_y -= sy;
    acc_x -= sx;
    if (sy) hv_vm_mouse_wheel(sy);
    if (sx) hv_vm_mouse_hwheel(-sx);
}
@end

@interface VWDelegate : NSObject <NSWindowDelegate>
@end
@implementation VWDelegate
- (void)windowDidResignKey:(NSNotification *)n { [(VWView *)((NSWindow *)n.object).contentView setCapture:NO]; }
- (void)windowWillClose:(NSNotification *)n {
    (void)n;
    exit(0);
}
@end

void hv_virt_window_run(unsigned width, unsigned height) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        CAMetalLayer *layer = [CAMetalLayer layer];
        layer.backgroundColor = CGColorGetConstantColor(kCGColorBlack); /* the letterbox */
        layer.contentsGravity = kCAGravityResizeAspect;
        NSRect frame = NSMakeRect(0, 0, width / 2.0, height / 2.0); /* 1:1 on a Retina screen */
        NSWindow *w = [[NSWindow alloc] initWithContentRect:frame
                                                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                            NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
        VWView *v = [[VWView alloc] initWithFrame:frame layer:layer];
        v.wantsLayer = YES;
        w.contentView = v;
        w.contentAspectRatio = NSMakeSize(width, height);
        w.acceptsMouseMovedEvents = YES;
        static VWDelegate *delegate;
        delegate = [VWDelegate new];
        w.delegate = delegate;
        w.title = @"HengeVM Linux — click to use the mouse";
        [w center];
        [w makeKeyAndOrderFront:nil];
        [w makeFirstResponder:v];
        hv_vm_set_display_layer((__bridge void *)layer);
        [app activateIgnoringOtherApps:YES];
        [app run];
    }
}
