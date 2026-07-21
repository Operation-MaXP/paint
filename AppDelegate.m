#import "AppDelegate.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "paintcore.h"
#import "CanvasView.h"
#import "OptionsView.h"
#import "ColorBarView.h"

// ---------------------------------------------------------------------------
// Thumbnail panel content — file-local helper, aspect-fit view of the bitmap.
// CanvasView pokes thumbView whenever it redisplays, so this stays live.
// ---------------------------------------------------------------------------
@interface PThumbView : NSView
@property (weak) CanvasView *canvas;
@end

@implementation PThumbView

- (void)drawRect:(NSRect)dirtyRect {
    [[NSColor windowBackgroundColor] setFill];
    NSRectFill(self.bounds);
    NSBitmapImageRep *b = self.canvas.bitmap;
    if (!b) return;
    NSRect area = NSInsetRect(self.bounds, 6, 6);
    double s = MIN(area.size.width / b.pixelsWide, area.size.height / b.pixelsHigh);
    NSRect dst = NSMakeRect(NSMidX(area) - b.pixelsWide * s / 2,
                            NSMidY(area) - b.pixelsHigh * s / 2,
                            b.pixelsWide * s, b.pixelsHigh * s);
    [PCheckerColor() setFill];
    NSRectFill(dst);
    NSGraphicsContext.currentContext.imageInterpolation = NSImageInterpolationNone;
    [b drawInRect:dst fromRect:NSZeroRect
        operation:NSCompositingOperationSourceOver fraction:1
    respectFlipped:YES hints:PNearestHint()];
    [[NSColor separatorColor] setStroke];
    [[NSBezierPath bezierPathWithRect:NSInsetRect(dst, 0.5, 0.5)] stroke];
}

@end

// View Bitmap: borderless full-screen preview, dismissed by any key or click.
@interface PViewBitmapWindow : NSWindow
@end

@implementation PViewBitmapWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (void)keyDown:(NSEvent *)e { [self orderOut:nil]; }
- (void)mouseDown:(NSEvent *)e { [self orderOut:nil]; }
- (void)rightMouseDown:(NSEvent *)e { [self orderOut:nil]; }
@end

@interface AppDelegate () <NSWindowDelegate, NSMenuItemValidation>
@property (strong) CanvasView *canvas;
@property (strong) NSScrollView *scroll;
@property (strong) OptionsView *options;
@property (strong) ColorBarView *colorBar;
@property (strong) NSMutableArray *toolButtons;
@property (strong) NSURL *documentURL;
@property (strong) NSPanel *thumbPanel;
@property (strong) PViewBitmapWindow *viewBitmapWindow;
@property (strong) NSTextField *statusPosLabel;
@property (strong) NSTextField *statusSizeLabel;
// save-as format popup
@property (strong) NSSavePanel *savePanel;
// attributes dialog state
@property (strong) NSTextField *attrWField;
@property (strong) NSTextField *attrHField;
@property (strong) NSButton *attrBWRadio;
@property NSInteger attrUnit;   // 0 inches, 1 cm, 2 pixels
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    NSWindow.allowsAutomaticWindowTabbing = NO;
    [self buildMenus];

    NSRect contentRect = NSMakeRect(0, 0, 940, 660);
    NSWindowStyleMask styleMask = NSWindowStyleMaskTitled |
                                  NSWindowStyleMaskClosable |
                                  NSWindowStyleMaskMiniaturizable |
                                  NSWindowStyleMaskResizable;
    self.window = [[NSWindow alloc] initWithContentRect:contentRect
                                              styleMask:styleMask
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    self.window.delegate = self;
    [self.window center];
    self.window.minSize = NSMakeSize(560, 420);

    NSView *content = self.window.contentView;
    CGFloat W = contentRect.size.width, H = contentRect.size.height;
    CGFloat statusH = 24, colorH = 40, toolW = 68;

    // --- canvas in a scroll view (right of the toolbox) ---
    self.canvas = [[CanvasView alloc] initWithCanvasWidth:640 height:480];

    self.scroll = [[NSScrollView alloc] initWithFrame:
        NSMakeRect(toolW, statusH + colorH, W - toolW, H - statusH - colorH)];
    self.scroll.hasVerticalScroller = YES;
    self.scroll.hasHorizontalScroller = YES;
    self.scroll.borderType = NSNoBorder;
    self.scroll.drawsBackground = YES;
    self.scroll.backgroundColor = [NSColor underPageBackgroundColor];
    self.scroll.documentView = self.canvas;
    self.scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [content addSubview:self.scroll];

    // --- toolbox: 2 x 8 grid pinned top-left ---
    self.toolButtons = [NSMutableArray array];
    CGFloat bs = 30, pad = 3, top = H - 6;
    for (NSInteger i = 0; i < 16; i++) {
        NSInteger row = i / 2, col = i % 2;
        NSButton *b = [[NSButton alloc] initWithFrame:
            NSMakeRect(pad + col * (bs + 2), top - bs - row * (bs + 2), bs, bs)];
        b.bezelStyle = NSBezelStyleTexturedSquare;
        [b setButtonType:NSButtonTypePushOnPushOff];
        NSImage *img = [NSImage imageWithSystemSymbolName:PToolSymbols[i]
                                 accessibilityDescription:PToolNames[i]];
        if (img) b.image = img; else b.title = [PToolNames[i] substringToIndex:1];
        b.toolTip = PToolNames[i];
        b.tag = i;
        b.target = self;
        b.action = @selector(toolClicked:);
        b.autoresizingMask = NSViewMinYMargin;
        b.state = (i == self.canvas.tool) ? NSControlStateValueOn : NSControlStateValueOff;
        [content addSubview:b];
        [self.toolButtons addObject:b];
    }

    // --- options box under the toolbox ---
    CGFloat optTop = top - 8 * (bs + 2) - 8;
    self.options = [[OptionsView alloc] initWithFrame:
        NSMakeRect(pad, optTop - 170, toolW - 2 * pad, 170)];
    self.options.canvas = self.canvas;
    self.options.autoresizingMask = NSViewMinYMargin;
    [content addSubview:self.options];

    // --- color bar across the bottom (above status bar) ---
    self.colorBar = [[ColorBarView alloc] initWithFrame:NSMakeRect(0, statusH, W, colorH)];
    self.colorBar.canvas = self.canvas;
    self.colorBar.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [content addSubview:self.colorBar];

    // --- status bar ---
    NSTextField *pos = [self statusLabel:NSMakeRect(8, 2, 140, 18)];
    NSTextField *size = [self statusLabel:NSMakeRect(160, 2, 200, 18)];
    [content addSubview:pos];
    [content addSubview:size];
    self.statusPosLabel = pos;
    self.statusSizeLabel = size;
    self.canvas.statusPos = pos;
    self.canvas.statusSize = size;
    [self.canvas updateStatusSize];

    // hooks
    self.canvas.optionsView = self.options;
    self.canvas.fgbgView = self.colorBar;
    __weak AppDelegate *weakSelf = self;
    self.canvas.onToolChanged = ^{ [weakSelf syncToolButtons]; };

    self.window.frameAutosaveName = @"PaintMainWindow";
    [self restoreSettings];
    [self updateTitle];
    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:self.canvas];
    [NSApp activate];
}

