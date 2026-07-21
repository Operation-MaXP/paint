// OptionsView — implementation. Rows are drawn and hit-tested directly,
// XP style. Shape tools show fill mode (3 rows) plus line width (5 rows).
#import "OptionsView.h"

static const NSInteger PBrushSizes[4]  = {1, 3, 5, 8};
static const NSInteger PEraserSizes[4] = {4, 6, 8, 10};
static const NSInteger PSpraySizes[3]  = {8, 16, 24};
static const NSInteger PZoomLevels[4]  = {1, 2, 6, 8};

static BOOL PIsShapeTool(PTool t) {
    return t == PToolRect || t == PToolEllipse || t == PToolRoundRect || t == PToolPolygon;
}

@implementation OptionsView

- (BOOL)isFlipped { return YES; }
- (CGFloat)rowHeight { return 20; }

- (NSInteger)rowCount {
    switch (self.canvas.tool) {
        case PToolLine: case PToolCurve: return 5;
        case PToolBrush: return 8;   // 4 sizes + 4 shapes
        case PToolEraser: return 4;
        case PToolAirbrush: return 3;
        case PToolZoom: return 4;
        case PToolSelect: case PToolFreeSelect: case PToolText: return 2;
        default:
            return PIsShapeTool(self.canvas.tool) ? 8 : 0;   // 3 fill + 5 width
    }
}

- (BOOL)isRowSelected:(NSInteger)i {
    CanvasView *cv = self.canvas;
    if (PIsShapeTool(cv.tool))
        return (i < 3) ? (cv.shapeFill == i) : (cv.lineWidth == i - 2);
    switch (cv.tool) {
        case PToolLine: case PToolCurve: return cv.lineWidth == i + 1;
        case PToolBrush:
            return (i < 4) ? (PBrushSizes[i] == cv.brushSize) : (cv.brushShape == i - 4);
        case PToolEraser: return PEraserSizes[i] == cv.eraserSize;
        case PToolAirbrush: return PSpraySizes[i] == cv.spraySize;
        case PToolZoom: return PZoomLevels[i] == cv.zoom;
        case PToolSelect: case PToolFreeSelect: case PToolText:
            return (i == 1) == cv.selTransparent;
        default: return NO;
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    [[NSColor controlBackgroundColor] setFill];
    NSRectFill(self.bounds);
    [[NSColor separatorColor] setStroke];
    [[NSBezierPath bezierPathWithRect:NSInsetRect(self.bounds, 0.5, 0.5)] stroke];

    NSInteger rows = [self rowCount];
    CGFloat rh = [self rowHeight];
    CGFloat w = self.bounds.size.width;

    static NSString * const zoomLabels[4] = {@"1x", @"2x", @"6x", @"8x"};
    static NSString * const fillLabels[3] = {@"Outline", @"Out + Fill", @"Filled"};

    for (NSInteger i = 0; i < rows; i++) {
        NSRect row = NSMakeRect(2, 4 + i * rh, w - 4, rh - 2);
        BOOL sel = [self isRowSelected:i];
        if (sel) {
            [[NSColor selectedContentBackgroundColor] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:row xRadius:4 yRadius:4] fill];
        }
        NSColor *ink = sel ? [NSColor whiteColor] : [NSColor labelColor];
        NSPoint mid = NSMakePoint(NSMidX(row), NSMidY(row));

        PTool t = self.canvas.tool;
        if (PIsShapeTool(t)) {
            if (i < 3) [self drawLabel:fillLabels[i] inRow:row ink:ink];
            else [self drawBarOfHeight:i - 2 inRow:row mid:mid ink:ink];
            continue;
        }
        switch (t) {
            case PToolLine: case PToolCurve:
                [self drawBarOfHeight:i + 1 inRow:row mid:mid ink:ink];
                break;
            case PToolBrush: {
                if (i < 4) {
                    CGFloat s = PBrushSizes[i];
                    [ink setFill];
                    [[NSBezierPath bezierPathWithOvalInRect:
                        NSMakeRect(mid.x - s / 2, mid.y - s / 2, s, s)] fill];
                } else {
                    [self drawBrushShape:i - 4 atMid:mid ink:ink];
                }
                break;
            }
            case PToolEraser: {
                CGFloat s = PEraserSizes[i];
                [ink setFill];
                NSRectFillUsingOperation(NSMakeRect(mid.x - s / 2, mid.y - s / 2, s, s),
                                         NSCompositingOperationSourceOver);
                break;
            }
            case PToolAirbrush: {
                static const CGFloat radii[3] = {4, 7, 10};
                [ink setFill];
                for (int k = 0; k < 8; k++) {
                    CGFloat ang = k * M_PI / 4.0;
                    NSRectFillUsingOperation(NSMakeRect(mid.x + cos(ang) * radii[i],
                                                        mid.y + sin(ang) * radii[i], 1.5, 1.5),
                                             NSCompositingOperationSourceOver);
                }
                break;
            }
            case PToolZoom:
                [self drawLabel:zoomLabels[i] inRow:row ink:ink];
                break;
            case PToolSelect: case PToolFreeSelect: case PToolText:
                [self drawSelIcon:(i == 1) inRow:row];
                break;
            default: break;
        }
    }
}

