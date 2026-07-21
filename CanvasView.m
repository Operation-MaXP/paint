// CanvasView — the drawing surface and all tool logic.
// Public interface in CanvasView.h; drag/selection/text state is private here.
#import "CanvasView.h"

@interface CanvasView ()
// selection
@property BOOL hasSelection;
@property NSRect selRect;                 // canvas coords
@property (strong) NSBitmapImageRep *floating;
@property NSPoint floatOrigin;
@property (strong) NSBezierPath *lasso;   // freeform in progress
// drag state
@property BOOL dragging;
@property BOOL dragRight;                 // right button = colors swapped
@property NSPoint dragStart, dragCur, lastPt;
@property (strong) NSMutableArray *polyPoints;
@property NSInteger curvePhase;           // 0 none, 1 endpoints, 2 c1 set
@property NSPoint curveA, curveB, curveC1, curveC2;
@property (strong) NSTimer *sprayTimer;
@property NSInteger canvasResizeMode;     // 0 none, 1 right, 2 bottom, 3 corner
@property BOOL trailDrag;                 // shift-drag: smear copies
@property BOOL gestureSnapshotDone;       // one undo entry per stamp gesture
// text
@property (strong) NSTextView *textEditor;
@property NSRect textRect;                // canvas coords
@end

@implementation CanvasView

- (instancetype)initWithCanvasWidth:(NSInteger)w height:(NSInteger)h {
    self = [super initWithFrame:NSMakeRect(0, 0, w, h)];
    self.undo = [NSUndoManager new];
    self.undo.levelsOfUndo = 40;         // full-bitmap snapshots — keep bounded
    self.fg = [NSColor blackColor];
    self.bg = [NSColor whiteColor];
    self.lineWidth = 1;
    self.brushSize = 3;
    self.brushShape = 0;
    self.eraserSize = 8;
    self.spraySize = 16;
    self.shapeFill = 0;
    self.zoom = 1;
    self.tool = PToolPencil;
    self.prevTool = PToolPencil;
    self.polyPoints = [NSMutableArray array];
    [self resetCanvasWidth:w height:h];
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return NO; }
- (BOOL)acceptsFirstResponder { return YES; }

- (void)resetCanvasWidth:(NSInteger)w height:(NSInteger)h {
    self.bitmap = PNewRep(w, h);
    // XP default: white canvas
    uint8_t white[4] = {255, 255, 255, 255};
    uint8_t *d = self.bitmap.bitmapData;
    for (NSInteger y = 0; y < h; y++)
        for (NSInteger x = 0; x < w; x++)
            memcpy(d + y * self.bitmap.bytesPerRow + x * 4, white, 4);
    [self clearSelectionState];
    [self.undo removeAllActions];
    [self updateFrame];
    [self setNeedsDisplay:YES];
}

- (void)updateFrame {
    // +12: room for the XP canvas-resize handles outside the bitmap
    [self setFrameSize:NSMakeSize(self.bitmap.pixelsWide * self.zoom + 12,
                                  self.bitmap.pixelsHigh * self.zoom + 12)];
}

// XP canvas-resize handles: right edge, bottom edge, corner
- (NSRect)handleRect:(NSInteger)mode {
    CGFloat bw = self.bitmap.pixelsWide * self.zoom;
    CGFloat bh = self.bitmap.pixelsHigh * self.zoom;
    CGFloat s = 7;
    switch (mode) {
        case 1:  return NSMakeRect(bw + 2, bh / 2 - s / 2, s, s);
        case 2:  return NSMakeRect(bw / 2 - s / 2, bh + 2, s, s);
        default: return NSMakeRect(bw + 2, bh + 2, s, s);
    }
}

- (NSInteger)handleAtViewPoint:(NSPoint)p {
    for (NSInteger mode = 3; mode >= 1; mode--)
        if (NSPointInRect(p, NSInsetRect([self handleRect:mode], -2, -2)))
            return mode;
    return 0;
}

- (void)drawCanvasHandles {
    if (self.textEditor) return;
    for (NSInteger mode = 1; mode <= 3; mode++) {
        NSRect r = [self handleRect:mode];
        [[NSColor controlAccentColor] setFill];
        NSRectFill(r);
        [[NSColor separatorColor] setStroke];
        [[NSBezierPath bezierPathWithRect:NSInsetRect(r, 0.5, 0.5)] stroke];
    }
}

// --- bitmap drawing context -------------------------------------------------
// Locks a flipped (top-left origin) context over the bitmap. Antialias off
// for the XP hard-pixel look; text turns it back on explicitly.
- (CGContextRef)lockBitmap {
    NSGraphicsContext *raw = [NSGraphicsContext graphicsContextWithBitmapImageRep:self.bitmap];
    CGContextRef c = raw.CGContext;
    CGContextSaveGState(c);
    CGContextTranslateCTM(c, 0, self.bitmap.pixelsHigh);
    CGContextScaleCTM(c, 1, -1);
    CGContextSetShouldAntialias(c, false);
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:
        [NSGraphicsContext graphicsContextWithCGContext:c flipped:YES]];
    return c;
}

- (void)unlockBitmap:(CGContextRef)c {
    CGContextRestoreGState(c);
    [NSGraphicsContext restoreGraphicsState];
    [self markDirty];
    [self setNeedsDisplay:YES];
}

// Freehand tools fire many times per drag; invalidate only what they touched.
- (void)unlockBitmap:(CGContextRef)c invalidateCanvasRect:(NSRect)r {
    CGContextRestoreGState(c);
    [NSGraphicsContext restoreGraphicsState];
    [self markDirty];
    [self setNeedsDisplayInRect:NSInsetRect([self zoomRect:r], -2, -2)];
    [self.thumbView setNeedsDisplay:YES];
}

- (void)setNeedsDisplay:(BOOL)flag {
    [super setNeedsDisplay:flag];
    if (flag) [self.thumbView setNeedsDisplay:YES];
}

- (void)markDirty { self.window.documentEdited = YES; }

// --- undo --------------------------------------------------------------------
- (void)snapshot {
    NSBitmapImageRep *copy = PCloneRep(self.bitmap);
    [self.undo registerUndoWithTarget:self selector:@selector(restoreBitmap:) object:copy];
    [self.undo setActionName:@"Paint"];
}

- (void)restoreBitmap:(NSBitmapImageRep *)rep {
    [self.undo registerUndoWithTarget:self selector:@selector(restoreBitmap:)
                               object:PCloneRep(self.bitmap)];
    [self discardTextEditor];
    self.floating = nil;
    self.hasSelection = NO;
    self.bitmap = rep;
    [self updateFrame];
    [self markDirty];
    [self setNeedsDisplay:YES];
}

// --- tool / option setters ----------------------------------------------------
- (void)setCurrentTool:(PTool)t {
    if (t == self.tool) return;
    [self commitTextEditor];
    if (t != PToolSelect && t != PToolFreeSelect) [self commitSelection];
    self.curvePhase = 0;
    [self.polyPoints removeAllObjects];
    if (t == PToolPicker) self.prevTool = self.tool;
    self.tool = t;
    [self.optionsView setNeedsDisplay:YES];
    [self setNeedsDisplay:YES];
    if (self.onToolChanged) self.onToolChanged();
}

- (void)setZoomLevel:(NSInteger)z {
    if (z == self.zoom) return;
    [self commitTextEditor];
    self.zoom = z;
    [self updateFrame];
    [self.optionsView setNeedsDisplay:YES];
    [self setNeedsDisplay:YES];
}