- (NSTextField *)statusLabel:(NSRect)frame {
    NSTextField *l = [NSTextField labelWithString:@""];
    l.frame = frame;
    l.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    l.textColor = [NSColor secondaryLabelColor];
    l.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
    return l;
}

- (void)toolClicked:(NSButton *)sender {
    [self.canvas setCurrentTool:(PTool)sender.tag];
    [self syncToolButtons];
}

- (void)syncToolButtons {
    for (NSButton *b in self.toolButtons)
        b.state = (b.tag == self.canvas.tool) ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)updateTitle {
    NSString *name = self.documentURL ? self.documentURL.lastPathComponent : @"untitled";
    self.window.title = [NSString stringWithFormat:@"%@ - Paint", name];
    self.window.representedURL = self.documentURL;
}

// ============================================================================
// Menus
// ============================================================================
- (void)buildMenus {
    NSMenu *mainMenu = [NSMenu new];

    // app menu
    NSMenuItem *appItem = [NSMenuItem new];
    [mainMenu addItem:appItem];
    NSMenu *appMenu = [NSMenu new];
    [appMenu addItemWithTitle:@"About Paint" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Hide Paint" action:@selector(hide:) keyEquivalent:@"h"];
    [appMenu addItemWithTitle:@"Quit Paint" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;

    // file
    NSMenuItem *fileItem = [NSMenuItem new];
    [mainMenu addItem:fileItem];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    [fileMenu addItemWithTitle:@"New" action:@selector(newDocument:) keyEquivalent:@"n"];
    [fileMenu addItemWithTitle:@"Open…" action:@selector(openDocument:) keyEquivalent:@"o"];
    NSMenuItem *recentItem = [fileMenu addItemWithTitle:@"Open Recent" action:nil keyEquivalent:@""];
    NSMenu *recentMenu = [[NSMenu alloc] initWithTitle:@"Open Recent"];
    [recentMenu addItemWithTitle:@"Clear Menu" action:@selector(clearRecentDocuments:) keyEquivalent:@""];
    recentItem.submenu = recentMenu;
    [fileMenu addItem:[NSMenuItem separatorItem]];
    [fileMenu addItemWithTitle:@"Save" action:@selector(saveDocument:) keyEquivalent:@"s"];
    NSMenuItem *saveAs = [fileMenu addItemWithTitle:@"Save As…" action:@selector(saveDocumentAs:) keyEquivalent:@"s"];
    saveAs.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [fileMenu addItem:[NSMenuItem separatorItem]];
    [fileMenu addItemWithTitle:@"Page Setup…" action:@selector(pageSetup:) keyEquivalent:@""];
    [fileMenu addItemWithTitle:@"Print…" action:@selector(printDocument:) keyEquivalent:@"p"];
    [fileMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *desktopItem = [fileMenu addItemWithTitle:@"Set As Desktop Picture" action:nil keyEquivalent:@""];
    NSMenu *desktopMenu = [[NSMenu alloc] initWithTitle:@"Set As Desktop Picture"];
    [desktopMenu addItemWithTitle:@"Fill Screen" action:@selector(setDesktopFill:) keyEquivalent:@""];
    [desktopMenu addItemWithTitle:@"Centered" action:@selector(setDesktopCentered:) keyEquivalent:@""];
    desktopItem.submenu = desktopMenu;
    [fileMenu addItem:[NSMenuItem separatorItem]];
    [fileMenu addItemWithTitle:@"Close" action:@selector(performClose:) keyEquivalent:@"w"];
    fileItem.submenu = fileMenu;

    // edit
    NSMenuItem *editItem = [NSMenuItem new];
    [mainMenu addItem:editItem];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenu addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
    NSMenuItem *redo = [editMenu addItemWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"z"];
    redo.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"Cut" action:@selector(cutAction:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copyAction:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(pasteAction:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAllAction:) keyEquivalent:@"a"];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"Copy To…" action:@selector(copyToAction:) keyEquivalent:@""];
    [editMenu addItemWithTitle:@"Paste From…" action:@selector(pasteFromAction:) keyEquivalent:@""];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"Delete Selection" action:@selector(deleteAction:) keyEquivalent:@""];
    editItem.submenu = editMenu;

    // view
    NSMenuItem *viewItem = [NSMenuItem new];
    [mainMenu addItem:viewItem];
    NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:@"View"];
    [viewMenu addItemWithTitle:@"Zoom In" action:@selector(zoomIn:) keyEquivalent:@"="];
    [viewMenu addItemWithTitle:@"Zoom Out" action:@selector(zoomOut:) keyEquivalent:@"-"];
    [viewMenu addItemWithTitle:@"Actual Size" action:@selector(zoomActual:) keyEquivalent:@"0"];
    [viewMenu addItem:[NSMenuItem separatorItem]];
    [viewMenu addItemWithTitle:@"Show Grid" action:@selector(toggleGrid:) keyEquivalent:@"g"];
    [viewMenu addItemWithTitle:@"Show Thumbnail" action:@selector(toggleThumbnail:) keyEquivalent:@""];
    [viewMenu addItem:[NSMenuItem separatorItem]];
    [viewMenu addItemWithTitle:@"Fonts…" action:@selector(showFonts:) keyEquivalent:@"t"];
    [viewMenu addItem:[NSMenuItem separatorItem]];
    [viewMenu addItemWithTitle:@"Tool Box" action:@selector(toggleToolBox:) keyEquivalent:@""];
    [viewMenu addItemWithTitle:@"Color Box" action:@selector(toggleColorBox:) keyEquivalent:@""];
    [viewMenu addItemWithTitle:@"Status Bar" action:@selector(toggleStatusBar:) keyEquivalent:@""];
    [viewMenu addItem:[NSMenuItem separatorItem]];
    [viewMenu addItemWithTitle:@"View Bitmap" action:@selector(viewBitmap:) keyEquivalent:@"f"];
    viewItem.submenu = viewMenu;

    // image
    NSMenuItem *imageItem = [NSMenuItem new];
    [mainMenu addItem:imageItem];
    NSMenu *imageMenu = [[NSMenu alloc] initWithTitle:@"Image"];
    [imageMenu addItemWithTitle:@"Flip Horizontal" action:@selector(flipH:) keyEquivalent:@""];
    [imageMenu addItemWithTitle:@"Flip Vertical" action:@selector(flipV:) keyEquivalent:@""];
    [imageMenu addItemWithTitle:@"Rotate 90° Clockwise" action:@selector(rotateCW:) keyEquivalent:@"r"];
    NSMenuItem *ccw = [imageMenu addItemWithTitle:@"Rotate 90° Counterclockwise" action:@selector(rotateCCW:) keyEquivalent:@"r"];
    ccw.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [imageMenu addItemWithTitle:@"Rotate 180°" action:@selector(rotate180:) keyEquivalent:@""];
    [imageMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *crop = [imageMenu addItemWithTitle:@"Crop to Selection" action:@selector(cropAction:) keyEquivalent:@"x"];
    crop.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [imageMenu addItemWithTitle:@"Stretch/Skew…" action:@selector(stretchSkewAction:) keyEquivalent:@""];
    [imageMenu addItem:[NSMenuItem separatorItem]];
    [imageMenu addItemWithTitle:@"Invert Colors" action:@selector(invertColorsAction:) keyEquivalent:@"i"];
    [imageMenu addItem:[NSMenuItem separatorItem]];
    [imageMenu addItemWithTitle:@"Attributes…" action:@selector(attributesAction:) keyEquivalent:@"e"];
    [imageMenu addItemWithTitle:@"Clear Image" action:@selector(clearImageAction:) keyEquivalent:@""];
    [imageMenu addItem:[NSMenuItem separatorItem]];
    [imageMenu addItemWithTitle:@"Draw Opaque" action:@selector(toggleDrawOpaque:) keyEquivalent:@""];
    imageItem.submenu = imageMenu;

    // colors
    NSMenuItem *colorsItem = [NSMenuItem new];
    [mainMenu addItem:colorsItem];
    NSMenu *colorsMenu = [[NSMenu alloc] initWithTitle:@"Colors"];
    [colorsMenu addItemWithTitle:@"Edit Colors…" action:@selector(editColors:) keyEquivalent:@""];
    colorsItem.submenu = colorsMenu;

    NSApp.mainMenu = mainMenu;
}

// menu actions ---------------------------------------------------------------
- (void)undo:(id)s { [self.canvas.undo undo]; }
- (void)redo:(id)s { [self.canvas.undo redo]; }

- (void)cutAction:(id)s    { [self.canvas cutSelection]; }
- (void)copyAction:(id)s   { [self.canvas copySelection]; }
- (void)pasteAction:(id)s  { [self.canvas pasteFromClipboard]; [self syncToolButtons]; }
- (void)selectAllAction:(id)s { [self.canvas selectAll]; [self syncToolButtons]; }
- (void)deleteAction:(id)s { [self.canvas deleteSelection]; }

- (void)zoomStep:(NSInteger)dir {
    static const NSInteger levels[4] = {1, 2, 6, 8};
    NSInteger i = 0;
    for (NSInteger k = 0; k < 4; k++) if (levels[k] == self.canvas.zoom) i = k;
    i = MAX(0, MIN(3, i + dir));
    NSRect vis = self.canvas.visibleRect;
    NSPoint center = NSMakePoint(NSMidX(vis) / self.canvas.zoom,
                                 NSMidY(vis) / self.canvas.zoom);
    [self.canvas setZoomLevel:levels[i] anchorCanvasPoint:center];
}
- (void)zoomIn:(id)s     { [self zoomStep:+1]; }
- (void)zoomOut:(id)s    { [self zoomStep:-1]; }
- (void)zoomActual:(id)s { [self.canvas setZoomLevel:1]; }

- (void)rotate180:(id)s { [self.canvas transformImageFlipH:NO flipV:NO rotate:2]; }
- (void)cropAction:(id)s { [self.canvas cropToSelection]; }
- (void)showFonts:(id)s { [[NSFontManager sharedFontManager] orderFrontFontPanel:self]; }

- (void)toggleGrid:(id)s {
    self.canvas.showGrid = !self.canvas.showGrid;
    [self.canvas setNeedsDisplay:YES];
}

- (void)toggleThumbnail:(id)s {
    if (!self.thumbPanel) {
        NSPanel *p = [[NSPanel alloc]
            initWithContentRect:NSMakeRect(0, 0, 210, 170)
                      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                NSWindowStyleMaskUtilityWindow | NSWindowStyleMaskResizable
                        backing:NSBackingStoreBuffered defer:NO];
        p.title = @"Thumbnail";
        p.floatingPanel = YES;
        PThumbView *tv = [[PThumbView alloc] initWithFrame:((NSView *)p.contentView).bounds];
        tv.canvas = self.canvas;
        tv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [p.contentView addSubview:tv];
        self.canvas.thumbView = tv;
        self.thumbPanel = p;
    }
    if (self.thumbPanel.visible) [self.thumbPanel orderOut:nil];
    else [self.thumbPanel orderFront:nil];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action == @selector(toggleGrid:))
        item.state = self.canvas.showGrid ? NSControlStateValueOn : NSControlStateValueOff;
    else if (item.action == @selector(toggleThumbnail:))
        item.state = self.thumbPanel.visible ? NSControlStateValueOn : NSControlStateValueOff;
    else if (item.action == @selector(toggleToolBox:))
        item.state = self.options.hidden ? NSControlStateValueOff : NSControlStateValueOn;
    else if (item.action == @selector(toggleColorBox:))
        item.state = self.colorBar.hidden ? NSControlStateValueOff : NSControlStateValueOn;
    else if (item.action == @selector(toggleStatusBar:))
        item.state = self.statusPosLabel.hidden ? NSControlStateValueOff : NSControlStateValueOn;
    else if (item.action == @selector(toggleDrawOpaque:))
        item.state = self.canvas.selTransparent ? NSControlStateValueOff : NSControlStateValueOn;
    return YES;
}

