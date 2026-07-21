// OptionsView — the contextual box under the toolbox (line widths, sizes,
// fill modes, opaque/transparent, zoom levels).
#import <Cocoa/Cocoa.h>
#import "CanvasView.h"

@interface OptionsView : NSView
@property (weak) CanvasView *canvas;
@end