- (void)setZoomLevel:(NSInteger)z anchorCanvasPoint:(NSPoint)pt {
    if (z == self.zoom) return;
    NSRect vis = self.visibleRect;
    CGFloat offX = pt.x * self.zoom - vis.origin.x;   // cursor offset in viewport
    CGFloat offY = pt.y * self.zoom - vis.origin.y;
    [self setZoomLevel:z];
    [self scrollPoint:NSMakePoint(MAX(0, pt.x * z - offX), MAX(0, pt.y * z - offY))];
}

- (void)setForeground:(NSColor *)c {
    self.fg = c;
    [self.fgbgView setNeedsDisplay:YES];
}

- (void)setBackground:(NSColor *)c {
    self.bg = c;
    [self.fgbgView setNeedsDisplay:YES];
}

// --- coordinate helpers --------------------------------------------------------
- (NSPoint)canvasPoint:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    return NSMakePoint(floor(p.x / self.zoom), floor(p.y / self.zoom));
}

- (NSPoint)clampPoint:(NSPoint)p {
    return NSMakePoint(MAX(0, MIN(p.x, self.bitmap.pixelsWide - 1)),
                       MAX(0, MIN(p.y, self.bitmap.pixelsHigh - 1)));
}

- (NSRect)zoomRect:(NSRect)r {
    return NSMakeRect(r.origin.x * self.zoom, r.origin.y * self.zoom,
                      r.size.width * self.zoom, r.size.height * self.zoom);
}

// ============================================================================
// Drawing the view: checkerboard, bitmap, floating selection, previews
// ============================================================================
- (void)drawRect:(NSRect)dirtyRect {
    NSRect full = NSMakeRect(0, 0, self.bitmap.pixelsWide * self.zoom,
                                   self.bitmap.pixelsHigh * self.zoom);

    [PCheckerColor() setFill];
    NSRectFill(full);

    NSGraphicsContext *g = NSGraphicsContext.currentContext;
    g.imageInterpolation = NSImageInterpolationNone;
    [self.bitmap drawInRect:full fromRect:NSZeroRect
                  operation:NSCompositingOperationSourceOver fraction:1
              respectFlipped:YES hints:PNearestHint()];

    // pixel grid (View > Show Grid), XP-style, at 2x and above
    if (self.showGrid && self.zoom >= 2) {
        NSBezierPath *grid = [NSBezierPath bezierPath];
        for (NSInteger x = 0; x <= self.bitmap.pixelsWide; x++) {
            [grid moveToPoint:NSMakePoint(x * self.zoom + 0.5, 0)];
            [grid lineToPoint:NSMakePoint(x * self.zoom + 0.5, full.size.height)];
        }
        for (NSInteger y = 0; y <= self.bitmap.pixelsHigh; y++) {
            [grid moveToPoint:NSMakePoint(0, y * self.zoom + 0.5)];
            [grid lineToPoint:NSMakePoint(full.size.width, y * self.zoom + 0.5)];
        }
        [[NSColor colorWithWhite:0.5 alpha:0.4] setStroke];
        grid.lineWidth = 1;
        [grid stroke];
    }

    // floating selection
    if (self.floating) {
        NSRect fr = [self zoomRect:NSMakeRect(self.floatOrigin.x, self.floatOrigin.y,
                                              self.floating.pixelsWide, self.floating.pixelsHigh)];
        NSBitmapImageRep *img = self.selTransparent ? [self maskedFloating] : self.floating;
        [img drawInRect:fr fromRect:NSZeroRect
              operation:NSCompositingOperationSourceOver fraction:1
          respectFlipped:YES hints:PNearestHint()];
        [self drawMarquee:fr];
    } else if (self.hasSelection) {
        [self drawMarquee:[self zoomRect:self.selRect]];
    }

    // lasso in progress
    if (self.lasso && self.dragging && self.tool == PToolFreeSelect) {
        NSBezierPath *p = [self.lasso copy];
        NSAffineTransform *t = [NSAffineTransform transform];
        [t scaleBy:self.zoom];
        [p transformUsingAffineTransform:t];
        [[NSColor blackColor] setStroke];
        CGFloat dash[2] = {4, 4};
        [p setLineDash:dash count:2 phase:0];
        [p stroke];
    }

    // text editor frame
    if (self.textEditor)
        [self drawMarquee:[self zoomRect:self.textRect]];

    [self drawPreview];
    [self drawCanvasHandles];
}

- (void)drawMarquee:(NSRect)r {
    NSBezierPath *p = [NSBezierPath bezierPathWithRect:NSInsetRect(r, 0.5, 0.5)];
    [[NSColor whiteColor] setStroke];
    [p stroke];
    CGFloat dash[2] = {4, 4};
    [p setLineDash:dash count:2 phase:0];
    [[NSColor blackColor] setStroke];
    [p stroke];
}

- (void)drawPreview {
    NSInteger z = self.zoom;

    if (self.canvasResizeMode) {
        CGFloat w = (self.canvasResizeMode != 2) ? self.dragCur.x : self.bitmap.pixelsWide;
        CGFloat h = (self.canvasResizeMode != 1) ? self.dragCur.y : self.bitmap.pixelsHigh;
        [self drawMarquee:[self zoomRect:NSMakeRect(0, 0, MAX(1, w), MAX(1, h))]];
        return;
    }
    NSColor *strokeColor = self.dragRight ? self.bg : self.fg;
    NSColor *fillColor   = self.dragRight ? self.fg : self.bg;

    NSBezierPath *p = nil;

    if (self.dragging) {
        NSRect r = [self zoomRect:PNormRect(self.dragStart, self.dragCur)];
        switch (self.tool) {
            case PToolSelect:
                if (!self.floating) [self drawMarquee:r];   // moving a floating
                return;                                     // selection draws its
                                                            // own marquee already
            case PToolText:
                [self drawMarquee:r];
                return;
            case PToolLine:
                p = [NSBezierPath bezierPath];
                [p moveToPoint:NSMakePoint(self.dragStart.x * z, self.dragStart.y * z)];
                [p lineToPoint:NSMakePoint(self.dragCur.x * z, self.dragCur.y * z)];
                p.lineWidth = self.lineWidth * z;
                break;
            case PToolRect:
                p = [NSBezierPath bezierPathWithRect:r];
                break;
            case PToolEllipse:
                p = [NSBezierPath bezierPathWithOvalInRect:r];
                break;
            case PToolRoundRect:
                p = [NSBezierPath bezierPathWithRoundedRect:r xRadius:8 * z yRadius:8 * z];
                break;
            default: break;
        }
        if (p && (self.tool == PToolRect || self.tool == PToolEllipse || self.tool == PToolRoundRect)) {
            if (self.shapeFill >= 1) {
                [(self.shapeFill == 2 ? strokeColor : fillColor) setFill];
                if ((self.shapeFill == 2 ? strokeColor : fillColor).alphaComponent > 0.001) [p fill];
            }
            if (self.shapeFill != 2) {
                p.lineWidth = self.lineWidth * z;
                [strokeColor setStroke];
                if (strokeColor.alphaComponent > 0.001) [p stroke];
            }
            return;
        }
        if (p) {
            [strokeColor setStroke];
            [p stroke];
            return;
        }
    }

    // curve preview (multi-phase, independent of dragging flag)
    if (self.tool == PToolCurve && self.curvePhase > 0) {
        p = [NSBezierPath bezierPath];
        [p moveToPoint:NSMakePoint(self.curveA.x * z, self.curveA.y * z)];
        NSPoint c1 = self.curveC1, c2 = self.curvePhase >= 2 ? self.curveC2 : self.curveC1;
        [p curveToPoint:NSMakePoint(self.curveB.x * z, self.curveB.y * z)
          controlPoint1:NSMakePoint(c1.x * z, c1.y * z)
          controlPoint2:NSMakePoint(c2.x * z, c2.y * z)];
        p.lineWidth = self.lineWidth * z;
        [strokeColor setStroke];
        [p stroke];
    }

    // polygon preview
    if (self.tool == PToolPolygon && self.polyPoints.count > 0) {
        p = [NSBezierPath bezierPath];
        NSPoint first = [self.polyPoints[0] pointValue];
        [p moveToPoint:NSMakePoint(first.x * z, first.y * z)];
        for (NSUInteger i = 1; i < self.polyPoints.count; i++) {
            NSPoint pt = [self.polyPoints[i] pointValue];
            [p lineToPoint:NSMakePoint(pt.x * z, pt.y * z)];
        }
        [p lineToPoint:NSMakePoint(self.dragCur.x * z, self.dragCur.y * z)];
        p.lineWidth = self.lineWidth * z;
        [strokeColor setStroke];
        [p stroke];
    }
}