// ---------------------------------------------------------------------------
// Panel toggles — XP's View > Tool Box / Color Box / Status Bar
// ---------------------------------------------------------------------------
- (void)layoutPanels {
    NSView *content = self.window.contentView;
    CGFloat W = content.bounds.size.width, H = content.bounds.size.height;
    CGFloat statusH = self.statusPosLabel.hidden ? 0 : 24;
    CGFloat colorH  = self.colorBar.hidden ? 0 : 40;
    CGFloat toolW   = self.options.hidden ? 0 : 68;
    self.colorBar.frame = NSMakeRect(0, statusH, W, 40);
    self.scroll.frame = NSMakeRect(toolW, statusH + colorH,
                                   W - toolW, H - statusH - colorH);
}

- (void)toggleToolBox:(id)s {
    BOOL hide = !self.options.hidden;
    self.options.hidden = hide;
    for (NSButton *b in self.toolButtons) b.hidden = hide;
    [self layoutPanels];
}

- (void)toggleColorBox:(id)s {
    self.colorBar.hidden = !self.colorBar.hidden;
    [self layoutPanels];
}

- (void)toggleStatusBar:(id)s {
    BOOL hide = !self.statusPosLabel.hidden;
    self.statusPosLabel.hidden = hide;
    self.statusSizeLabel.hidden = hide;
    [self layoutPanels];
}

