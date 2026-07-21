// ColorBarView — implementation. Left click a swatch = foreground,
// right click = background. Clicking the fg or bg indicator square opens
// the system color editor targeting that slot (the XP "Edit Colors" flow).
#import "ColorBarView.h"

@interface ColorBarView ()
@property BOOL panelEditsBG;
@end

@implementation ColorBarView

- (BOOL)isFlipped { return YES; }

- (NSRect)indicatorRect { return NSMakeRect(4, 4, 30, 30); }
- (NSRect)fgRect { NSRect i = [self indicatorRect]; return NSMakeRect(i.origin.x, i.origin.y, 18, 18); }
- (NSRect)bgRect { NSRect i = [self indicatorRect]; return NSMakeRect(i.origin.x + 10, i.origin.y + 10, 18, 18); }

- (NSRect)swatchRectCol:(NSInteger)col row:(NSInteger)row {
    return NSMakeRect(44 + col * 18, 3 + row * 17, 16, 15);
}

- (NSRect)transparentSwatchRect { return NSMakeRect(44 + 14 * 18 + 4, 3, 16, 32); }

- (void)drawSwatch:(NSRect)r color:(NSColor *)c {
    if (c.alphaComponent < 0.001) {
        [PCheckerColor() setFill];
        NSRectFill(r);
    } else {
        [c setFill];
        NSRectFill(r);
    }
    [[NSColor separatorColor] setStroke];
    [[NSBezierPath bezierPathWithRect:NSInsetRect(r, 0.5, 0.5)] stroke];
}

- (void)drawRect:(NSRect)dirtyRect {
    [[NSColor windowBackgroundColor] setFill];
    NSRectFill(self.bounds);

    // bg square behind, fg square in front (XP style)
    [self drawSwatch:[self bgRect] color:self.canvas.bg];
    [self drawSwatch:[self fgRect] color:self.canvas.fg];

    for (NSInteger i = 0; i < 28; i++) {
        NSColor *c = [NSColor colorWithSRGBRed:PPalette[i][0] / 255.0
                                         green:PPalette[i][1] / 255.0
                                          blue:PPalette[i][2] / 255.0 alpha:1];
        [self drawSwatch:[self swatchRectCol:(i % 14) row:(i / 14)] color:c];
    }
    [self drawSwatch:[self transparentSwatchRect] color:[NSColor clearColor]];
}

- (NSColor *)colorAtPoint:(NSPoint)p {
    if (NSPointInRect(p, [self transparentSwatchRect])) return [NSColor clearColor];
    for (NSInteger i = 0; i < 28; i++) {
        if (NSPointInRect(p, [self swatchRectCol:(i % 14) row:(i / 14)]))
            return [NSColor colorWithSRGBRed:PPalette[i][0] / 255.0
                                       green:PPalette[i][1] / 255.0
                                        blue:PPalette[i][2] / 255.0 alpha:1];
    }
    return nil;
}

- (void)openPanelForBG:(BOOL)bg {
    self.panelEditsBG = bg;
    NSColorPanel *panel = [NSColorPanel sharedColorPanel];
    panel.showsAlpha = YES;
    panel.color = bg ? self.canvas.bg : self.canvas.fg;
    panel.target = self;
    panel.action = @selector(panelChanged:);
    [panel orderFront:nil];
}

- (void)panelChanged:(NSColorPanel *)panel {
    if (self.panelEditsBG) [self.canvas setBackground:panel.color];
    else [self.canvas setForeground:panel.color];
    [self.canvas setNeedsDisplay:YES];
    [self setNeedsDisplay:YES];
}

- (void)mouseDown:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    // fg square is drawn in front, so it wins the overlap
    if (NSPointInRect(p, [self fgRect])) { [self openPanelForBG:NO]; return; }
    if (NSPointInRect(p, [self bgRect])) { [self openPanelForBG:YES]; return; }
    if (e.clickCount >= 2) { [self openPanelForBG:NO]; return; }
    NSColor *c = [self colorAtPoint:p];
    if (c) {
        [self.canvas setForeground:c];
        [self setNeedsDisplay:YES];
    }
}

- (void)rightMouseDown:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    NSColor *c = [self colorAtPoint:p];
    if (c) {
        [self.canvas setBackground:c];
        [self.canvas setNeedsDisplay:YES];
        [self setNeedsDisplay:YES];
    }
}

@end