// ============================================================================
// Mouse handling — one linear flow, right button swaps fg/bg (XP behavior)
// ============================================================================
- (void)mouseDown:(NSEvent *)e        { [self toolDown:e right:NO]; }
- (void)rightMouseDown:(NSEvent *)e   { [self toolDown:e right:YES]; }
- (void)mouseDragged:(NSEvent *)e     { [self toolDrag:e]; }
- (void)rightMouseDragged:(NSEvent *)e{ [self toolDrag:e]; }
- (void)mouseUp:(NSEvent *)e          { [self toolUp:e]; }
- (void)rightMouseUp:(NSEvent *)e     { [self toolUp:e]; }

- (NSColor *)dragFG { return self.dragRight ? self.bg : self.fg; }
- (NSColor *)dragBG { return self.dragRight ? self.fg : self.bg; }

- (void)toolDown:(NSEvent *)e right:(BOOL)right {
    [self.window makeFirstResponder:self];
    NSPoint pt = [self canvasPoint:e];

    // clicking outside an active text box commits it
    if (self.textEditor && !NSPointInRect(pt, self.textRect)) {
        [self commitTextEditor];
        return;
    }

    // canvas-resize handles live outside the bitmap; left-drag grabs them
    if (!right) {
        NSPoint vp = [self convertPoint:e.locationInWindow fromView:nil];
        NSInteger hm = [self handleAtViewPoint:vp];
        if (hm) {
            self.canvasResizeMode = hm;
            self.dragging = YES;
            self.dragRight = NO;
            self.dragStart = pt;
            self.dragCur = NSMakePoint(self.bitmap.pixelsWide, self.bitmap.pixelsHigh);
            return;
        }
    }

    self.dragRight = right;
    self.dragStart = pt;
    self.dragCur = pt;
    self.lastPt = pt;
    self.dragging = YES;
    self.gestureSnapshotDone = NO;
    self.trailDrag = NO;

    switch (self.tool) {

        case PToolPencil: {
            [self snapshot];
            [self strokeFrom:pt to:pt width:1 color:self.dragFG];
            break;
        }
        case PToolBrush: {
            [self snapshot];
            [self brushSegmentFrom:pt to:pt];
            break;
        }
        case PToolEraser: {
            [self snapshot];
            if (self.dragRight) [self colorEraseFrom:pt to:pt];
            else [self eraseFrom:pt to:pt];
            break;
        }
        case PToolAirbrush: {
            [self snapshot];
            [self sprayAt:pt];
            self.sprayTimer = [NSTimer scheduledTimerWithTimeInterval:0.05 target:self
                                selector:@selector(sprayTick:) userInfo:nil repeats:YES];
            break;
        }
        case PToolFill: {
            NSInteger fx = (NSInteger)pt.x, fy = (NSInteger)pt.y;
            if (fx >= 0 && fy >= 0 &&
                fx < self.bitmap.pixelsWide && fy < self.bitmap.pixelsHigh) {
                uint8_t fill[4];
                PBytes(self.dragFG, fill);
                uint8_t *px = self.bitmap.bitmapData
                            + fy * self.bitmap.bytesPerRow + fx * 4;
                if (memcmp(px, fill, 4) != 0) {   // no-op fill: no undo entry
                    [self snapshot];
                    PFlood(self.bitmap, fx, fy, fill);
                    [self markDirty];
                    [self setNeedsDisplay:YES];
                }
            }
            self.dragging = NO;
            break;
        }
        case PToolPicker: {
            NSColor *c = [self pixelColorAt:[self clampPoint:pt]];
            if (right) [self setBackground:c]; else [self setForeground:c];
            [self setCurrentTool:self.prevTool];
            self.dragging = NO;
            break;
        }
        case PToolZoom: {
            static const NSInteger levels[4] = {1, 2, 6, 8};
            NSInteger i = 0;
            for (NSInteger k = 0; k < 4; k++) if (levels[k] == self.zoom) i = k;
            BOOL out = right || (e.modifierFlags & NSEventModifierFlagOption);
            i = out ? MAX(0, i - 1) : MIN(3, i + 1);
            [self setZoomLevel:levels[i] anchorCanvasPoint:pt];
            self.dragging = NO;
            break;
        }
        case PToolSelect: {
            if (self.hasSelection && NSPointInRect(pt, [self activeSelRect])) {
                if (!self.floating) [self liftSelectionWithPath:nil];
                // XP: ctrl-drag leaves a copy behind, shift-drag smears a trail
                if (e.modifierFlags & (NSEventModifierFlagOption | NSEventModifierFlagControl))
                    [self stampFloatingCopy];
                self.trailDrag = (e.modifierFlags & NSEventModifierFlagShift) != 0;
                // drag offset stored in dragStart relative to floatOrigin
                self.dragStart = NSMakePoint(pt.x - self.floatOrigin.x, pt.y - self.floatOrigin.y);
            } else {
                [self commitSelection];
                self.hasSelection = NO;
            }
            break;
        }
        case PToolFreeSelect: {
            if (self.hasSelection && NSPointInRect(pt, [self activeSelRect])) {
                if (!self.floating) [self liftSelectionWithPath:nil];
                if (e.modifierFlags & (NSEventModifierFlagOption | NSEventModifierFlagControl))
                    [self stampFloatingCopy];
                self.trailDrag = (e.modifierFlags & NSEventModifierFlagShift) != 0;
                self.dragStart = NSMakePoint(pt.x - self.floatOrigin.x, pt.y - self.floatOrigin.y);
                self.lasso = nil;
            } else {
                [self commitSelection];
                self.hasSelection = NO;
                self.lasso = [NSBezierPath bezierPath];
                [self.lasso moveToPoint:pt];
            }
            break;
        }
        case PToolPolygon: {
            if (self.polyPoints.count == 0) {
                [self.polyPoints addObject:[NSValue valueWithPoint:pt]];
            } else if (e.clickCount >= 2) {
                [self commitPolygon];
                self.dragging = NO;
            } else {
                [self.polyPoints addObject:[NSValue valueWithPoint:pt]];
            }
            [self setNeedsDisplay:YES];
            break;
        }
        case PToolCurve: {
            if (self.curvePhase == 0) {
                self.curveA = pt; self.curveB = pt;
                self.curveC1 = pt; self.curveC2 = pt;
            } else if (self.curvePhase == 1) {
                self.curveC1 = pt; self.curveC2 = pt;
            } else {
                self.curveC2 = pt;
            }
            [self setNeedsDisplay:YES];
            break;
        }
        case PToolText: {
            // drag defines the box; handled at mouseUp
            break;
        }
        default: break;
    }
    [self updateStatus:pt];
}

