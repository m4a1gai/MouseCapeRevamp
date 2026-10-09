//
//  MouseCapeBridge.h
//  Declarations for the private CoreGraphics / SkyLight / HIServices cursor APIs.
//
//  These are the same entry points the original Mousecape used. They still exist
//  on macOS 26, and the signatures below were verified against the live system
//  (see docs/FINDINGS.md). Nothing here is public API.
//

#ifndef MouseCapeBridge_h
#define MouseCapeBridge_h

#include <CoreGraphics/CoreGraphics.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdbool.h>

typedef int CGSConnectionID;
typedef int CGSCursorID;

/// The window-server connection for this process.
extern CGSConnectionID CGSMainConnectionID(void);

/// Bumps every time the displayed cursor changes.
extern int CGSCurrentCursorSeed(void);

/// Registers cursor art under `cursorName`, globally and across processes.
///
/// `imageArray` holds one CGImage per scale representation. Each image stacks all
/// `frameCount` frames vertically, so a 2x rep of a 24x24 cursor with 8 frames is
/// a 48x384 image. `cursorSize` is the logical size of a SINGLE frame in points;
/// the server infers each rep's scale from imageWidth / cursorSize.width.
///
/// NOTE: the window server silently ignores writes to the nine system-defined
/// names (com.apple.coregraphics.*) on macOS 26 - it still returns
/// kCGErrorSuccess. Always verify with CGSCopyRegisteredCursorImages.
extern CGError CGSRegisterCursorWithImages(CGSConnectionID cid,
                                           char *cursorName,
                                           bool setGlobally,
                                           bool instantly,
                                           CGSize cursorSize,
                                           CGPoint hotspot,
                                           unsigned long frameCount,
                                           CGFloat frameDuration,
                                           CFArrayRef imageArray,
                                           int *seed);

/// Reads back whatever art is currently registered for `cursorName`.
extern CGError CGSCopyRegisteredCursorImages(CGSConnectionID cid,
                                             char *cursorName,
                                             CGSize *imageSize,
                                             CGPoint *hotSpot,
                                             unsigned long *frameCount,
                                             CGFloat *frameDuration,
                                             CFArrayRef *imageArray);

/// Size in bytes of the registered ARGB data; 0 / error means "not registered".
extern CGError CGSGetRegisteredCursorDataSize(CGSConnectionID cid,
                                              char *cursorName,
                                              size_t *size);

/// Drops a single registration. Fails with kCGErrorFailure (1000) for the
/// protected com.apple.coregraphics.* names.
extern CGError CGSRemoveRegisteredCursor(CGSConnectionID cid,
                                         char *cursorName,
                                         bool unknownFlag);

/// Drops every cursor override and restores the stock system art.
/// This is the reset path - it is what makes the app safe to experiment with.
extern CGError CoreCursorUnregisterAll(CGSConnectionID cid);

/// Reads the stock art for a CoreCursor id (0 = arrow, 1 = I-beam, ...).
extern CGError CoreCursorCopyImages(CGSConnectionID cid,
                                    CGSCursorID cursorID,
                                    CFArrayRef *images,
                                    CGSize *imageSize,
                                    CGPoint *hotSpot,
                                    unsigned long *frameCount,
                                    CGFloat *frameDuration);

/// Sets this connection's cursor to a registered name. Used by the test pane
/// to show what a themed cursor actually looks like in use.
extern CGError CGSSetRegisteredCursor(CGSConnectionID cid, char *cursorName, int *seed);

/// Maps a system cursor id to its registered name, or NULL when the id is not
/// one of the nine system-defined cursors.
extern char *CGSCursorNameForSystemCursor(CGSCursorID cursor);

#endif /* MouseCapeBridge_h */