- (void)toggleDrawOpaque:(id)s {
    self.canvas.selTransparent = !self.canvas.selTransparent;
    [self.options setNeedsDisplay:YES];
    [self.canvas setNeedsDisplay:YES];
}

// ---------------------------------------------------------------------------
// View Bitmap — full-screen preview (XP Ctrl+F)
// ---------------------------------------------------------------------------
- (void)viewBitmap:(id)s {
    [self.canvas commitTextEditor];
    NSScreen *screen = self.window.screen ?: NSScreen.mainScreen;
    if (!self.viewBitmapWindow) {
        PViewBitmapWindow *w = [[PViewBitmapWindow alloc]
            initWithContentRect:screen.frame
                      styleMask:NSWindowStyleMaskBorderless
                        backing:NSBackingStoreBuffered defer:NO];
        w.backgroundColor = [NSColor blackColor];
        w.level = NSStatusWindowLevel;
        w.releasedWhenClosed = NO;
        PThumbView *v = [[PThumbView alloc] initWithFrame:((NSView *)w.contentView).bounds];
        v.canvas = self.canvas;
        v.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [w.contentView addSubview:v];
        self.viewBitmapWindow = w;
    }
    [self.viewBitmapWindow setFrame:screen.frame display:YES];
    [self.viewBitmapWindow makeKeyAndOrderFront:nil];
}

// ---------------------------------------------------------------------------
// Set As Desktop Picture — XP's Set As Background, macOS flavors
// ---------------------------------------------------------------------------
- (void)setDesktopFill:(id)s {
    [self setDesktopWithScaling:NSImageScaleProportionallyUpOrDown clipping:YES];
}

- (void)setDesktopCentered:(id)s {
    [self setDesktopWithScaling:NSImageScaleNone clipping:NO];
}