- (void)drawBarOfHeight:(NSInteger)h inRow:(NSRect)row mid:(NSPoint)mid ink:(NSColor *)ink {
    [ink setFill];
    NSRectFillUsingOperation(NSMakeRect(row.origin.x + 8, mid.y - h / 2.0,
                                        row.size.width - 16, h),
                             NSCompositingOperationSourceOver);
}

// XP's selection-mode icons: shapes over a solid backdrop (opaque) or over
// the transparency checker (transparent).
- (void)drawSelIcon:(BOOL)transparent inRow:(NSRect)row {
    NSRect box = NSMakeRect(NSMidX(row) - 17, NSMidY(row) - 7, 34, 14);
    if (transparent) [PCheckerColor() setFill];
    else [[NSColor colorWithCalibratedWhite:0.82 alpha:1] setFill];
    NSRectFill(box);
    [[NSColor systemBlueColor] setFill];
    NSRectFill(NSMakeRect(box.origin.x + 5, box.origin.y + 4, 7, 7));
    [[NSColor systemGreenColor] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:
        NSMakeRect(box.origin.x + 17, box.origin.y + 3, 9, 9)] fill];
    [[NSColor separatorColor] setStroke];
    [[NSBezierPath bezierPathWithRect:NSInsetRect(box, 0.5, 0.5)] stroke];
}

- (void)drawBrushShape:(NSInteger)shape atMid:(NSPoint)mid ink:(NSColor *)ink {
    if (shape == 0) {
        [ink setFill];
        [[NSBezierPath bezierPathWithOvalInRect:
            NSMakeRect(mid.x - 3.5, mid.y - 3.5, 7, 7)] fill];
        [[NSColor tertiaryLabelColor] setStroke];
        [[NSBezierPath bezierPathWithOvalInRect:
            NSMakeRect(mid.x - 5.5, mid.y - 5.5, 11, 11)] stroke];
    } else if (shape == 1) {
        [ink setFill];
        NSRectFillUsingOperation(NSMakeRect(mid.x - 3.5, mid.y - 3.5, 7, 7),
                                 NSCompositingOperationSourceOver);
    } else {
        NSBezierPath *p = [NSBezierPath bezierPath];
        CGFloat d = (shape == 2) ? 1 : -1;   // flipped view: y down
        [p moveToPoint:NSMakePoint(mid.x - 4, mid.y + 4 * d)];
        [p lineToPoint:NSMakePoint(mid.x + 4, mid.y - 4 * d)];
        p.lineWidth = 1.5;
        [ink setStroke];
        [p stroke];
    }
}

- (void)drawLabel:(NSString *)s inRow:(NSRect)row ink:(NSColor *)ink {
    NSDictionary *attrs = @{ NSFontAttributeName: [NSFont systemFontOfSize:10],
                             NSForegroundColorAttributeName: ink };
    NSSize sz = [s sizeWithAttributes:attrs];
    [s drawAtPoint:NSMakePoint(NSMidX(row) - sz.width / 2, NSMidY(row) - sz.height / 2)
        withAttributes:attrs];
}

- (void)mouseDown:(NSEvent *)e {
    NSInteger rows = [self rowCount];
    if (rows == 0) return;
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    NSInteger i = (NSInteger)((p.y - 4) / [self rowHeight]);
    if (i < 0 || i >= rows) return;

    CanvasView *cv = self.canvas;
    if (PIsShapeTool(cv.tool)) {
        if (i < 3) cv.shapeFill = i;
        else cv.lineWidth = i - 2;
        [self setNeedsDisplay:YES];
        return;
    }
    switch (cv.tool) {
        case PToolLine: case PToolCurve: cv.lineWidth = i + 1; break;
        case PToolBrush:
            if (i < 4) cv.brushSize = PBrushSizes[i];
            else cv.brushShape = i - 4;
            break;
        case PToolEraser: cv.eraserSize = PEraserSizes[i]; break;
        case PToolAirbrush: cv.spraySize = PSpraySizes[i]; break;
        case PToolZoom: [cv setZoomLevel:PZoomLevels[i]]; break;
        case PToolSelect: case PToolFreeSelect: case PToolText:
            cv.selTransparent = (i == 1);
            [cv setNeedsDisplay:YES];
            break;
        default: break;
    }
    [self setNeedsDisplay:YES];
}

@end
