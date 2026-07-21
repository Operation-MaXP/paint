// paintcore — tool vocabulary, XP palette, and pixel/CG helpers.
// Pure functions, no state. Everything else in the app builds on this.
#import <Cocoa/Cocoa.h>

// XP toolbox order, 2 columns x 8 rows
typedef NS_ENUM(NSInteger, PTool) {
    PToolFreeSelect = 0, PToolSelect,
    PToolEraser,         PToolFill,
    PToolPicker,         PToolZoom,
    PToolPencil,         PToolBrush,
    PToolAirbrush,       PToolText,
    PToolLine,           PToolCurve,
    PToolRect,           PToolPolygon,
    PToolEllipse,        PToolRoundRect
};

extern NSString * const PToolNames[16];
extern NSString * const PToolSymbols[16];
extern const uint8_t PPalette[28][3];       // XP 28-color palette

// Premultiplied sRGB bytes for a color (matches bitmap layout R G B A)
void PBytes(NSColor *color, uint8_t out[4]);
// Per-channel comparison with small tolerance
BOOL PNearEq(const uint8_t *a, const uint8_t *b);
// Fill / stroke color on a CGContext; fully transparent color paints "erase"
void PSetFill(CGContextRef c, NSColor *col);
void PSetStroke(CGContextRef c, NSColor *col);
// Normalized integral rect between two points
NSRect PNormRect(NSPoint a, NSPoint b);
// Fresh RGBA premultiplied bitmap (row 0 = top scanline), zero-filled
NSBitmapImageRep *PNewRep(NSInteger w, NSInteger h);
NSBitmapImageRep *PCloneRep(NSBitmapImageRep *src);
// Flood fill, 4-way, exact byte match on premultiplied RGBA
void PFlood(NSBitmapImageRep *rep, NSInteger sx, NSInteger sy, const uint8_t fill[4]);
// Drawing hints / shared pattern
NSDictionary *PNearestHint(void);
NSColor *PCheckerColor(void);