- (void)toolDrag:(NSEvent *)e {
    if (!self.dragging) return;
    NSPoint pt = [self canvasPoint:e];

    if (self.canvasResizeMode) {
        self.dragCur = NSMakePoint(MAX(1, pt.x + 1), MAX(1, pt.y + 1));
        self.statusSize.stringValue = [NSString stringWithFormat:@"%ld × %ld",
            (long)((self.canvasResizeMode != 2) ? self.dragCur.x : self.bitmap.pixelsWide),
            (long)((self.canvasResizeMode != 1) ? self.dragCur.y : self.bitmap.pixelsHigh)];
        [self setNeedsDisplay:YES];
        return;
    }

    // shift constrains lines to 45° and shapes to squares
    if (e.modifierFlags & NSEventModifierFlagShift) {
        CGFloat dx = pt.x - self.dragStart.x, dy = pt.y - self.dragStart.y;
        if (self.tool == PToolLine) {
            if (fabs(dx) > 2 * fabs(dy)) pt.y = self.dragStart.y;
            else if (fabs(dy) > 2 * fabs(dx)) pt.x = self.dragStart.x;
            else {
                CGFloat m = MAX(fabs(dx), fabs(dy));
                pt = NSMakePoint(self.dragStart.x + copysign(m, dx),
                                 self.dragStart.y + copysign(m, dy));
            }
        } else if (self.tool == PToolRect || self.tool == PToolEllipse || self.tool == PToolRoundRect) {
            CGFloat m = MAX(fabs(dx), fabs(dy));
            pt = NSMakePoint(self.dragStart.x + copysign(m, dx),
                             self.dragStart.y + copysign(m, dy));
        }
    }

    self.dragCur = pt;

    switch (self.tool) {
        case PToolPencil:
            [self strokeFrom:self.lastPt to:pt width:1 color:self.dragFG];
            break;
        case PToolBrush:
            [self brushSegmentFrom:self.lastPt to:pt];
            break;
        case PToolEraser:
            if (self.dragRight) [self colorEraseFrom:self.lastPt to:pt];
            else [self eraseFrom:self.lastPt to:pt];
            break;
        case PToolAirbrush:
            // timer sprays at lastPt continuously
            break;
        case PToolSelect:
        case PToolFreeSelect:
            if (self.floating) {
                if (self.trailDrag) [self stampFloatingCopy];   // shift: smear
                self.floatOrigin = NSMakePoint(pt.x - self.dragStart.x, pt.y - self.dragStart.y);
            } else if (self.tool == PToolFreeSelect && self.lasso) {
                [self.lasso lineToPoint:pt];
            }
            [self setNeedsDisplay:YES];
            break;
        case PToolCurve:
            if (self.curvePhase == 0) self.curveB = pt;
            else if (self.curvePhase == 1) { self.curveC1 = pt; self.curveC2 = pt; }
            else self.curveC2 = pt;
            [self setNeedsDisplay:YES];
            break;
        default:
            [self setNeedsDisplay:YES];
            break;
    }
    self.lastPt = pt;
    [self updateStatus:pt];
    [self updateStatusSize];
}

- (void)toolUp:(NSEvent *)e {
    if (!self.dragging) return;

    if (self.canvasResizeMode) {
        NSInteger mode = self.canvasResizeMode;
        self.canvasResizeMode = 0;
        self.dragging = NO;
        NSInteger w = self.bitmap.pixelsWide, h = self.bitmap.pixelsHigh;
        if (mode == 1 || mode == 3) w = MAX(1, (NSInteger)lround(self.dragCur.x));
        if (mode == 2 || mode == 3) h = MAX(1, (NSInteger)lround(self.dragCur.y));
        [self resizeCanvasWidth:w height:h];
        return;
    }

    NSPoint pt = self.dragCur;
    self.dragging = NO;
    self.trailDrag = NO;

    switch (self.tool) {
        case PToolAirbrush:
            [self.sprayTimer invalidate];
            self.sprayTimer = nil;
            break;
        case PToolLine:
            [self commitLineFrom:self.dragStart to:pt];
            break;
        case PToolRect:
        case PToolEllipse:
        case PToolRoundRect:
            [self commitShapeFrom:self.dragStart to:pt];
            break;
        case PToolCurve:
            if (self.curvePhase == 0) {
                if (!NSEqualPoints(self.curveA, self.curveB)) self.curvePhase = 1;
            } else if (self.curvePhase == 1) {
                self.curvePhase = 2;
            } else {
                [self commitCurve];
                self.curvePhase = 0;
            }
            [self setNeedsDisplay:YES];
            break;
        case PToolSelect:
            if (!self.floating) {
                NSRect r = PNormRect(self.dragStart, pt);
                r = NSIntersectionRect(r, NSMakeRect(0, 0, self.bitmap.pixelsWide, self.bitmap.pixelsHigh));
                self.hasSelection = r.size.width >= 1 && r.size.height >= 1;
                self.selRect = r;
            }
            [self setNeedsDisplay:YES];
            break;
        case PToolFreeSelect:
            if (!self.floating && self.lasso) {
                [self.lasso closePath];
                NSRect b = NSIntegralRect(self.lasso.bounds);
                b = NSIntersectionRect(b, NSMakeRect(0, 0, self.bitmap.pixelsWide, self.bitmap.pixelsHigh));
                if (b.size.width >= 2 && b.size.height >= 2) {
                    self.selRect = b;
                    self.hasSelection = YES;
                    [self liftSelectionWithPath:self.lasso];
                }
                self.lasso = nil;
            }
            [self setNeedsDisplay:YES];
            break;
        case PToolText: {
            NSRect r = PNormRect(self.dragStart, pt);
            if (r.size.width >= 24 && r.size.height >= 16)
                [self beginTextEditorInRect:r];
            break;
        }
        default: break;
    }
    [self updateStatusSize];
}

// ============================================================================
// Freehand tools
// ============================================================================
- (void)strokeFrom:(NSPoint)a to:(NSPoint)b width:(NSInteger)w color:(NSColor *)col {
    CGContextRef c = [self lockBitmap];
    PSetStroke(c, col);
    CGContextSetLineWidth(c, w);
    CGContextSetLineCap(c, kCGLineCapRound);
    CGContextSetLineJoin(c, kCGLineJoinRound);
    CGContextBeginPath(c);
    CGContextMoveToPoint(c, a.x + 0.5, a.y + 0.5);
    CGContextAddLineToPoint(c, b.x + 0.5, b.y + 0.5);
    CGContextStrokePath(c);
    [self unlockBitmap:c invalidateCanvasRect:
        NSInsetRect(PNormRect(a, b), -(w + 2), -(w + 2))];
}

// XP brush shapes: round stroke, square stamps, and slash / backslash
// strokes stamped along the drag path.
- (void)brushSegmentFrom:(NSPoint)a to:(NSPoint)b {
    NSInteger s = self.brushSize;
    if (self.brushShape == 0) {
        [self strokeFrom:a to:b width:s color:self.dragFG];
        return;
    }
    CGContextRef c = [self lockBitmap];
    CGFloat dist = MAX(1, hypot(b.x - a.x, b.y - a.y));
    if (self.brushShape == 1) {
        PSetFill(c, self.dragFG);
        for (CGFloat t = 0; t <= dist; t += 1) {
            CGFloat x = a.x + (b.x - a.x) * t / dist;
            CGFloat y = a.y + (b.y - a.y) * t / dist;
            CGContextFillRect(c, CGRectMake(round(x - s / 2.0), round(y - s / 2.0), s, s));
        }
    } else {
        // slash (/) or backslash (\): thin diagonal of length s
        PSetStroke(c, self.dragFG);
        CGContextSetLineWidth(c, 1);
        CGFloat h = s / 2.0;
        CGFloat dir = (self.brushShape == 2) ? 1 : -1;   // flipped coords: y down
        CGContextBeginPath(c);
        for (CGFloat t = 0; t <= dist; t += 1) {
            CGFloat x = a.x + (b.x - a.x) * t / dist;
            CGFloat y = a.y + (b.y - a.y) * t / dist;
            CGContextMoveToPoint(c, x - h, y + h * dir);
            CGContextAddLineToPoint(c, x + h, y - h * dir);
        }
        CGContextStrokePath(c);
    }
    [self unlockBitmap:c invalidateCanvasRect:
        NSInsetRect(PNormRect(a, b), -(s + 2), -(s + 2))];
}