- (void)setDesktopWithScaling:(NSImageScaling)scaling clipping:(BOOL)clip {
    [self.canvas commitSelection];
    [self.canvas commitTextEditor];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *dir = [[fm URLForDirectory:NSApplicationSupportDirectory
                             inDomain:NSUserDomainMask
                    appropriateForURL:nil create:YES error:nil]
                  URLByAppendingPathComponent:@"paint" isDirectory:YES];
    [fm createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    // unique name so the wallpaper agent registers the change
    NSURL *url = [dir URLByAppendingPathComponent:
        [NSString stringWithFormat:@"desktop-%.0f.png", NSDate.date.timeIntervalSince1970]];
    NSData *data = [self.canvas.bitmap representationUsingType:NSBitmapImageFileTypePNG
                                                    properties:@{}];
    if (![data writeToURL:url atomically:YES]) return;
    NSDictionary *opts = @{
        NSWorkspaceDesktopImageScalingKey: @(scaling),
        NSWorkspaceDesktopImageAllowClippingKey: @(clip),
        NSWorkspaceDesktopImageFillColorKey: [NSColor blackColor],
    };
    for (NSScreen *screen in NSScreen.screens)
        [[NSWorkspace sharedWorkspace] setDesktopImageURL:url forScreen:screen
                                                  options:opts error:nil];
}

- (void)copyToAction:(id)s {
    NSBitmapImageRep *rep = [self.canvas selectionRep];
    if (!rep) { NSBeep(); return; }
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedContentTypes = @[UTTypePNG];
    panel.nameFieldStringValue = @"selection.png";
    if ([panel runModal] != NSModalResponseOK) return;
    NSData *data = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    [data writeToURL:panel.URL atomically:YES];
}

- (void)pasteFromAction:(id)s {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedContentTypes = @[UTTypeImage];
    if ([panel runModal] != NSModalResponseOK) return;
    NSImage *img = [[NSImage alloc] initWithContentsOfURL:panel.URL];
    [self.canvas pasteImage:img];
    [self syncToolButtons];
}

- (void)pageSetup:(id)s {
    [[NSPageLayout pageLayout] runModal];
}

- (void)printDocument:(id)s {
    [self.canvas commitSelection];
    [self.canvas commitTextEditor];
    NSBitmapImageRep *rep = PCloneRep(self.canvas.bitmap);
    NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(rep.pixelsWide, rep.pixelsHigh)];
    [img addRepresentation:rep];
    NSImageView *v = [[NSImageView alloc]
        initWithFrame:NSMakeRect(0, 0, rep.pixelsWide, rep.pixelsHigh)];
    v.image = img;
    NSPrintOperation *op = [NSPrintOperation printOperationWithView:v];
    [op runOperationModalForWindow:self.window delegate:nil
                    didRunSelector:NULL contextInfo:NULL];
}

- (void)stretchSkewAction:(id)s {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Stretch and Skew";
    [alert addButtonWithTitle:@"OK"];
    [alert addButtonWithTitle:@"Cancel"];

    NSView *acc = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 340, 120)];
    NSTextField *(^label)(NSString *, NSRect) = ^(NSString *t, NSRect f) {
        NSTextField *l = [NSTextField labelWithString:t];
        l.frame = f;
        [acc addSubview:l];
        return l;
    };
    NSTextField *(^field)(double, NSRect) = ^(double v, NSRect f) {
        NSTextField *tf = [[NSTextField alloc] initWithFrame:f];
        tf.doubleValue = v;
        [acc addSubview:tf];
        return tf;
    };

    label(@"Stretch", NSMakeRect(0, 96, 100, 17));
    label(@"Horizontal:", NSMakeRect(16, 70, 76, 17));
    NSTextField *shf = field(100, NSMakeRect(96, 66, 60, 24));
    label(@"%", NSMakeRect(160, 70, 16, 17));
    label(@"Vertical:", NSMakeRect(190, 70, 60, 17));
    NSTextField *svf = field(100, NSMakeRect(252, 66, 60, 24));
    label(@"%", NSMakeRect(316, 70, 16, 17));

    label(@"Skew", NSMakeRect(0, 40, 100, 17));
    label(@"Horizontal:", NSMakeRect(16, 14, 76, 17));
    NSTextField *khf = field(0, NSMakeRect(96, 10, 60, 24));
    label(@"°", NSMakeRect(160, 14, 16, 17));
    label(@"Vertical:", NSMakeRect(190, 14, 60, 17));
    NSTextField *kvf = field(0, NSMakeRect(252, 10, 60, 24));
    label(@"°", NSMakeRect(316, 14, 16, 17));

    alert.accessoryView = acc;
    if ([alert runModal] == NSAlertFirstButtonReturn)
        [self.canvas stretchHorizontal:shf.doubleValue vertical:svf.doubleValue
                                 skewH:khf.doubleValue skewV:kvf.doubleValue];
}

- (void)flipH:(id)s     { [self.canvas transformImageFlipH:YES flipV:NO rotate:0]; }
- (void)flipV:(id)s     { [self.canvas transformImageFlipH:NO flipV:YES rotate:0]; }
- (void)rotateCW:(id)s  { [self.canvas transformImageFlipH:NO flipV:NO rotate:1]; }
- (void)rotateCCW:(id)s { [self.canvas transformImageFlipH:NO flipV:NO rotate:3]; }
- (void)invertColorsAction:(id)s { [self.canvas invertColors]; }
- (void)clearImageAction:(id)s   { [self.canvas clearImage]; }

- (void)editColors:(id)s {
    NSColorPanel *panel = [NSColorPanel sharedColorPanel];
    panel.showsAlpha = YES;
    panel.target = self;
    panel.action = @selector(colorPanelChanged:);
    [panel orderFront:nil];
}

- (void)colorPanelChanged:(NSColorPanel *)panel {
    [self.canvas setForeground:panel.color];
    [self.colorBar setNeedsDisplay:YES];
}

// Attributes — XP-style: file info, width/height, units, colors, Default.
static const double kDPI = 72.0;

- (double)pxToUnit:(NSInteger)px {
    if (self.attrUnit == 0) return px / kDPI;
    if (self.attrUnit == 1) return px / kDPI * 2.54;
    return px;
}

