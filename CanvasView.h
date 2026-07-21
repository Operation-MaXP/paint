// CanvasView — the drawing surface. This header is the whole public
// interface; drag, selection, and text internals live in CanvasView.m.
#import <Cocoa/Cocoa.h>
#import "paintcore.h"

@interface CanvasView : NSView

@property (strong) NSBitmapImageRep *bitmap;
@property (strong) NSUndoManager *undo;

@property PTool tool;
@property PTool prevTool;                 // picker returns here
@property (strong) NSColor *fg;
@property (strong) NSColor *bg;
@property NSInteger lineWidth;            // 1..5 — line, curve, shape outlines
@property NSInteger brushSize;            // 1,3,5,8
@property NSInteger brushShape;           // 0 round, 1 square, 2 slash, 3 backslash
@property NSInteger eraserSize;           // 4,6,8,10
@property NSInteger spraySize;            // 8,16,24
@property NSInteger shapeFill;            // 0 outline, 1 outline+fill, 2 fill
@property BOOL selTransparent;            // transparent selection / text bg
@property NSInteger zoom;                 // 1,2,6,8
@property BOOL showGrid;                  // pixel grid at zoom >= 2

// hooks to the rest of the UI
@property (weak) NSView *optionsView;
@property (weak) NSView *fgbgView;
@property (weak) NSView *thumbView;       // thumbnail panel content, if open
@property (weak) NSTextField *statusPos;
@property (weak) NSTextField *statusSize;
@property (copy) void (^onToolChanged)(void);

- (instancetype)initWithCanvasWidth:(NSInteger)w height:(NSInteger)h;
- (void)resetCanvasWidth:(NSInteger)w height:(NSInteger)h;

- (void)setCurrentTool:(PTool)t;
- (void)setZoomLevel:(NSInteger)z;
- (void)setZoomLevel:(NSInteger)z anchorCanvasPoint:(NSPoint)pt;
- (void)setForeground:(NSColor *)c;
- (void)setBackground:(NSColor *)c;

- (void)commitSelection;
- (void)commitTextEditor;
- (void)deleteSelection;
- (void)copySelection;
- (void)cutSelection;
- (void)pasteFromClipboard;
- (void)pasteImage:(NSImage *)img;        // Paste From… / clipboard share this
- (NSBitmapImageRep *)selectionRep;       // current selection pixels, or nil
- (void)selectAll;

- (void)transformImageFlipH:(BOOL)fh flipV:(BOOL)fv rotate:(NSInteger)quarterTurnsCW;
- (void)invertColors;
- (void)resizeCanvasWidth:(NSInteger)w height:(NSInteger)h;
- (void)stretchHorizontal:(double)hPct vertical:(double)vPct
                    skewH:(double)hDeg skewV:(double)vDeg;
- (void)cropToSelection;
- (void)convertToMonochrome;
- (void)clearImage;

- (void)updateStatusSize;

@end