- (void)eraseFrom:(NSPoint)a to:(NSPoint)b {
    CGContextRef c = [self lockBitmap];
    // XP eraser paints the background color; transparent bg erases to alpha 0
    uint8_t bytes[4];
    PBytes(self.bg, bytes);
    CGContextSetBlendMode(c, kCGBlendModeCopy);
    NSColor *s = [self.bg colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    CGContextSetRGBFillColor(c, s.redComponent, s.greenComponent, s.blueComponent, s.alphaComponent);
    CGFloat sz = self.eraserSize;
    CGFloat dist = MAX(1, hypot(b.x - a.x, b.y - a.y));
    for (CGFloat t = 0; t <= dist; t += 1) {
        CGFloat x = a.x + (b.x - a.x) * t / dist;
        CGFloat y = a.y + (b.y - a.y) * t / dist;
        CGContextFillRect(c, CGRectMake(round(x - sz / 2), round(y - sz / 2), sz, sz));
    }
    [self unlockBitmap:c invalidateCanvasRect:
        NSInsetRect(PNormRect(a, b), -(sz + 2), -(sz + 2))];
}

// XP color eraser (right-drag): within the eraser square, replace only
// pixels matching the foreground color with the background color.
- (void)colorEraseFrom:(NSPoint)a to:(NSPoint)b {
    uint8_t fgB[4], bgB[4];
    PBytes(self.fg, fgB);
    PBytes(self.bg, bgB);
    uint8_t *data = self.bitmap.bitmapData;
    NSInteger bpr = self.bitmap.bytesPerRow;
    NSInteger W = self.bitmap.pixelsWide, H = self.bitmap.pixelsHigh;
    NSInteger s = self.eraserSize;
    CGFloat dist = MAX(1, hypot(b.x - a.x, b.y - a.y));
    for (CGFloat t = 0; t <= dist; t += 1) {
        NSInteger cx = (NSInteger)lround(a.x + (b.x - a.x) * t / dist);
        NSInteger cy = (NSInteger)lround(a.y + (b.y - a.y) * t / dist);
        for (NSInteger y = cy - s / 2; y < cy - s / 2 + s; y++) {
            if (y < 0 || y >= H) continue;
            for (NSInteger x = cx - s / 2; x < cx - s / 2 + s; x++) {
                if (x < 0 || x >= W) continue;
                uint8_t *p = data + y * bpr + x * 4;
                if (PNearEq(p, fgB)) memcpy(p, bgB, 4);
            }
        }
    }
    [self markDirty];
    [self setNeedsDisplayInRect:
        NSInsetRect([self zoomRect:PNormRect(a, b)], -(s + 2) * self.zoom, -(s + 2) * self.zoom)];
    [self.thumbView setNeedsDisplay:YES];
}

// Stamp the floating selection at its current position without dropping it.
// One undo entry per gesture, however many stamps a shift-smear lays down.
- (void)stampFloatingCopy {
    if (!self.floating) return;
    if (!self.gestureSnapshotDone) {
        [self snapshot];
        self.gestureSnapshotDone = YES;
    }
    CGContextRef c = [self lockBitmap];
    NSBitmapImageRep *img = self.selTransparent ? [self maskedFloating] : self.floating;
    [img drawInRect:NSMakeRect(self.floatOrigin.x, self.floatOrigin.y,
                               img.pixelsWide, img.pixelsHigh)
           fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
           fraction:1 respectFlipped:YES hints:PNearestHint()];
    [self unlockBitmap:c];
}

- (void)sprayTick:(NSTimer *)t { [self sprayAt:self.lastPt]; }

- (void)sprayAt:(NSPoint)pt {
    CGContextRef c = [self lockBitmap];
    PSetFill(c, self.dragFG);
    CGFloat r = self.spraySize / 2.0;
    for (int i = 0; i < 12; i++) {
        CGFloat ang = (arc4random_uniform(10000) / 10000.0) * 2 * M_PI;
        CGFloat rad = sqrt(arc4random_uniform(10000) / 10000.0) * r;
        CGContextFillRect(c, CGRectMake(floor(pt.x + cos(ang) * rad),
                                        floor(pt.y + sin(ang) * rad), 1, 1));
    }
    [self unlockBitmap:c invalidateCanvasRect:
        NSMakeRect(pt.x - r - 2, pt.y - r - 2, r * 2 + 4, r * 2 + 4)];
}

// ============================================================================
// Shape commits
// ============================================================================
- (void)commitLineFrom:(NSPoint)a to:(NSPoint)b {
    [self snapshot];
    CGContextRef c = [self lockBitmap];
    PSetStroke(c, self.dragFG);
    CGContextSetLineWidth(c, self.lineWidth);
    CGContextSetLineCap(c, kCGLineCapRound);
    CGContextBeginPath(c);
    CGContextMoveToPoint(c, a.x + 0.5, a.y + 0.5);
    CGContextAddLineToPoint(c, b.x + 0.5, b.y + 0.5);
    CGContextStrokePath(c);
    [self unlockBitmap:c];
}

- (void)commitShapeFrom:(NSPoint)a to:(NSPoint)b {
    NSRect r = PNormRect(a, b);
    if (r.size.width < 1 || r.size.height < 1) return;
    [self snapshot];
    CGContextRef c = [self lockBitmap];

    CGPathRef path;
    if (self.tool == PToolEllipse)
        path = CGPathCreateWithEllipseInRect(r, NULL);
    else if (self.tool == PToolRoundRect)
        path = CGPathCreateWithRoundedRect(r, MIN(8, r.size.width / 2), MIN(8, r.size.height / 2), NULL);
    else
        path = CGPathCreateWithRect(r, NULL);

    if (self.shapeFill >= 1) {
        PSetFill(c, self.shapeFill == 2 ? self.dragFG : self.dragBG);
        CGContextBeginPath(c);
        CGContextAddPath(c, path);
        CGContextFillPath(c);
    }
    if (self.shapeFill != 2) {
        PSetStroke(c, self.dragFG);
        CGContextSetLineWidth(c, self.lineWidth);
        CGContextBeginPath(c);
        CGContextAddPath(c, path);
        CGContextStrokePath(c);
    }
    CGPathRelease(path);
    [self unlockBitmap:c];
}

- (void)commitPolygon {
    if (self.polyPoints.count < 3) { [self.polyPoints removeAllObjects]; return; }
    [self snapshot];
    CGContextRef c = [self lockBitmap];
    CGContextBeginPath(c);
    NSPoint first = [self.polyPoints[0] pointValue];
    CGContextMoveToPoint(c, first.x + 0.5, first.y + 0.5);
    for (NSUInteger i = 1; i < self.polyPoints.count; i++) {
        NSPoint pt = [self.polyPoints[i] pointValue];
        CGContextAddLineToPoint(c, pt.x + 0.5, pt.y + 0.5);
    }
    CGContextClosePath(c);
    CGPathRef path = CGContextCopyPath(c);
    if (self.shapeFill >= 1) {
        PSetFill(c, self.shapeFill == 2 ? self.dragFG : self.dragBG);
        CGContextFillPath(c);
    }
    if (self.shapeFill != 2) {
        PSetStroke(c, self.dragFG);
        CGContextSetLineWidth(c, self.lineWidth);
        CGContextBeginPath(c);
        CGContextAddPath(c, path);
        CGContextStrokePath(c);
    }
    CGPathRelease(path);
    [self unlockBitmap:c];
    [self.polyPoints removeAllObjects];
}

- (void)commitCurve {
    [self snapshot];
    CGContextRef c = [self lockBitmap];
    PSetStroke(c, self.dragFG);
    CGContextSetLineWidth(c, self.lineWidth);
    CGContextSetLineCap(c, kCGLineCapRound);
    CGContextBeginPath(c);
    CGContextMoveToPoint(c, self.curveA.x + 0.5, self.curveA.y + 0.5);
    CGContextAddCurveToPoint(c, self.curveC1.x, self.curveC1.y,
                             self.curveC2.x, self.curveC2.y,
                             self.curveB.x + 0.5, self.curveB.y + 0.5);
    CGContextStrokePath(c);
    [self unlockBitmap:c];
}

// ============================================================================
// Selection: lift, move, stamp, transparent mode, clipboard
// ============================================================================
- (NSRect)activeSelRect {
    if (self.floating)
        return NSMakeRect(self.floatOrigin.x, self.floatOrigin.y,
                          self.floating.pixelsWide, self.floating.pixelsHigh);
    return self.selRect;
}

// Extract a region's pixels into a standalone rep, without touching the canvas.
- (NSBitmapImageRep *)extractRect:(NSRect)sel path:(NSBezierPath *)path {
    NSBitmapImageRep *flo = PNewRep((NSInteger)sel.size.width, (NSInteger)sel.size.height);
    NSGraphicsContext *raw = [NSGraphicsContext graphicsContextWithBitmapImageRep:flo];
    CGContextRef fc = raw.CGContext;
    CGContextSaveGState(fc);
    CGContextTranslateCTM(fc, 0, flo.pixelsHigh);
    CGContextScaleCTM(fc, 1, -1);
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:
        [NSGraphicsContext graphicsContextWithCGContext:fc flipped:YES]];
    if (path) {
        NSBezierPath *p = [path copy];
        NSAffineTransform *t = [NSAffineTransform transform];
        [t translateXBy:-sel.origin.x yBy:-sel.origin.y];
        [p transformUsingAffineTransform:t];
        [p addClip];
    }
    [self.bitmap drawInRect:NSMakeRect(-sel.origin.x, -sel.origin.y,
                                       self.bitmap.pixelsWide, self.bitmap.pixelsHigh)
                   fromRect:NSZeroRect operation:NSCompositingOperationCopy
                   fraction:1 respectFlipped:YES hints:PNearestHint()];
    CGContextRestoreGState(fc);
    [NSGraphicsContext restoreGraphicsState];
    return flo;
}