- (NSInteger)unitToPx:(double)v {
    if (self.attrUnit == 0) return (NSInteger)lround(v * kDPI);
    if (self.attrUnit == 1) return (NSInteger)lround(v / 2.54 * kDPI);
    return (NSInteger)lround(v);
}

- (void)setAttrField:(NSTextField *)f toPx:(NSInteger)px {
    if (self.attrUnit == 2) f.stringValue = [NSString stringWithFormat:@"%ld", (long)px];
    else f.stringValue = [NSString stringWithFormat:@"%.2f", [self pxToUnit:px]];
}

- (void)attrUnitChanged:(NSButton *)sender {
    if (sender.tag == self.attrUnit) return;
    // read out in the old unit, re-display in the new one
    NSInteger wPx = [self unitToPx:self.attrWField.doubleValue];
    NSInteger hPx = [self unitToPx:self.attrHField.doubleValue];
    self.attrUnit = sender.tag;
    [self setAttrField:self.attrWField toPx:wPx];
    [self setAttrField:self.attrHField toPx:hPx];
}

- (void)attrColorsChanged:(NSButton *)sender {
    // grouping only; state is read from attrBWRadio on OK
}

- (void)attrDefault:(NSButton *)sender {
    [self setAttrField:self.attrWField toPx:640];
    [self setAttrField:self.attrHField toPx:480];
}

- (NSTextField *)attrInfoLabel:(NSString *)text y:(CGFloat)y {
    NSTextField *l = [NSTextField labelWithString:text];
    l.frame = NSMakeRect(0, y, 400, 17);
    l.font = [NSFont systemFontOfSize:12];
    return l;
}

- (void)attributesAction:(id)s {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Attributes";
    [alert addButtonWithTitle:@"OK"];
    [alert addButtonWithTitle:@"Cancel"];

    // file info lines (XP: File last saved / Size on disk / Resolution)
    NSString *lastSaved = @"Not Available", *sizeOnDisk = @"Not Available";
    if (self.documentURL) {
        NSDictionary *fa = [[NSFileManager defaultManager]
            attributesOfItemAtPath:self.documentURL.path error:nil];
        if (fa) {
            NSDate *mod = fa[NSFileModificationDate];
            if (mod != nil) {
                NSDateFormatter *df = [NSDateFormatter new];
                df.dateStyle = NSDateFormatterMediumStyle;
                df.timeStyle = NSDateFormatterShortStyle;
                lastSaved = [df stringFromDate:mod];
            }
            NSNumber *sz = fa[NSFileSize];
            if (sz != nil) sizeOnDisk = [NSByteCountFormatter
                stringFromByteCount:sz.longLongValue
                         countStyle:NSByteCountFormatterCountStyleFile];
        }
    }

    NSView *acc = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 208)];
    [acc addSubview:[self attrInfoLabel:
        [NSString stringWithFormat:@"File last saved:  %@", lastSaved] y:186]];
    [acc addSubview:[self attrInfoLabel:
        [NSString stringWithFormat:@"Size on disk:  %@", sizeOnDisk] y:166]];
    [acc addSubview:[self attrInfoLabel:
        [NSString stringWithFormat:@"Resolution:  %.0f dots per inch", kDPI] y:146]];

    // width / height / default
    self.attrUnit = 2;   // pixels
    NSTextField *wl = [NSTextField labelWithString:@"Width:"];
    wl.frame = NSMakeRect(0, 112, 48, 17);
    self.attrWField = [[NSTextField alloc] initWithFrame:NSMakeRect(50, 108, 72, 24)];
    NSTextField *hl = [NSTextField labelWithString:@"Height:"];
    hl.frame = NSMakeRect(138, 112, 52, 17);
    self.attrHField = [[NSTextField alloc] initWithFrame:NSMakeRect(192, 108, 72, 24)];
    [self setAttrField:self.attrWField toPx:self.canvas.bitmap.pixelsWide];
    [self setAttrField:self.attrHField toPx:self.canvas.bitmap.pixelsHigh];
    NSButton *def = [NSButton buttonWithTitle:@"Default"
                                       target:self action:@selector(attrDefault:)];
    def.frame = NSMakeRect(290, 106, 90, 28);
    [acc addSubview:wl];
    [acc addSubview:self.attrWField];
    [acc addSubview:hl];
    [acc addSubview:self.attrHField];
    [acc addSubview:def];

    // units radio group
    NSTextField *ul = [NSTextField labelWithString:@"Units:"];
    ul.frame = NSMakeRect(0, 68, 48, 17);
    [acc addSubview:ul];
    NSString *unitTitles[3] = {@"Inches", @"Cm", @"Pixels"};
    CGFloat ux[3] = {60, 160, 240};
    for (NSInteger i = 0; i < 3; i++) {
        NSButton *r = [NSButton radioButtonWithTitle:unitTitles[i]
                                              target:self action:@selector(attrUnitChanged:)];
        r.frame = NSMakeRect(ux[i], 66, 90, 20);
        r.tag = i;
        r.state = (i == 2) ? NSControlStateValueOn : NSControlStateValueOff;
        [acc addSubview:r];
    }

    // colors radio group
    NSTextField *cl = [NSTextField labelWithString:@"Colors:"];
    cl.frame = NSMakeRect(0, 28, 52, 17);
    [acc addSubview:cl];
    self.attrBWRadio = [NSButton radioButtonWithTitle:@"Black and white"
                                               target:self action:@selector(attrColorsChanged:)];
    self.attrBWRadio.frame = NSMakeRect(60, 26, 140, 20);
    NSButton *colorsRadio = [NSButton radioButtonWithTitle:@"Colors"
                                                    target:self action:@selector(attrColorsChanged:)];
    colorsRadio.frame = NSMakeRect(240, 26, 90, 20);
    colorsRadio.state = NSControlStateValueOn;
    [acc addSubview:self.attrBWRadio];
    [acc addSubview:colorsRadio];

    alert.accessoryView = acc;

    if ([alert runModal] == NSAlertFirstButtonReturn) {
        NSInteger w = MAX(1, MIN(8192, [self unitToPx:self.attrWField.doubleValue]));
        NSInteger h = MAX(1, MIN(8192, [self unitToPx:self.attrHField.doubleValue]));
        [self.canvas resizeCanvasWidth:w height:h];
        if (self.attrBWRadio.state == NSControlStateValueOn)
            [self.canvas convertToMonochrome];
    }
    self.attrWField = nil;
    self.attrHField = nil;
    self.attrBWRadio = nil;
}

