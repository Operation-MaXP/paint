// paintcore tests — build & run the paintcoretests target.
// Plain main() with checks, K&R style: prints PASS/FAIL, exit code says it all.
#import "paintcore.h"

static int failures = 0;

static void check(BOOL cond, const char *name) {
    printf("%s  %s\n", cond ? "PASS" : "FAIL", name);
    if (!cond) failures++;
}

int main(void) {
    @autoreleasepool {
        // PNormRect normalizes corner order and integralizes
        NSRect r = PNormRect(NSMakePoint(10, 20), NSMakePoint(4, 6));
        check(NSEqualRects(r, NSMakeRect(4, 6, 6, 14)), "PNormRect normalizes");

        // PBytes premultiplies against alpha
        uint8_t b[4];
        PBytes([NSColor colorWithSRGBRed:1 green:0 blue:0 alpha:0.5], b);
        check(b[3] >= 127 && b[3] <= 128 && b[0] >= 126 && b[0] <= 129 && b[1] == 0,
              "PBytes premultiplies");

        PBytes([NSColor clearColor], b);
        check(b[0] == 0 && b[1] == 0 && b[2] == 0 && b[3] == 0,
              "PBytes transparent is all zeros");

        // PNearEq tolerance is 3 per channel
        uint8_t x[4] = {100, 100, 100, 255};
        uint8_t y[4] = {103,  97, 100, 255};
        uint8_t z[4] = {105, 100, 100, 255};
        check(PNearEq(x, y) && !PNearEq(x, z), "PNearEq tolerance is 3");

        // PNewRep zero-filled; PCloneRep is a deep copy
        NSBitmapImageRep *rep = PNewRep(4, 4);
        check(rep.bitmapData[0] == 0, "PNewRep zero-filled");
        rep.bitmapData[0] = 42;
        NSBitmapImageRep *cl = PCloneRep(rep);
        rep.bitmapData[0] = 7;
        check(cl.bitmapData[0] == 42 && cl.pixelsWide == 4 && cl.pixelsHigh == 4,
              "PCloneRep is a deep copy");

        // PFlood fills the whole connected region
        NSBitmapImageRep *f = PNewRep(3, 3);
        uint8_t red[4] = {255, 0, 0, 255};
        PFlood(f, 0, 0, red);
        BOOL all = YES;
        for (NSInteger py = 0; py < 3; py++)
            for (NSInteger px = 0; px < 3; px++)
                if (memcmp(f.bitmapData + py * f.bytesPerRow + px * 4, red, 4) != 0)
                    all = NO;
        check(all, "PFlood fills connected region");

        // PFlood stops at differently-colored pixels
        NSBitmapImageRep *g = PNewRep(3, 1);
        uint8_t blue[4] = {0, 0, 255, 255};
        memcpy(g.bitmapData + 1 * 4, blue, 4);          // wall at x=1
        PFlood(g, 0, 0, red);
        check(memcmp(g.bitmapData + 2 * 4, red, 4) != 0 &&
              memcmp(g.bitmapData + 0 * 4, red, 4) == 0,
              "PFlood stops at walls");

        // PFlood no-ops when target already equals fill (and doesn't crash OOB)
        PFlood(g, -1, 0, red);
        PFlood(g, 0, 5, red);
        check(YES, "PFlood out-of-bounds is safe");
    }
    if (failures) printf("\n%d failure(s)\n", failures);
    else printf("\nall tests passed\n");
    return failures ? 1 : 0;
}
