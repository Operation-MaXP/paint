// ColorBarView — fg/bg indicator plus the 28-color XP palette and a
// transparent swatch. Left click = foreground, right click = background,
// clicking the indicator squares opens the color editor for that slot.
#import <Cocoa/Cocoa.h>
#import "CanvasView.h"

@interface ColorBarView : NSView
@property (weak) CanvasView *canvas;
@end
