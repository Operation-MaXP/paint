// paintcore — implementation. See paintcore.h for the interface.
#import "paintcore.h"

NSString * const PToolNames[16] = {
    @"Free-Form Select", @"Select", @"Eraser", @"Fill With Color",
    @"Pick Color", @"Magnifier", @"Pencil", @"Brush",
    @"Airbrush", @"Text", @"Line", @"Curve",
    @"Rectangle", @"Polygon", @"Ellipse", @"Rounded Rectangle"
};

NSString * const PToolSymbols[16] = {
    @"lasso", @"rectangle.dashed", @"eraser", @"drop.fill",
    @"eyedropper", @"magnifyingglass", @"pencil", @"paintbrush.pointed",
    @"aqi.medium", @"textformat", @"line.diagonal", @"scribble",
    @"rectangle", @"pentagon", @"oval", @"app"
};

// ---------------------------------------------------------------------------
// Small helpers

const uint8_t PPalette[28][3] = {
    {0,0,0},{128,128,128},{128,0,0},{128,128,0},{0,128,0},{0,128,128},{0,0,128},
    {128,0,128},{128,128,64},{0,64,64},{0,128,255},{0,64,128},{64,0,255},{128,64,0},
    {255,255,255},{192,192,192},{255,0,0},{255,255,0},{0,255,0},{0,255,255},{0,0,255},
    {255,0,255},{255,255,128},{0,255,128},{128,255,255},{128,128,255},{255,0,128},{255,128,64}
};


// Premultiplied sRGB bytes for a color (matches our bitmap layout: R G B A).
void PBytes(NSColor *color, uint8_t out[4]) {
    NSColor *s = [color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    CGFloat r = 0, g = 0, b = 0, a = 0;
    [s getRed:&r green:&g blue:&b alpha:&a];
    out[0] = (uint8_t)lround(r * a * 255.0);
    out[1] = (uint8_t)lround(g * a * 255.0);
    out[2] = (uint8_t)lround(b * a * 255.0);
    out[3] = (uint8_t)lround(a * 255.0);
}

BOOL PNearEq(const uint8_t *a, const uint8_t *b) {
    return llabs((long long)a[0] - b[0]) <= 3 &&
           llabs((long long)a[1] - b[1]) <= 3 &&
           llabs((long long)a[2] - b[2]) <= 3 &&
           llabs((long long)a[3] - b[3]) <= 3;
}

// Fill / stroke color on a CGContext; a fully transparent color paints "erase".
void PSetFill(CGContextRef c, NSColor *col) {
    if (col.alphaComponent < 0.001) {
        CGContextSetBlendMode(c, kCGBlendModeClear);
        CGContextSetRGBFillColor(c, 0, 0, 0, 1);
        return;
    }
    CGContextSetBlendMode(c, kCGBlendModeNormal);
    NSColor *s = [col colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    CGContextSetRGBFillColor(c, s.redComponent, s.greenComponent, s.blueComponent, s.alphaComponent);
}

void PSetStroke(CGContextRef c, NSColor *col) {
    if (col.alphaComponent < 0.001) {
        CGContextSetBlendMode(c, kCGBlendModeClear);
        CGContextSetRGBStrokeColor(c, 0, 0, 0, 1);
        return;
    }
    CGContextSetBlendMode(c, kCGBlendModeNormal);
    NSColor *s = [col colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    CGContextSetRGBStrokeColor(c, s.redComponent, s.greenComponent, s.blueComponent, s.alphaComponent);
}

NSRect PNormRect(NSPoint a, NSPoint b) {
    return NSIntegralRect(NSMakeRect(MIN(a.x, b.x), MIN(a.y, b.y),
                                     fabs(b.x - a.x), fabs(b.y - a.y)));
}

// Fresh RGBA premultiplied bitmap (row 0 = top scanline).
NSBitmapImageRep *PNewRep(NSInteger w, NSInteger h) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:w pixelsHigh:h
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
        colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:32];
    memset(rep.bitmapData, 0, rep.bytesPerRow * h);
    return rep;
}

NSBitmapImageRep *PCloneRep(NSBitmapImageRep *src) {
    NSBitmapImageRep *dst = PNewRep(src.pixelsWide, src.pixelsHigh);
    memcpy(dst.bitmapData, src.bitmapData, src.bytesPerRow * src.pixelsHigh);
    return dst;
}

// Scanline-free simple flood fill (4-way, exact byte match on premultiplied RGBA).
void PFlood(NSBitmapImageRep *rep, NSInteger sx, NSInteger sy, const uint8_t fill[4]) {
    NSInteger w = rep.pixelsWide, h = rep.pixelsHigh, bpr = rep.bytesPerRow;
    uint8_t *data = rep.bitmapData;
    if (sx < 0 || sy < 0 || sx >= w || sy >= h) return;
    uint8_t target[4];
    memcpy(target, data + sy * bpr + sx * 4, 4);
    if (memcmp(target, fill, 4) == 0) return;

    size_t cap = 1 << 16, top = 0;
    NSInteger *stack = malloc(cap * 2 * sizeof(NSInteger));
    stack[0] = sx; stack[1] = sy; top = 1;
    while (top) {
        top--;
        NSInteger x = stack[top * 2], y = stack[top * 2 + 1];
        if (x < 0 || y < 0 || x >= w || y >= h) continue;
        uint8_t *p = data + y * bpr + x * 4;
        if (memcmp(p, target, 4) != 0) continue;
        memcpy(p, fill, 4);
        if (top + 4 >= cap) { cap *= 2; stack = realloc(stack, cap * 2 * sizeof(NSInteger)); }
        stack[top * 2] = x + 1; stack[top * 2 + 1] = y;     top++;
        stack[top * 2] = x - 1; stack[top * 2 + 1] = y;     top++;
        stack[top * 2] = x;     stack[top * 2 + 1] = y + 1; top++;
        stack[top * 2] = x;     stack[top * 2 + 1] = y - 1; top++;
    }
    free(stack);
}

NSDictionary *PNearestHint(void) {
    return @{ NSImageHintInterpolation: @(NSImageInterpolationNone) };
}

// Shared checkerboard pattern color (transparency backdrop).
NSColor *PCheckerColor(void) {
    static NSColor *c = nil;
    if (!c) {
        NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(16, 16)];
        [img lockFocus];
        [[NSColor whiteColor] setFill]; NSRectFill(NSMakeRect(0, 0, 16, 16));
        [[NSColor colorWithWhite:0.78 alpha:1] setFill];
        NSRectFill(NSMakeRect(0, 0, 8, 8)); NSRectFill(NSMakeRect(8, 8, 8, 8));
        [img unlockFocus];
        c = [NSColor colorWithPatternImage:img];
    }
    return c;
}