- (void)liftSelectionWithPath:(NSBezierPath *)path {
    NSRect sel = self.selRect;
    if (sel.size.width < 1 || sel.size.height < 1) return;
    [self snapshot];

    NSBitmapImageRep *flo = [self extractRect:sel path:path];

    // clear the source region to the background color (or to alpha 0)
    CGContextRef c = [self lockBitmap];
    CGContextSaveGState(c);
    if (path) {
        [path addClip];
    }
    CGContextSetBlendMode(c, kCGBlendModeCopy);
    NSColor *s = [self.bg colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    CGContextSetRGBFillColor(c, s.redComponent, s.greenComponent, s.blueComponent, s.alphaComponent);
    CGContextFillRect(c, sel);
    CGContextRestoreGState(c);
    [self unlockBitmap:c];

    self.floating = flo;
    self.floatOrigin = sel.origin;
}

- (NSBitmapImageRep *)maskedFloating {
    // transparent selection mode: pixels matching the background color drop out
    NSBitmapImageRep *m = PCloneRep(self.floating);
    uint8_t bgBytes[4];
    PBytes(self.bg, bgBytes);
    uint8_t *d = m.bitmapData;
    for (NSInteger y = 0; y < m.pixelsHigh; y++) {
        for (NSInteger x = 0; x < m.pixelsWide; x++) {
            uint8_t *p = d + y * m.bytesPerRow + x * 4;
            if (PNearEq(p, bgBytes)) memset(p, 0, 4);
        }
    }
    return m;
}

- (void)commitSelection {
    if (self.floating) {
        [self snapshot];
        CGContextRef c = [self lockBitmap];
        NSBitmapImageRep *img = self.selTransparent ? [self maskedFloating] : self.floating;
        [img drawInRect:NSMakeRect(self.floatOrigin.x, self.floatOrigin.y,
                                   img.pixelsWide, img.pixelsHigh)
               fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
               fraction:1 respectFlipped:YES hints:PNearestHint()];
        [self unlockBitmap:c];
        self.floating = nil;
    }
    self.hasSelection = NO;
    [self setNeedsDisplay:YES];
}

- (void)clearSelectionState {
    self.floating = nil;
    self.hasSelection = NO;
    self.lasso = nil;
}

- (void)deleteSelection {
    if (self.floating) {
        // region was already cleared on lift; just drop the pixels
        self.floating = nil;
        self.hasSelection = NO;
        [self setNeedsDisplay:YES];
        return;
    }
    if (!self.hasSelection) return;
    [self snapshot];
    CGContextRef c = [self lockBitmap];
    CGContextSetBlendMode(c, kCGBlendModeCopy);
    NSColor *s = [self.bg colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    CGContextSetRGBFillColor(c, s.redComponent, s.greenComponent, s.blueComponent, s.alphaComponent);
    CGContextFillRect(c, self.selRect);
    [self unlockBitmap:c];
    self.hasSelection = NO;
}

- (void)copySelection {
    NSBitmapImageRep *src = nil;
    if (self.floating) src = self.floating;
    else if (self.hasSelection) src = [self extractRect:self.selRect path:nil];
    if (!src) return;
    [self writeRepToPasteboard:src];
}

// PNG + TIFF: PNG keeps alpha exact, TIFF satisfies older paste targets
- (void)writeRepToPasteboard:(NSBitmapImageRep *)src {
    NSPasteboard *pb = NSPasteboard.generalPasteboard;
    [pb declareTypes:@[NSPasteboardTypePNG, NSPasteboardTypeTIFF] owner:nil];
    [pb setData:[src representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
        forType:NSPasteboardTypePNG];
    [pb setData:[src TIFFRepresentation] forType:NSPasteboardTypeTIFF];
}

- (void)cutSelection {
    if (!self.hasSelection && !self.floating) return;
    if (!self.floating) [self liftSelectionWithPath:nil];
    [self writeRepToPasteboard:self.floating];
    self.floating = nil;
    self.hasSelection = NO;
    [self setNeedsDisplay:YES];
}

- (void)pasteFromClipboard {
    NSImage *img = [[NSImage alloc] initWithPasteboard:NSPasteboard.generalPasteboard];
    [self pasteImage:img];
}

- (void)pasteImage:(NSImage *)img {
    if (!img) return;
    [self commitSelection];
    [self commitTextEditor];

    NSInteger w = MAX(1, (NSInteger)round(img.size.width));
    NSInteger h = MAX(1, (NSInteger)round(img.size.height));
    NSBitmapImageRep *flo = PNewRep(w, h);
    NSGraphicsContext *raw = [NSGraphicsContext graphicsContextWithBitmapImageRep:flo];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:raw];
    [img drawInRect:NSMakeRect(0, 0, w, h) fromRect:NSZeroRect
          operation:NSCompositingOperationCopy fraction:1];
    [NSGraphicsContext restoreGraphicsState];

    self.floating = flo;
    NSRect vis = self.visibleRect;
    self.floatOrigin = NSMakePoint(floor(vis.origin.x / self.zoom),
                                   floor(vis.origin.y / self.zoom));
    self.hasSelection = YES;
    [self setCurrentTool:PToolSelect];
    [self setNeedsDisplay:YES];
}

- (void)selectAll {
    [self commitSelection];
    [self setCurrentTool:PToolSelect];
    self.selRect = NSMakeRect(0, 0, self.bitmap.pixelsWide, self.bitmap.pixelsHigh);
    self.hasSelection = YES;
    [self setNeedsDisplay:YES];
}

- (NSBitmapImageRep *)selectionRep {
    if (self.floating) return self.floating;
    if (self.hasSelection) return [self extractRect:self.selRect path:nil];
    return nil;
}

- (void)cropToSelection {
    NSRect r;
    if (self.floating) {
        r = [self activeSelRect];
        [self commitSelection];
    } else if (self.hasSelection) {
        r = self.selRect;
        self.hasSelection = NO;
    } else {
        return;
    }
    r = NSIntersectionRect(NSIntegralRect(r),
                           NSMakeRect(0, 0, self.bitmap.pixelsWide, self.bitmap.pixelsHigh));
    if (r.size.width < 1 || r.size.height < 1) return;
    [self snapshot];
    self.bitmap = [self extractRect:r path:nil];
    [self updateFrame];
    [self markDirty];
    [self setNeedsDisplay:YES];
    [self updateStatusSize];
}

// XP Stretch/Skew: percentages scale, degrees shear; canvas grows to fit.
- (void)stretchHorizontal:(double)hPct vertical:(double)vPct
                    skewH:(double)hDeg skewV:(double)vDeg {
    double sx = hPct / 100.0, sy = vPct / 100.0;
    double tH = tan(hDeg * M_PI / 180.0), tV = tan(vDeg * M_PI / 180.0);
    if (sx <= 0 || sy <= 0) return;
    if (fabs(hDeg) >= 89 || fabs(vDeg) >= 89) return;
    if (sx == 1 && sy == 1 && tH == 0 && tV == 0) return;
    [self commitSelection];
    [self commitTextEditor];
    [self snapshot];

    NSInteger ow = self.bitmap.pixelsWide, oh = self.bitmap.pixelsHigh;
    double W1 = ow * sx, H1 = oh * sy;
    NSInteger nw = MAX(1, MIN(8192, (NSInteger)lround(W1 + fabs(tH) * H1)));
    NSInteger nh = MAX(1, MIN(8192, (NSInteger)lround(H1 + fabs(tV) * W1)));

    NSBitmapImageRep *out = PNewRep(nw, nh);
    NSGraphicsContext *raw = [NSGraphicsContext graphicsContextWithBitmapImageRep:out];
    CGContextRef c = raw.CGContext;
    CGContextSaveGState(c);
    CGContextTranslateCTM(c, tH < 0 ? fabs(tH) * H1 : 0, tV < 0 ? fabs(tV) * W1 : 0);
    CGContextConcatCTM(c, CGAffineTransformMake(sx, sx * tV, sy * tH, sy, 0, 0));
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:raw];
    NSGraphicsContext.currentContext.imageInterpolation = NSImageInterpolationNone;
    [self.bitmap drawInRect:NSMakeRect(0, 0, ow, oh) fromRect:NSZeroRect
                  operation:NSCompositingOperationSourceOver fraction:1
              respectFlipped:NO hints:PNearestHint()];
    [NSGraphicsContext restoreGraphicsState];
    CGContextRestoreGState(c);

    self.bitmap = out;
    [self updateFrame];
    [self markDirty];
    [self setNeedsDisplay:YES];
    [self updateStatusSize];
}

// ============================================================================
// Text tool
// ============================================================================
- (void)beginTextEditorInRect:(NSRect)r {
    [self commitTextEditor];
    self.textRect = r;
    NSTextView *tv = [[NSTextView alloc] initWithFrame:[self zoomRect:r]];
    tv.richText = NO;
    tv.usesFontPanel = YES;
    tv.font = [NSFont systemFontOfSize:14.0 * self.zoom];
    tv.textColor = self.fg.alphaComponent > 0.001 ? self.fg : [NSColor blackColor];
    if (self.selTransparent || self.bg.alphaComponent < 0.001) {
        tv.drawsBackground = NO;
    } else {
        tv.drawsBackground = YES;
        tv.backgroundColor = self.bg;
    }
    [self addSubview:tv];
    self.textEditor = tv;
    [self.window makeFirstResponder:tv];
    [self setNeedsDisplay:YES];
}

- (void)commitTextEditor {
    if (!self.textEditor) return;
    NSString *str = self.textEditor.string;
    NSFont *editorFont = self.textEditor.font ?: [NSFont systemFontOfSize:14.0 * self.zoom];
    NSRect r = self.textRect;
    [self.textEditor removeFromSuperview];
    self.textEditor = nil;
    if (str.length) {
        [self snapshot];
        CGContextRef c = [self lockBitmap];
        if (!self.selTransparent) {
            CGContextSetBlendMode(c, kCGBlendModeCopy);
            NSColor *s = [self.bg colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
            CGContextSetRGBFillColor(c, s.redComponent, s.greenComponent, s.blueComponent, s.alphaComponent);
            CGContextFillRect(c, r);
            CGContextSetBlendMode(c, kCGBlendModeNormal);
        }
        CGContextSetShouldAntialias(c, true);
        // editor font is displayed at zoom scale; commit at 1x
        NSFont *drawFont = [NSFont fontWithDescriptor:editorFont.fontDescriptor
                                                 size:MAX(1, editorFont.pointSize / self.zoom)]
                           ?: [NSFont systemFontOfSize:14.0];
        NSDictionary *attrs = @{
            NSFontAttributeName: drawFont,
            NSForegroundColorAttributeName: self.fg.alphaComponent > 0.001 ? self.fg : [NSColor blackColor]
        };
        [str drawInRect:r withAttributes:attrs];
        [self unlockBitmap:c];
    }
    [self setNeedsDisplay:YES];
}

- (void)discardTextEditor {
    if (!self.textEditor) return;
    [self.textEditor removeFromSuperview];
    self.textEditor = nil;
}

// ============================================================================
// Pixel access
// ============================================================================
- (NSColor *)pixelColorAt:(NSPoint)pt {
    uint8_t *p = self.bitmap.bitmapData
               + (NSInteger)pt.y * self.bitmap.bytesPerRow
               + (NSInteger)pt.x * 4;
    CGFloat a = p[3] / 255.0;
    if (a < 0.004) return [NSColor clearColor];
    return [NSColor colorWithSRGBRed:p[0] / (255.0 * a)
                               green:p[1] / (255.0 * a)
                                blue:p[2] / (255.0 * a)
                               alpha:a];
}

// ============================================================================
// Image menu operations
// ============================================================================
- (void)transformImageFlipH:(BOOL)fh flipV:(BOOL)fv rotate:(NSInteger)quarterTurnsCW {
    [self commitSelection];
    [self commitTextEditor];
    [self snapshot];

    NSInteger ow = self.bitmap.pixelsWide, oh = self.bitmap.pixelsHigh;
    BOOL swap = (quarterTurnsCW % 2) != 0;
    NSInteger nw = swap ? oh : ow, nh = swap ? ow : oh;

    NSBitmapImageRep *out = PNewRep(nw, nh);
    NSGraphicsContext *raw = [NSGraphicsContext graphicsContextWithBitmapImageRep:out];
    CGContextRef c = raw.CGContext;                     // bottom-left origin
    CGContextSaveGState(c);
    if (quarterTurnsCW == 1) {                          // 90° CW
        CGContextTranslateCTM(c, 0, nh);
        CGContextRotateCTM(c, -M_PI_2);
    } else if (quarterTurnsCW == 3) {                   // 90° CCW
        CGContextTranslateCTM(c, nw, 0);
        CGContextRotateCTM(c, M_PI_2);
    } else if (quarterTurnsCW == 2) {
        CGContextTranslateCTM(c, nw, nh);
        CGContextScaleCTM(c, -1, -1);
    }
    if (fh) { CGContextTranslateCTM(c, ow, 0); CGContextScaleCTM(c, -1, 1); }
    if (fv) { CGContextTranslateCTM(c, 0, oh); CGContextScaleCTM(c, 1, -1); }
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:raw];
    NSGraphicsContext.currentContext.imageInterpolation = NSImageInterpolationNone;
    [self.bitmap drawInRect:NSMakeRect(0, 0, ow, oh) fromRect:NSZeroRect
                  operation:NSCompositingOperationCopy fraction:1
              respectFlipped:NO hints:PNearestHint()];
    [NSGraphicsContext restoreGraphicsState];
    CGContextRestoreGState(c);

    self.bitmap = out;
    [self updateFrame];
    [self markDirty];
    [self setNeedsDisplay:YES];
}

- (void)invertColors {
    [self commitSelection];
    [self snapshot];
    uint8_t *d = self.bitmap.bitmapData;
    NSInteger bpr = self.bitmap.bytesPerRow;
    for (NSInteger y = 0; y < self.bitmap.pixelsHigh; y++) {
        for (NSInteger x = 0; x < self.bitmap.pixelsWide; x++) {
            uint8_t *p = d + y * bpr + x * 4;
            p[0] = p[3] - p[0];   // premultiplied: invert within alpha
            p[1] = p[3] - p[1];
            p[2] = p[3] - p[2];
        }
    }
    [self markDirty];
    [self setNeedsDisplay:YES];
}

- (void)resizeCanvasWidth:(NSInteger)w height:(NSInteger)h {
    if (w < 1 || h < 1 || (w == self.bitmap.pixelsWide && h == self.bitmap.pixelsHigh)) return;
    [self commitSelection];
    [self commitTextEditor];
    [self snapshot];

    NSBitmapImageRep *out = PNewRep(w, h);
    NSGraphicsContext *raw = [NSGraphicsContext graphicsContextWithBitmapImageRep:out];
    CGContextRef c = raw.CGContext;
    CGContextSaveGState(c);
    CGContextTranslateCTM(c, 0, h);
    CGContextScaleCTM(c, 1, -1);
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:
        [NSGraphicsContext graphicsContextWithCGContext:c flipped:YES]];
    // new area filled with background color
    CGContextSetBlendMode(c, kCGBlendModeCopy);
    NSColor *s = [self.bg colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    CGContextSetRGBFillColor(c, s.redComponent, s.greenComponent, s.blueComponent, s.alphaComponent);
    CGContextFillRect(c, CGRectMake(0, 0, w, h));
    CGContextSetBlendMode(c, kCGBlendModeNormal);
    [self.bitmap drawInRect:NSMakeRect(0, 0, self.bitmap.pixelsWide, self.bitmap.pixelsHigh)
                   fromRect:NSZeroRect operation:NSCompositingOperationCopy
                   fraction:1 respectFlipped:YES hints:PNearestHint()];
    [NSGraphicsContext restoreGraphicsState];
    CGContextRestoreGState(c);

    self.bitmap = out;
    [self updateFrame];
    [self markDirty];
    [self setNeedsDisplay:YES];
}

- (void)convertToMonochrome {
    [self commitSelection];
    [self commitTextEditor];
    [self snapshot];
    uint8_t *d = self.bitmap.bitmapData;
    NSInteger bpr = self.bitmap.bytesPerRow;
    for (NSInteger y = 0; y < self.bitmap.pixelsHigh; y++) {
        for (NSInteger x = 0; x < self.bitmap.pixelsWide; x++) {
            uint8_t *p = d + y * bpr + x * 4;
            uint8_t a = p[3];
            if (a == 0) continue;
            // premultiplied luminance vs half of alpha = 50% threshold
            double lum = 0.299 * p[0] + 0.587 * p[1] + 0.114 * p[2];
            uint8_t v = (lum >= a * 0.5) ? a : 0;   // premult white or black
            p[0] = v; p[1] = v; p[2] = v;
        }
    }
    [self markDirty];
    [self setNeedsDisplay:YES];
}

- (void)clearImage {
    [self commitSelection];
    [self commitTextEditor];
    [self snapshot];
    CGContextRef c = [self lockBitmap];
    CGContextSetBlendMode(c, kCGBlendModeCopy);
    NSColor *s = [self.bg colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    CGContextSetRGBFillColor(c, s.redComponent, s.greenComponent, s.blueComponent, s.alphaComponent);
    CGContextFillRect(c, CGRectMake(0, 0, self.bitmap.pixelsWide, self.bitmap.pixelsHigh));
    [self unlockBitmap:c];
}

// ============================================================================
// Keyboard, cursor, status bar
// ============================================================================
- (void)keyDown:(NSEvent *)e {
    NSString *chars = e.charactersIgnoringModifiers;
    if (chars.length == 0) { [super keyDown:e]; return; }
    unichar ch = [chars characterAtIndex:0];
    if (ch == NSDeleteCharacter || ch == NSDeleteFunctionKey) {
        [self deleteSelection];
        return;
    }
    if (ch == 27) { // escape: cancel selection (XP behavior)
        if (self.floating || self.hasSelection) {
            [self commitSelection];
            return;
        }
    }
    [super keyDown:e];
}

- (void)resetCursorRects {
    NSRect bmr = NSMakeRect(0, 0, self.bitmap.pixelsWide * self.zoom,
                                  self.bitmap.pixelsHigh * self.zoom);
    [self addCursorRect:bmr cursor:[NSCursor crosshairCursor]];
    [self addCursorRect:NSInsetRect([self handleRect:1], -2, -2)
                 cursor:[NSCursor resizeLeftRightCursor]];
    [self addCursorRect:NSInsetRect([self handleRect:2], -2, -2)
                 cursor:[NSCursor resizeUpDownCursor]];
    [self addCursorRect:NSInsetRect([self handleRect:3], -2, -2)
                 cursor:[NSCursor crosshairCursor]];
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *a in self.trackingAreas) [self removeTrackingArea:a];
    [self addTrackingArea:[[NSTrackingArea alloc]
        initWithRect:NSZeroRect
             options:NSTrackingMouseMoved | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
               owner:self userInfo:nil]];
}

- (void)mouseMoved:(NSEvent *)e {
    [self updateStatus:[self canvasPoint:e]];
}

- (void)updateStatus:(NSPoint)pt {
    self.statusPos.stringValue = [NSString stringWithFormat:@"%ld, %ld",
                                  (long)pt.x, (long)pt.y];
}

- (void)updateStatusSize {
    if (self.dragging && !self.floating &&
        (self.tool == PToolSelect || self.tool == PToolText ||
         self.tool == PToolRect || self.tool == PToolEllipse ||
         self.tool == PToolRoundRect || self.tool == PToolLine)) {
        NSRect r = PNormRect(self.dragStart, self.dragCur);
        self.statusSize.stringValue = [NSString stringWithFormat:@"%ld × %ld",
                                       (long)r.size.width, (long)r.size.height];
    } else {
        self.statusSize.stringValue = [NSString stringWithFormat:@"%ld × %ld",
                                       (long)self.bitmap.pixelsWide,
                                       (long)self.bitmap.pixelsHigh];
    }
}

@end