// ============================================================================
// File I/O
// ============================================================================
- (void)newDocument:(id)s {
    if (![self confirmDiscard]) return;
    [self.canvas resetCanvasWidth:640 height:480];
    self.documentURL = nil;
    self.window.documentEdited = NO;
    [self updateTitle];
}

- (void)openDocument:(id)s {
    if (![self confirmDiscard]) return;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedContentTypes = @[UTTypeImage];
    if ([panel runModal] != NSModalResponseOK) return;
    [self loadImageAtURL:panel.URL];
}

- (BOOL)application:(NSApplication *)sender openFile:(NSString *)filename {
    if (![self confirmDiscard]) return NO;
    [self loadImageAtURL:[NSURL fileURLWithPath:filename]];
    return YES;
}

- (void)loadImageAtURL:(NSURL *)url {
    NSData *data = [NSData dataWithContentsOfURL:url];
    NSBitmapImageRep *loaded = [NSBitmapImageRep imageRepWithData:data];
    if (!loaded) return;

    NSInteger w = loaded.pixelsWide, h = loaded.pixelsHigh;
    [self.canvas resetCanvasWidth:w height:h];
    NSBitmapImageRep *dst = self.canvas.bitmap;
    NSGraphicsContext *raw = [NSGraphicsContext graphicsContextWithBitmapImageRep:dst];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:raw];
    [loaded drawInRect:NSMakeRect(0, 0, w, h) fromRect:NSZeroRect
             operation:NSCompositingOperationCopy fraction:1
         respectFlipped:NO hints:PNearestHint()];
    [NSGraphicsContext restoreGraphicsState];

    [self.canvas.undo removeAllActions];
    self.documentURL = url;
    self.window.documentEdited = NO;
    [[NSDocumentController sharedDocumentController] noteNewRecentDocumentURL:url];
    [self.canvas setNeedsDisplay:YES];
    [self.canvas updateStatusSize];
    [self updateTitle];
}

- (void)saveDocument:(id)s {
    if (!self.documentURL) { [self saveDocumentAs:s]; return; }
    [self writeImageToURL:self.documentURL];
}

- (void)formatChanged:(NSPopUpButton *)pop {
    UTType *t = UTTypePNG;
    NSString *title = pop.titleOfSelectedItem;
    if ([title isEqualToString:@"JPEG"]) t = UTTypeJPEG;
    else if ([title isEqualToString:@"BMP"]) t = UTTypeBMP;
    else if ([title isEqualToString:@"GIF"]) t = UTTypeGIF;
    else if ([title isEqualToString:@"TIFF"]) t = UTTypeTIFF;
    // single allowed type → the panel rewrites the filename extension itself
    self.savePanel.allowedContentTypes = @[t];
}

- (void)saveDocumentAs:(id)s {
    NSSavePanel *panel = [NSSavePanel savePanel];
    self.savePanel = panel;
    panel.allowedContentTypes = @[UTTypePNG];
    panel.nameFieldStringValue = self.documentURL ?
        self.documentURL.lastPathComponent : @"untitled.png";

    // Format: [PNG | JPEG | BMP | TIFF] accessory, like Preview's export
    NSView *acc = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 260, 32)];
    NSTextField *label = [NSTextField labelWithString:@"Format:"];
    label.frame = NSMakeRect(20, 8, 60, 17);
    NSPopUpButton *pop = [[NSPopUpButton alloc]
        initWithFrame:NSMakeRect(84, 3, 150, 26) pullsDown:NO];
    [pop addItemsWithTitles:@[@"PNG", @"JPEG", @"BMP", @"GIF", @"TIFF"]];
    NSString *ext = self.documentURL.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"]) {
        [pop selectItemWithTitle:@"JPEG"];
        panel.allowedContentTypes = @[UTTypeJPEG];
    } else if ([ext isEqualToString:@"bmp"]) {
        [pop selectItemWithTitle:@"BMP"];
        panel.allowedContentTypes = @[UTTypeBMP];
    } else if ([ext isEqualToString:@"gif"]) {
        [pop selectItemWithTitle:@"GIF"];
        panel.allowedContentTypes = @[UTTypeGIF];
    } else if ([ext isEqualToString:@"tiff"] || [ext isEqualToString:@"tif"]) {
        [pop selectItemWithTitle:@"TIFF"];
        panel.allowedContentTypes = @[UTTypeTIFF];
    }
    pop.target = self;
    pop.action = @selector(formatChanged:);
    [acc addSubview:label];
    [acc addSubview:pop];
    panel.accessoryView = acc;

    NSModalResponse r = [panel runModal];
    self.savePanel = nil;
    if (r != NSModalResponseOK) return;
    self.documentURL = panel.URL;
    [self writeImageToURL:panel.URL];
    [self updateTitle];
}

- (void)writeImageToURL:(NSURL *)url {
    [self.canvas commitSelection];
    [self.canvas commitTextEditor];

    NSString *ext = url.pathExtension.lowercaseString;
    NSBitmapImageRep *rep = self.canvas.bitmap;
    NSData *data;
    if ([ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"]) {
        // JPEG has no alpha: composite onto white first
        NSBitmapImageRep *flat = PNewRep(rep.pixelsWide, rep.pixelsHigh);
        NSGraphicsContext *raw = [NSGraphicsContext graphicsContextWithBitmapImageRep:flat];
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:raw];
        [[NSColor whiteColor] setFill];
        NSRectFill(NSMakeRect(0, 0, rep.pixelsWide, rep.pixelsHigh));
        [rep drawInRect:NSMakeRect(0, 0, rep.pixelsWide, rep.pixelsHigh)];
        [NSGraphicsContext restoreGraphicsState];
        data = [flat representationUsingType:NSBitmapImageFileTypeJPEG
                                  properties:@{NSImageCompressionFactor: @0.9}];
    } else if ([ext isEqualToString:@"bmp"]) {
        data = [rep representationUsingType:NSBitmapImageFileTypeBMP properties:@{}];
    } else if ([ext isEqualToString:@"gif"]) {
        data = [rep representationUsingType:NSBitmapImageFileTypeGIF
                                 properties:@{NSImageDitherTransparency: @YES}];
    } else if ([ext isEqualToString:@"tiff"] || [ext isEqualToString:@"tif"]) {
        data = [rep representationUsingType:NSBitmapImageFileTypeTIFF properties:@{}];
    } else {
        data = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    }
    if ([data writeToURL:url atomically:YES]) {
        self.window.documentEdited = NO;
        [[NSDocumentController sharedDocumentController] noteNewRecentDocumentURL:url];
    }
}

- (BOOL)confirmDiscard {
    if (!self.window.documentEdited) return YES;
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Save changes to your image?";
    [alert addButtonWithTitle:@"Save"];
    [alert addButtonWithTitle:@"Don't Save"];
    [alert addButtonWithTitle:@"Cancel"];
    NSModalResponse r = [alert runModal];
    if (r == NSAlertFirstButtonReturn) {
        [self saveDocument:nil];
        return !self.window.documentEdited;   // save may have been cancelled
    }
    if (r == NSAlertSecondButtonReturn) {
        self.window.documentEdited = NO;      // discarded: don't prompt again at quit
        return YES;
    }
    return NO;
}

// ============================================================================
// Window / app lifecycle
// ============================================================================
- (NSUndoManager *)windowWillReturnUndoManager:(NSWindow *)window {
    return self.canvas.undo;
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    return [self confirmDiscard];
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    return [self confirmDiscard] ? NSTerminateNow : NSTerminateCancel;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app {
    return YES;
}

- (void)applicationWillTerminate:(NSNotification *)aNotification {
    [self saveSettings];
}

// ---------------------------------------------------------------------------
// Settings persistence — tool, colors, sizes survive relaunch
// ---------------------------------------------------------------------------
static NSArray *PDefaultsFromColor(NSColor *c) {
    NSColor *s = [c colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    return @[@(s.redComponent), @(s.greenComponent), @(s.blueComponent), @(s.alphaComponent)];
}

static NSColor *PColorFromDefaults(id obj, NSColor *fallback) {
    if (![obj isKindOfClass:[NSArray class]] || [obj count] != 4) return fallback;
    NSArray *arr = obj;
    return [NSColor colorWithSRGBRed:[arr[0] doubleValue] green:[arr[1] doubleValue]
                                blue:[arr[2] doubleValue] alpha:[arr[3] doubleValue]];
}

- (void)saveSettings {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setInteger:self.canvas.tool forKey:@"tool"];
    [d setObject:PDefaultsFromColor(self.canvas.fg) forKey:@"fg"];
    [d setObject:PDefaultsFromColor(self.canvas.bg) forKey:@"bg"];
    [d setInteger:self.canvas.lineWidth forKey:@"lineWidth"];
    [d setInteger:self.canvas.brushSize forKey:@"brushSize"];
    [d setInteger:self.canvas.brushShape forKey:@"brushShape"];
    [d setInteger:self.canvas.eraserSize forKey:@"eraserSize"];
    [d setInteger:self.canvas.spraySize forKey:@"spraySize"];
    [d setInteger:self.canvas.shapeFill forKey:@"shapeFill"];
    [d setBool:self.canvas.selTransparent forKey:@"selTransparent"];
    [d setBool:self.canvas.showGrid forKey:@"showGrid"];
}

- (void)restoreSettings {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    CanvasView *cv = self.canvas;
    if ([d objectForKey:@"tool"]) {
        NSInteger t = [d integerForKey:@"tool"];
        if (t >= 0 && t < 16) [cv setCurrentTool:(PTool)t];
    }
    cv.fg = PColorFromDefaults([d objectForKey:@"fg"], cv.fg);
    cv.bg = PColorFromDefaults([d objectForKey:@"bg"], cv.bg);
    if ([d objectForKey:@"lineWidth"])
        cv.lineWidth = MAX(1, MIN(5, [d integerForKey:@"lineWidth"]));
    if ([d objectForKey:@"brushSize"]) cv.brushSize = [d integerForKey:@"brushSize"];
    if ([d objectForKey:@"brushShape"])
        cv.brushShape = MAX(0, MIN(3, [d integerForKey:@"brushShape"]));
    if ([d objectForKey:@"eraserSize"]) cv.eraserSize = [d integerForKey:@"eraserSize"];
    if ([d objectForKey:@"spraySize"]) cv.spraySize = [d integerForKey:@"spraySize"];
    if ([d objectForKey:@"shapeFill"])
        cv.shapeFill = MAX(0, MIN(2, [d integerForKey:@"shapeFill"]));
    cv.selTransparent = [d boolForKey:@"selTransparent"];
    cv.showGrid = [d boolForKey:@"showGrid"];
    [self syncToolButtons];
    [self.options setNeedsDisplay:YES];
    [self.colorBar setNeedsDisplay:YES];
}

@end
