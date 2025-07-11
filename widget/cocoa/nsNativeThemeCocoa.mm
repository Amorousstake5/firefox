/* -*- Mode: C++; tab-width: 2; indent-tabs-mode: nil; c-basic-offset: 2 -*- */
/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

#include "nsNativeThemeCocoa.h"
#include <objc/NSObjCRuntime.h>

#include "mozilla/gfx/2D.h"
#include "mozilla/gfx/Helpers.h"
#include "mozilla/gfx/PathHelpers.h"
#include "nsChildView.h"
#include "nsDeviceContext.h"
#include "nsLayoutUtils.h"
#include "nsObjCExceptions.h"
#include "nsNumberControlFrame.h"
#include "nsRect.h"
#include "nsSize.h"
#include "nsStyleConsts.h"
#include "nsPresContext.h"
#include "nsIContent.h"
#include "mozilla/dom/Document.h"
#include "nsIFrame.h"
#include "nsAtom.h"
#include "nsNameSpaceManager.h"
#include "nsPresContext.h"
#include "nsGkAtoms.h"
#include "nsCocoaFeatures.h"
#include "nsCocoaWindow.h"
#include "nsNativeThemeColors.h"
#include "mozilla/ClearOnShutdown.h"
#include "mozilla/Range.h"
#include "mozilla/dom/Element.h"
#include "mozilla/layers/StackingContextHelper.h"
#include "mozilla/StaticPrefs_layout.h"
#include "mozilla/StaticPrefs_widget.h"
#include "nsLookAndFeel.h"
#include "MacThemeGeometryType.h"
#include "VibrancyManager.h"

#include "gfxContext.h"
#include "gfxQuartzSurface.h"
#include "gfxQuartzNativeDrawing.h"
#include "gfxUtils.h"  // for ToDeviceColor
#include <algorithm>

using namespace mozilla;
using namespace mozilla::gfx;

#define DRAW_IN_FRAME_DEBUG 0
#define SCROLLBARS_VISUAL_DEBUG 0

// private Quartz routines needed here
extern "C" {
CG_EXTERN void CGContextSetCTM(CGContextRef, CGAffineTransform);
CG_EXTERN void CGContextSetBaseCTM(CGContextRef, CGAffineTransform);
typedef CFTypeRef CUIRendererRef;
void CUIDraw(CUIRendererRef r, CGRect rect, CGContextRef ctx,
             CFDictionaryRef options, CFDictionaryRef* result);
}

// Workaround for NSCell control tint drawing
// Without this workaround, NSCells are always drawn with the clear control tint
// as long as they're not attached to an NSControl which is a subview of an
// active window.
// XXXmstange Why doesn't Webkit need this?
@implementation NSCell (ControlTintWorkaround)
- (int)_realControlTint {
  return [self controlTint];
}
@end

// This is the window for our MOZCellDrawView. When an NSCell is drawn, some
// NSCell implementations look at the draw view's window to determine whether
// the cell should draw with the active look.
@interface MOZCellDrawWindow : NSWindow
@property BOOL cellsShouldLookActive;
@end

@implementation MOZCellDrawWindow

// Override three different methods, for good measure. The NSCell implementation
// could call any one of them.
- (BOOL)_hasActiveAppearance {
  return self.cellsShouldLookActive;
}
- (BOOL)hasKeyAppearance {
  return self.cellsShouldLookActive;
}
- (BOOL)_hasKeyAppearance {
  return self.cellsShouldLookActive;
}

@end

// The purpose of this class is to provide objects that can be used when drawing
// NSCells using drawWithFrame:inView: without causing any harm. Only a small
// number of methods are called on the draw view, among those "isFlipped" and
// "currentEditor": isFlipped needs to return YES in order to avoid drawing bugs
// on 10.4 (see bug 465069); currentEditor (which isn't even a method of
// NSView) will be called when drawing search fields, and we only provide it in
// order to prevent "unrecognized selector" exceptions.
// There's no need to pass the actual NSView that we're drawing into to
// drawWithFrame:inView:. What's more, doing so even causes unnecessary
// invalidations as soon as we draw a focusring!
// This class needs to be an NSControl so that NSTextFieldCell (and
// NSSearchFieldCell, which is a subclass of NSTextFieldCell) draws a focus
// ring.
@interface MOZCellDrawView : NSControl
// Called by NSTreeHeaderCell during drawing.
@property BOOL _drawingEndSeparator;
@end

@implementation MOZCellDrawView

- (BOOL)isFlipped {
  return YES;
}

- (NSText*)currentEditor {
  return nil;
}

@end

static void DrawFocusRingForCellIfNeeded(NSCell* aCell, NSRect aWithFrame,
                                         NSView* aInView) {
  if ([aCell showsFirstResponder]) {
    CGContextRef cgContext = [[NSGraphicsContext currentContext] CGContext];
    CGContextSaveGState(cgContext);

    // It's important to set the focus ring style before we enter the
    // transparency layer so that the transparency layer only contains
    // the normal button mask without the focus ring, and the conversion
    // to the focus ring shape happens only when the transparency layer is
    // ended.
    NSSetFocusRingStyle(NSFocusRingOnly);

    // We need to draw the whole button into a transparency layer because
    // many button types are composed of multiple parts, and if these parts
    // were drawn while the focus ring style was active, each individual part
    // would produce a focus ring for itself. But we only want one focus ring
    // for the whole button. The transparency layer is a way to merge the
    // individual button parts together before the focus ring shape is
    // calculated.
    CGContextBeginTransparencyLayerWithRect(cgContext,
                                            NSRectToCGRect(aWithFrame), 0);
    [aCell drawFocusRingMaskWithFrame:aWithFrame inView:aInView];
    CGContextEndTransparencyLayer(cgContext);

    CGContextRestoreGState(cgContext);
  }
}

static void DrawCellIncludingFocusRing(NSCell* aCell, NSRect aWithFrame,
                                       NSView* aInView) {
  [aCell drawWithFrame:aWithFrame inView:aInView];
  DrawFocusRingForCellIfNeeded(aCell, aWithFrame, aInView);
}

static constexpr CGFloat kMaxFocusRingWidth = 7;

enum class CocoaSize { Mini = 0, Small, Regular };
static constexpr size_t kControlSizeCount = 3;

template <typename T>
using PerSizeArray = EnumeratedArray<CocoaSize, T, kControlSizeCount>;

static CocoaSize EnumSizeForCocoaSize(NSControlSize cocoaControlSize) {
  switch (cocoaControlSize) {
    case NSControlSizeMini:
      return CocoaSize::Mini;
    case NSControlSizeSmall:
      return CocoaSize::Small;
    default:
      return CocoaSize::Regular;
  }
}

static NSControlSize ControlSizeForEnum(CocoaSize enumControlSize) {
  switch (enumControlSize) {
    case CocoaSize::Mini:
      return NSControlSizeMini;
    case CocoaSize::Small:
      return NSControlSizeSmall;
    case CocoaSize::Regular:
      return NSControlSizeRegular;
  }
  MOZ_ASSERT_UNREACHABLE("Unknown enum");
  return NSControlSizeRegular;
}

using CellMarginArray = PerSizeArray<IntMargin>;

static void InflateControlRect(NSRect* rect, NSControlSize cocoaControlSize,
                               const CellMarginArray& marginSet) {
  auto controlSize = EnumSizeForCocoaSize(cocoaControlSize);
  const IntMargin& buttonMargins = marginSet[controlSize];
  rect->origin.x -= buttonMargins.left;
  rect->origin.y -= buttonMargins.bottom;
  rect->size.width += buttonMargins.LeftRight();
  rect->size.height += buttonMargins.TopBottom();
}

static NSWindow* NativeWindowForFrame(nsIFrame* aFrame,
                                      nsIWidget** aTopLevelWidget = NULL) {
  if (!aFrame) return nil;

  nsIWidget* widget = aFrame->GetNearestWidget();
  if (!widget) return nil;

  nsIWidget* topLevelWidget = widget->GetTopLevelWidget();
  if (aTopLevelWidget) *aTopLevelWidget = topLevelWidget;

  return (NSWindow*)topLevelWidget->GetNativeData(NS_NATIVE_WINDOW);
}

static NSSize WindowButtonsSize(nsIFrame* aFrame) {
  NSWindow* window = NativeWindowForFrame(aFrame);
  if (!window) {
    // Return fallback values.
    return NSSize{54, 16};
  }

  NSRect buttonBox = NSZeroRect;
  NSButton* closeButton = [window standardWindowButton:NSWindowCloseButton];
  if (closeButton) {
    buttonBox = NSUnionRect(buttonBox, [closeButton frame]);
  }
  NSButton* minimizeButton =
      [window standardWindowButton:NSWindowMiniaturizeButton];
  if (minimizeButton) {
    buttonBox = NSUnionRect(buttonBox, [minimizeButton frame]);
  }
  NSButton* zoomButton = [window standardWindowButton:NSWindowZoomButton];
  if (zoomButton) {
    buttonBox = NSUnionRect(buttonBox, [zoomButton frame]);
  }
  return buttonBox.size;
}

static BOOL FrameIsInActiveWindow(nsIFrame* aFrame) {
  nsIWidget* topLevelWidget = NULL;
  NSWindow* win = NativeWindowForFrame(aFrame, &topLevelWidget);
  if (!topLevelWidget || !win) return YES;

  // XUL popups, e.g. the toolbar customization popup, can't become key windows,
  // but controls in these windows should still get the active look.
  if (topLevelWidget->GetWindowType() == widget::WindowType::Popup) {
    return YES;
  }
  if ([win isSheet]) {
    return [win isKeyWindow];
  }
  return [win isMainWindow] && ![win attachedSheet];
}

NS_IMPL_ISUPPORTS_INHERITED(nsNativeThemeCocoa, nsNativeTheme, nsITheme)

nsNativeThemeCocoa::nsNativeThemeCocoa() : ThemeCocoa(ScrollbarStyle()) {
  NS_OBJC_BEGIN_TRY_IGNORE_BLOCK;

  // provide a local autorelease pool, as this is called during startup
  // before the main event-loop pool is in place
  nsAutoreleasePool pool;

  mDisclosureButtonCell = [[NSButtonCell alloc] initTextCell:@""];
  [mDisclosureButtonCell setBezelStyle:NSBezelStyleRoundedDisclosure];
  [mDisclosureButtonCell setButtonType:NSButtonTypePushOnPushOff];
  [mDisclosureButtonCell setHighlightsBy:NSPushInCellMask];

  mHelpButtonCell = [[NSButtonCell alloc] initTextCell:@""];
  [mHelpButtonCell setBezelStyle:NSBezelStyleHelpButton];
  [mHelpButtonCell setButtonType:NSButtonTypeMomentaryPushIn];
  [mHelpButtonCell setHighlightsBy:NSPushInCellMask];

  mPushButtonCell = [[NSButtonCell alloc] initTextCell:@""];
  [mPushButtonCell setButtonType:NSButtonTypeMomentaryPushIn];
  [mPushButtonCell setHighlightsBy:NSPushInCellMask];

  mRadioButtonCell = [[NSButtonCell alloc] initTextCell:@""];
  [mRadioButtonCell setButtonType:NSButtonTypeRadio];

  mCheckboxCell = [[NSButtonCell alloc] initTextCell:@""];
  [mCheckboxCell setButtonType:NSButtonTypeSwitch];
  [mCheckboxCell setAllowsMixedState:YES];

  mTextFieldCell = [[NSTextFieldCell alloc] initTextCell:@""];
  [mTextFieldCell setBezeled:YES];
  [mTextFieldCell setEditable:YES];
  [mTextFieldCell setFocusRingType:NSFocusRingTypeExterior];

  mDropdownCell = [[NSPopUpButtonCell alloc] initTextCell:@"" pullsDown:NO];

  mComboBoxCell = [[NSComboBoxCell alloc] initTextCell:@""];
  [mComboBoxCell setBezeled:YES];
  [mComboBoxCell setEditable:YES];
  [mComboBoxCell setFocusRingType:NSFocusRingTypeExterior];

  mCellDrawView = [[MOZCellDrawView alloc] init];

  if (XRE_IsParentProcess()) {
    // Put the cell draw view into a window that is never shown.
    // This allows us to convince some NSCell implementations (such as
    // NSButtonCell for default buttons) to draw with the active appearance.
    // Another benefit of putting the draw view in a window is the fact that it
    // lets NSTextFieldCell (and its subclass NSSearchFieldCell) inherit the
    // current NSApplication effectiveAppearance automatically, so the field
    // adapts to Dark Mode correctly. We don't create this window when the
    // native theme is used in the content process because NSWindow creation
    // runs into the sandbox and because we never run default buttons in content
    // processes anyway.
    mCellDrawWindow = [[MOZCellDrawWindow alloc]
        initWithContentRect:NSZeroRect
                  styleMask:NSWindowStyleMaskBorderless
                    backing:NSBackingStoreBuffered
                      defer:NO];
    [mCellDrawWindow.contentView addSubview:mCellDrawView];
  }

  NS_OBJC_END_TRY_IGNORE_BLOCK;
}

nsNativeThemeCocoa::~nsNativeThemeCocoa() {
  NS_OBJC_BEGIN_TRY_IGNORE_BLOCK;

  [mDisclosureButtonCell release];
  [mHelpButtonCell release];
  [mPushButtonCell release];
  [mRadioButtonCell release];
  [mCheckboxCell release];
  [mTextFieldCell release];
  [mDropdownCell release];
  [mComboBoxCell release];
  [mCellDrawWindow release];
  [mCellDrawView release];

  NS_OBJC_END_TRY_IGNORE_BLOCK;
}

// Limit on the area of the target rect (in pixels^2) in
// DrawCellWithScaling() and DrawButton() and above which we
// don't draw the object into a bitmap buffer.  This is to avoid crashes in
// [NSGraphicsContext graphicsContextWithCGContext:flipped:] and
// CGContextDrawImage(), and also to avoid very poor drawing performance in
// CGContextDrawImage() when it scales the bitmap (particularly if xscale or
// yscale is less than but near 1 -- e.g. 0.9).  This value was determined
// by trial and error, on OS X 10.4.11 and 10.5.4, and on systems with
// different amounts of RAM.
#define BITMAP_MAX_AREA 500000

static int GetBackingScaleFactorForRendering(CGContextRef cgContext) {
  CGAffineTransform ctm =
      CGContextGetUserSpaceToDeviceSpaceTransform(cgContext);
  CGRect transformedUserSpacePixel =
      CGRectApplyAffineTransform(CGRectMake(0, 0, 1, 1), ctm);
  float maxScale = std::max(fabs(transformedUserSpacePixel.size.width),
                            fabs(transformedUserSpacePixel.size.height));
  return maxScale > 1.0 ? 2 : 1;
}

/*
 * Draw the given NSCell into the given cgContext.
 *
 * destRect - the size and position of the resulting control rectangle
 * controlSize - the NSControlSize which will be given to the NSCell before
 *  asking it to render
 * naturalSize - The natural dimensions of this control.
 *  If the control rect size is not equal to either of these, a scale
 *  will be applied to the context so that rendering the control at the
 *  natural size will result in it filling the destRect space.
 *  If a control has no natural dimensions in either/both axes, pass 0.0f.
 * minimumSize - The minimum dimensions of this control.
 *  If the control rect size is less than the minimum for a given axis,
 *  a scale will be applied to the context so that the minimum is used
 *  for drawing.  If a control has no minimum dimensions in either/both
 *  axes, pass 0.0f.
 * marginSet - an array of margins
 * view - The NSView that we're drawing into. As far as I can tell, it doesn't
 *  matter if this is really the right view; it just has to return YES when
 *  asked for isFlipped. Otherwise we'll get drawing bugs on 10.4.
 * mirrorHorizontal - whether to mirror the cell horizontally
 */
static void DrawCellWithScaling(NSCell* cell, CGContextRef cgContext,
                                const NSRect& destRect,
                                NSControlSize controlSize, NSSize naturalSize,
                                NSSize minimumSize,
                                const CellMarginArray& marginSet, NSView* view,
                                BOOL mirrorHorizontal) {
  NS_OBJC_BEGIN_TRY_IGNORE_BLOCK;

  NSRect drawRect = destRect;

  if (naturalSize.width != 0.0f) drawRect.size.width = naturalSize.width;
  if (naturalSize.height != 0.0f) drawRect.size.height = naturalSize.height;

  // Keep aspect ratio when scaling if one dimension is free.
  if (naturalSize.width == 0.0f && naturalSize.height != 0.0f)
    drawRect.size.width =
        destRect.size.width * naturalSize.height / destRect.size.height;
  if (naturalSize.height == 0.0f && naturalSize.width != 0.0f)
    drawRect.size.height =
        destRect.size.height * naturalSize.width / destRect.size.width;

  // Honor minimum sizes.
  if (drawRect.size.width < minimumSize.width)
    drawRect.size.width = minimumSize.width;
  if (drawRect.size.height < minimumSize.height)
    drawRect.size.height = minimumSize.height;

  [NSGraphicsContext saveGraphicsState];

  // Only skip the buffer if the area of our cell (in pixels^2) is too large.
  if (drawRect.size.width * drawRect.size.height > BITMAP_MAX_AREA) {
    // Inflate the rect Gecko gave us by the margin for the control.
    InflateControlRect(&drawRect, controlSize, marginSet);

    NSGraphicsContext* savedContext = [NSGraphicsContext currentContext];
    [NSGraphicsContext
        setCurrentContext:[NSGraphicsContext
                              graphicsContextWithCGContext:cgContext
                                                   flipped:YES]];

    DrawCellIncludingFocusRing(cell, drawRect, view);

    [NSGraphicsContext setCurrentContext:savedContext];
  } else {
    float w = ceil(drawRect.size.width);
    float h = ceil(drawRect.size.height);
    NSRect tmpRect = NSMakeRect(kMaxFocusRingWidth, kMaxFocusRingWidth, w, h);

    // inflate to figure out the frame we need to tell NSCell to draw in, to get
    // something that's 0,0,w,h
    InflateControlRect(&tmpRect, controlSize, marginSet);

    // and then, expand by kMaxFocusRingWidth size to make sure we can capture
    // any focus ring
    w += kMaxFocusRingWidth * 2.0;
    h += kMaxFocusRingWidth * 2.0;

    int backingScaleFactor = GetBackingScaleFactorForRendering(cgContext);
    CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(
        NULL, (int)w * backingScaleFactor, (int)h * backingScaleFactor, 8,
        (int)w * backingScaleFactor * 4, rgb, kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(rgb);

    // We need to flip the image twice in order to avoid drawing bugs on 10.4,
    // see bug 465069. This is the first flip transform, applied to cgContext.
    CGContextScaleCTM(cgContext, 1.0f, -1.0f);
    CGContextTranslateCTM(cgContext, 0.0f,
                          -(2.0 * destRect.origin.y + destRect.size.height));
    if (mirrorHorizontal) {
      CGContextScaleCTM(cgContext, -1.0f, 1.0f);
      CGContextTranslateCTM(
          cgContext, -(2.0 * destRect.origin.x + destRect.size.width), 0.0f);
    }

    NSGraphicsContext* savedContext = [NSGraphicsContext currentContext];
    [NSGraphicsContext
        setCurrentContext:[NSGraphicsContext graphicsContextWithCGContext:ctx
                                                                  flipped:YES]];

    CGContextScaleCTM(ctx, backingScaleFactor, backingScaleFactor);

    // Set the context's "base transform" to in order to get correctly-sized
    // focus rings.
    CGContextSetBaseCTM(ctx, CGAffineTransformMakeScale(backingScaleFactor,
                                                        backingScaleFactor));

    // This is the second flip transform, applied to ctx.
    CGContextScaleCTM(ctx, 1.0f, -1.0f);
    CGContextTranslateCTM(ctx, 0.0f,
                          -(2.0 * tmpRect.origin.y + tmpRect.size.height));

    DrawCellIncludingFocusRing(cell, tmpRect, view);

    [NSGraphicsContext setCurrentContext:savedContext];

    CGImageRef img = CGBitmapContextCreateImage(ctx);

    // Drop the image into the original destination rectangle, scaling to fit
    // Only scale kMaxFocusRingWidth by xscale/yscale when the resulting rect
    // doesn't extend beyond the overflow rect
    float xscale = destRect.size.width / drawRect.size.width;
    float yscale = destRect.size.height / drawRect.size.height;
    float scaledFocusRingX =
        xscale < 1.0f ? kMaxFocusRingWidth * xscale : kMaxFocusRingWidth;
    float scaledFocusRingY =
        yscale < 1.0f ? kMaxFocusRingWidth * yscale : kMaxFocusRingWidth;
    CGContextDrawImage(cgContext,
                       CGRectMake(destRect.origin.x - scaledFocusRingX,
                                  destRect.origin.y - scaledFocusRingY,
                                  destRect.size.width + scaledFocusRingX * 2,
                                  destRect.size.height + scaledFocusRingY * 2),
                       img);

    CGImageRelease(img);
    CGContextRelease(ctx);
  }

  [NSGraphicsContext restoreGraphicsState];

#if DRAW_IN_FRAME_DEBUG
  CGContextSetRGBFillColor(cgContext, 0.0, 0.0, 0.5, 0.25);
  CGContextFillRect(cgContext, destRect);
#endif

  NS_OBJC_END_TRY_IGNORE_BLOCK;
}

struct CellRenderSettings {
  // The natural dimensions of the control.
  // If a control has no natural dimensions in either/both axes, set to 0.0f.
  PerSizeArray<NSSize> naturalSizes;

  // The minimum dimensions of the control.
  // If a control has no minimum dimensions in either/both axes, set to 0.0f.
  PerSizeArray<NSSize> minimumSizes;

  // A margin array indexed by control size.
  PerSizeArray<IntMargin> margins;
};

/*
 * This is a helper method that returns the required NSControlSize given a size
 * and the size of the three controls plus a tolerance.
 * size - The width or the height of the element to draw.
 * sizes - An array with the all the width/height of the element for its
 *         different sizes.
 * tolerance - The tolerance as passed to DrawCellWithSnapping.
 * NOTE: returns NSControlSizeRegular if all values in 'sizes' are zero.
 */
static NSControlSize FindControlSize(CGFloat size,
                                     const PerSizeArray<CGFloat>& sizes,
                                     CGFloat tolerance) {
  for (size_t i = 0; i < kControlSizeCount; ++i) {
    if (sizes[CocoaSize(i)] == 0) {
      continue;
    }

    CGFloat next = 0;
    // Find next value.
    for (size_t j = i + 1; j < kControlSizeCount; ++j) {
      if (sizes[CocoaSize(j)] != 0) {
        next = sizes[CocoaSize(j)];
        break;
      }
    }

    // If it's the latest value, we pick it.
    if (next == 0) {
      return ControlSizeForEnum(CocoaSize(i));
    }

    if (size <= sizes[CocoaSize(i)] + tolerance && size < next) {
      return ControlSizeForEnum(CocoaSize(i));
    }
  }

  // If we are here, that means sizes[] was an array with only empty values
  // or the algorithm above is wrong.
  // The former can happen but the later would be wrong.
  NS_ASSERTION(
      std::all_of(sizes.begin(), sizes.end(), [](CGFloat s) { return s == 0; }),
      "We found no control! We shouldn't be there!");
  return ControlSizeForEnum(CocoaSize::Regular);
}

/*
 * Draw the given NSCell into the given cgContext with a nice control size.
 *
 * This function is similar to DrawCellWithScaling, but it decides what
 * control size to use based on the destRect's size.
 * Scaling is only applied when the difference between the destRect's size
 * and the next smaller natural size is greater than snapTolerance. Otherwise
 * it snaps to the next smaller control size without scaling because unscaled
 * controls look nicer.
 */
static void DrawCellWithSnapping(NSCell* cell, CGContextRef cgContext,
                                 const NSRect& destRect,
                                 const CellRenderSettings& settings,
                                 float verticalAlignFactor, NSView* view,
                                 BOOL mirrorHorizontal,
                                 float snapTolerance = 2.0f) {
  NS_OBJC_BEGIN_TRY_IGNORE_BLOCK;

  const float rectWidth = destRect.size.width;
  const float rectHeight = destRect.size.height;
  const PerSizeArray<NSSize>& sizes = settings.naturalSizes;
  const NSSize miniSize = sizes[EnumSizeForCocoaSize(NSControlSizeMini)];
  const NSSize smallSize = sizes[EnumSizeForCocoaSize(NSControlSizeSmall)];
  const NSSize regularSize = sizes[EnumSizeForCocoaSize(NSControlSizeRegular)];

  NSRect drawRect = destRect;

  PerSizeArray<CGFloat> controlWidths{miniSize.width, smallSize.width,
                                      regularSize.width};
  NSControlSize controlSizeX =
      FindControlSize(rectWidth, controlWidths, snapTolerance);
  PerSizeArray<CGFloat> controlHeights{miniSize.height, smallSize.height,
                                       regularSize.height};
  NSControlSize controlSizeY =
      FindControlSize(rectHeight, controlHeights, snapTolerance);

  NSControlSize controlSize = NSControlSizeRegular;
  CocoaSize sizeIndex = CocoaSize::Mini;

  // At some sizes, don't scale but snap.
  const NSControlSize smallerControlSize =
      EnumSizeForCocoaSize(controlSizeX) < EnumSizeForCocoaSize(controlSizeY)
          ? controlSizeX
          : controlSizeY;
  const auto smallerControlSizeIndex = EnumSizeForCocoaSize(smallerControlSize);
  const NSSize size = sizes[smallerControlSizeIndex];
  float diffWidth = size.width ? rectWidth - size.width : 0.0f;
  float diffHeight = size.height ? rectHeight - size.height : 0.0f;
  if (diffWidth >= 0.0f && diffHeight >= 0.0f && diffWidth <= snapTolerance &&
      diffHeight <= snapTolerance) {
    // Snap to the smaller control size.
    controlSize = smallerControlSize;
    sizeIndex = smallerControlSizeIndex;
    // Resize and center the drawRect.
    if (sizes[sizeIndex].width) {
      drawRect.origin.x +=
          ceil((destRect.size.width - sizes[sizeIndex].width) / 2);
      drawRect.size.width = sizes[sizeIndex].width;
    }
    if (sizes[sizeIndex].height) {
      drawRect.origin.y +=
          floor((destRect.size.height - sizes[sizeIndex].height) *
                verticalAlignFactor);
      drawRect.size.height = sizes[sizeIndex].height;
    }
  } else {
    // Use the larger control size.
    controlSize =
        EnumSizeForCocoaSize(controlSizeX) > EnumSizeForCocoaSize(controlSizeY)
            ? controlSizeX
            : controlSizeY;
    sizeIndex = EnumSizeForCocoaSize(controlSize);
  }

  [cell setControlSize:controlSize];

  const NSSize minimumSize = settings.minimumSizes[sizeIndex];
  DrawCellWithScaling(cell, cgContext, drawRect, controlSize, sizes[sizeIndex],
                      minimumSize, settings.margins, view, mirrorHorizontal);

  NS_OBJC_END_TRY_IGNORE_BLOCK;
}

static float VerticalAlignFactor(nsIFrame* aFrame) {
  if (!aFrame) return 0.5f;  // default: center

  const auto& va = aFrame->StyleDisplay()->mVerticalAlign;
  auto kw = va.IsKeyword() ? va.AsKeyword() : StyleVerticalAlignKeyword::Middle;
  switch (kw) {
    case StyleVerticalAlignKeyword::Top:
    case StyleVerticalAlignKeyword::TextTop:
      return 0.0f;

    case StyleVerticalAlignKeyword::Sub:
    case StyleVerticalAlignKeyword::Super:
    case StyleVerticalAlignKeyword::Middle:
    case StyleVerticalAlignKeyword::MozMiddleWithBaseline:
      return 0.5f;

    case StyleVerticalAlignKeyword::Baseline:
    case StyleVerticalAlignKeyword::Bottom:
    case StyleVerticalAlignKeyword::TextBottom:
      return 1.0f;

    default:
      MOZ_ASSERT_UNREACHABLE("invalid vertical-align");
      return 0.5f;
  }
}

static void ApplyControlParamsToNSCell(
    nsNativeThemeCocoa::ControlParams aControlParams, NSCell* aCell) {
  [aCell setEnabled:!aControlParams.disabled];
  [aCell setShowsFirstResponder:(aControlParams.focused &&
                                 !aControlParams.disabled &&
                                 aControlParams.insideActiveWindow)];
  [aCell setHighlighted:aControlParams.pressed];
}

// These are the sizes that Gecko needs to request to draw if it wants
// to get a standard-sized Aqua radio button drawn. Note that the rects
// that draw these are actually a little bigger.
constexpr static CellRenderSettings radioSettings = {
    {
        NSSize{11, 11},  // mini
        NSSize{13, 13},  // small
        NSSize{16, 16}   // regular
    },
    {NSSize{}, NSSize{}, NSSize{}},
    {
        IntMargin{0, 0, 0, 0},  // mini
        IntMargin{1, 1, 2, 1},  // small
        IntMargin{0, 0, 0, 0},  // regular
    },
};

constexpr static CellRenderSettings checkboxSettings = {
    {
        NSSize{11, 11},  // mini
        NSSize{13, 13},  // small
        NSSize{16, 16}   // regular
    },
    {NSSize{}, NSSize{}, NSSize{}},
    {
        IntMargin{1, 0, 0, 0},  // mini
        IntMargin{1, 0, 1, 0},  // small
        IntMargin{1, 0, 1, 0}   // regular
    }};

static NSControlStateValue CellStateForCheckboxOrRadioState(
    nsNativeThemeCocoa::CheckboxOrRadioState aState) {
  switch (aState) {
    case nsNativeThemeCocoa::CheckboxOrRadioState::eOff:
      return NSControlStateValueOff;
    case nsNativeThemeCocoa::CheckboxOrRadioState::eOn:
      return NSControlStateValueOn;
    case nsNativeThemeCocoa::CheckboxOrRadioState::eIndeterminate:
      return NSControlStateValueMixed;
  }
}

void nsNativeThemeCocoa::DrawCheckboxOrRadio(
    CGContextRef cgContext, bool inCheckbox, const NSRect& inBoxRect,
    const CheckboxOrRadioParams& aParams) {
  NS_OBJC_BEGIN_TRY_IGNORE_BLOCK;

  NSButtonCell* cell = inCheckbox ? mCheckboxCell : mRadioButtonCell;
  ApplyControlParamsToNSCell(aParams.controlParams, cell);

  [cell setState:CellStateForCheckboxOrRadioState(aParams.state)];
  [cell setControlTint:(aParams.controlParams.insideActiveWindow
                            ? [NSColor currentControlTint]
                            : NSClearControlTint)];

  // Ensure that the control is square.
  float length = std::min(inBoxRect.size.width, inBoxRect.size.height);
  NSRect drawRect = NSMakeRect(
      inBoxRect.origin.x + (int)((inBoxRect.size.width - length) / 2.0f),
      inBoxRect.origin.y + (int)((inBoxRect.size.height - length) / 2.0f),
      length, length);

  if (mCellDrawWindow) {
    mCellDrawWindow.cellsShouldLookActive =
        aParams.controlParams.insideActiveWindow;
  }
  DrawCellWithSnapping(cell, cgContext, drawRect,
                       inCheckbox ? checkboxSettings : radioSettings,
                       aParams.verticalAlignFactor, mCellDrawView, NO);

  NS_OBJC_END_TRY_IGNORE_BLOCK;
}

constexpr static CellRenderSettings searchFieldSettings = {
    {
        NSSize{0, 16},  // mini
        NSSize{0, 19},  // small
        NSSize{0, 22}   // regular
    },
    {
        NSSize{32, 0},  // mini
        NSSize{38, 0},  // small
        NSSize{44, 0}   // regular
    },
    {
        IntMargin{0, 0, 0, 0},  // mini
        IntMargin{0, 0, 0, 0},  // small
        IntMargin{0, 0, 0, 0}   // regular
    }};

static bool IsToolbarStyleContainer(nsIFrame* aFrame) {
  nsIContent* content = aFrame->GetContent();
  if (!content) {
    return false;
  }
  if (content->IsAnyOfXULElements(nsGkAtoms::toolbar, nsGkAtoms::toolbox,
                                  nsGkAtoms::statusbar)) {
    return true;
  }
  return false;
}

static bool IsInsideToolbar(nsIFrame* aFrame) {
  for (nsIFrame* frame = aFrame; frame; frame = frame->GetParent()) {
    if (IsToolbarStyleContainer(frame)) {
      return true;
    }
  }
  return false;
}

nsNativeThemeCocoa::TextFieldParams nsNativeThemeCocoa::ComputeTextFieldParams(
    nsIFrame* aFrame, ElementState aEventState) {
  TextFieldParams params;
  params.insideToolbar = IsInsideToolbar(aFrame);
  params.disabled = aEventState.HasState(ElementState::DISABLED);

  // See ShouldUnconditionallyDrawFocusRingIfFocused.
  params.focused = aEventState.HasState(ElementState::FOCUS);

  params.rtl = IsFrameRTL(aFrame);
  params.verticalAlignFactor = VerticalAlignFactor(aFrame);
  return params;
}

void nsNativeThemeCocoa::DrawTextField(CGContextRef cgContext,
                                       const NSRect& inBoxRect,
                                       const TextFieldParams& aParams) {
  NS_OBJC_BEGIN_TRY_IGNORE_BLOCK;

  NSTextFieldCell* cell = mTextFieldCell;
  [cell setEnabled:!aParams.disabled];
  [cell setShowsFirstResponder:aParams.focused];

  if (mCellDrawWindow) {
    mCellDrawWindow.cellsShouldLookActive =
        YES;  // TODO: propagate correct activeness state
  }
  DrawCellWithSnapping(cell, cgContext, inBoxRect, searchFieldSettings,
                       aParams.verticalAlignFactor, mCellDrawView, aParams.rtl);

  NS_OBJC_END_TRY_IGNORE_BLOCK;
}

static bool ShouldUnconditionallyDrawFocusRingIfFocused(nsIFrame* aFrame) {
  // Mac always draws focus rings for textboxes and lists.
  switch (aFrame->StyleDisplay()->EffectiveAppearance()) {
    case StyleAppearance::NumberInput:
    case StyleAppearance::PasswordInput:
    case StyleAppearance::Textfield:
    case StyleAppearance::Textarea:
      return true;
    default:
      return false;
  }
}

nsNativeThemeCocoa::ControlParams nsNativeThemeCocoa::ComputeControlParams(
    nsIFrame* aFrame, ElementState aEventState) {
  ControlParams params;
  params.disabled = aEventState.HasState(ElementState::DISABLED);
  params.insideActiveWindow = FrameIsInActiveWindow(aFrame);
  params.pressed =
      aEventState.HasAllStates(ElementState::ACTIVE | ElementState::HOVER);
  params.focused = aEventState.HasState(ElementState::FOCUS) &&
                   (aEventState.HasState(ElementState::FOCUSRING) ||
                    ShouldUnconditionallyDrawFocusRingIfFocused(aFrame));
  params.rtl = IsFrameRTL(aFrame);
  return params;
}

constexpr static NSSize kHelpButtonSize = NSSize{20, 20};
constexpr static NSSize kDisclosureButtonSize = NSSize{21, 21};

constexpr static CellRenderSettings pushButtonSettings = {
    {
        NSSize{0, 16},  // mini
        NSSize{0, 19},  // small
        NSSize{0, 22}   // regular
    },
    {
        NSSize{18, 0},  // mini
        NSSize{26, 0},  // small
        NSSize{30, 0}   // regular
    },
    {
        IntMargin{0, 0, 0, 0},  // mini
        IntMargin{0, 4, 1, 4},  // small
        IntMargin{0, 5, 2, 5}   // regular
    }};

// The height at which we start doing square buttons instead of rounded buttons
// Rounded buttons look bad if drawn at a height greater than 26, so at that
// point we switch over to doing square buttons which looks fine at any size.
#define DO_SQUARE_BUTTON_HEIGHT 26

void nsNativeThemeCocoa::DrawPushButton(CGContextRef cgContext,
                                        const NSRect& inBoxRect,
                                        ButtonType aButtonType,
                                        ControlParams aControlParams) {
  NS_OBJC_BEGIN_TRY_IGNORE_BLOCK;

  ApplyControlParamsToNSCell(aControlParams, mPushButtonCell);
  [mPushButtonCell setBezelStyle:NSBezelStyleRounded];
  mPushButtonCell.keyEquivalent =
      aButtonType == ButtonType::eDefaultPushButton ? @"\r" : @"";

  if (mCellDrawWindow) {
    mCellDrawWindow.cellsShouldLookActive = aControlParams.insideActiveWindow;
  }
  DrawCellWithSnapping(mPushButtonCell, cgContext, inBoxRect,
                       pushButtonSettings, 0.5f, mCellDrawView,
                       aControlParams.rtl, 1.0f);

  NS_OBJC_END_TRY_IGNORE_BLOCK;
}

void nsNativeThemeCocoa::DrawSquareBezelPushButton(
    CGContextRef cgContext, const NSRect& inBoxRect,
    ControlParams aControlParams) {
  NS_OBJC_BEGIN_TRY_IGNORE_BLOCK;

  ApplyControlParamsToNSCell(aControlParams, mPushButtonCell);
  [mPushButtonCell setBezelStyle:NSBezelStyleShadowlessSquare];

  if (mCellDrawWindow) {
    mCellDrawWindow.cellsShouldLookActive = aControlParams.insideActiveWindow;
  }
  DrawCellWithScaling(mPushButtonCell, cgContext, inBoxRect,
                      NSControlSizeRegular, NSSize{}, NSSize{14, 0}, {},
                      mCellDrawView, aControlParams.rtl);

  NS_OBJC_END_TRY_IGNORE_BLOCK;
}

void nsNativeThemeCocoa::DrawHelpButton(CGContextRef cgContext,
                                        const NSRect& inBoxRect,
                                        ControlParams aControlParams) {
  NS_OBJC_BEGIN_TRY_IGNORE_BLOCK;

  ApplyControlParamsToNSCell(aControlParams, mHelpButtonCell);

  if (mCellDrawWindow) {
    mCellDrawWindow.cellsShouldLookActive = aControlParams.insideActiveWindow;
  }
  DrawCellWithScaling(mHelpButtonCell, cgContext, inBoxRect,
                      NSControlSizeRegular, NSSize{}, kHelpButtonSize, {},
                      mCellDrawView,
                      false);  // Don't mirror icon in RTL.

  NS_OBJC_END_TRY_IGNORE_BLOCK;
}

void nsNativeThemeCocoa::DrawDisclosureButton(CGContextRef cgContext,
                                              const NSRect& inBoxRect,
                                              ControlParams aControlParams,
                                              NSControlStateValue aCellState) {
  NS_OBJC_BEGIN_TRY_IGNORE_BLOCK;

  ApplyControlParamsToNSCell(aControlParams, mDisclosureButtonCell);
  [mDisclosureButtonCell setState:aCellState];

  if (mCellDrawWindow) {
    mCellDrawWindow.cellsShouldLookActive = aControlParams.insideActiveWindow;
  }
  DrawCellWithScaling(mDisclosureButtonCell, cgContext, inBoxRect,
                      NSControlSizeRegular, NSSize{}, kDisclosureButtonSize, {},
                      mCellDrawView,
                      false);  // Don't mirror icon in RTL.

  NS_OBJC_END_TRY_IGNORE_BLOCK;
}

typedef void (*RenderHIThemeControlFunction)(CGContextRef cgContext,
                                             const NSRect& aRenderRect,
                                             void* aData);

static void RenderTransformedHIThemeControl(CGContextRef aCGContext,
                                            const NSRect& aRect,
                                            RenderHIThemeControlFunction aFunc,
                                            void* aData,
                                            BOOL mirrorHorizontally = NO) {
  CGAffineTransform savedCTM = CGContextGetCTM(aCGContext);
  CGContextTranslateCTM(aCGContext, aRect.origin.x, aRect.origin.y);

  bool drawDirect;
  NSRect drawRect = aRect;
  drawRect.origin = CGPointZero;

  if (!mirrorHorizontally && savedCTM.a == 1.0f && savedCTM.b == 0.0f &&
      savedCTM.c == 0.0f && (savedCTM.d == 1.0f || savedCTM.d == -1.0f)) {
    drawDirect = TRUE;
  } else {
    drawDirect = FALSE;
  }

  // Fall back to no bitmap buffer if the area of our control (in pixels^2)
  // is too large.
  if (drawDirect || (aRect.size.width * aRect.size.height > BITMAP_MAX_AREA)) {
    aFunc(aCGContext, drawRect, aData);
  } else {
    // Inflate the buffer to capture focus rings.
    int w = ceil(drawRect.size.width) + 2 * kMaxFocusRingWidth;
    int h = ceil(drawRect.size.height) + 2 * kMaxFocusRingWidth;

    int backingScaleFactor = GetBackingScaleFactorForRendering(aCGContext);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef bitmapctx = CGBitmapContextCreate(
        NULL, w * backingScaleFactor, h * backingScaleFactor, 8,
        w * backingScaleFactor * 4, colorSpace,
        kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(colorSpace);

    CGContextScaleCTM(bitmapctx, backingScaleFactor, backingScaleFactor);
    CGContextTranslateCTM(bitmapctx, kMaxFocusRingWidth, kMaxFocusRingWidth);

    // Set the context's "base transform" to in order to get correctly-sized
    // focus rings.
    CGContextSetBaseCTM(bitmapctx, CGAffineTransformMakeScale(
                                       backingScaleFactor, backingScaleFactor));

    // HITheme always wants to draw into a flipped context, or things
    // get confused.
    CGContextTranslateCTM(bitmapctx, 0.0f, aRect.size.height);
    CGContextScaleCTM(bitmapctx, 1.0f, -1.0f);

    aFunc(bitmapctx, drawRect, aData);

    CGImageRef bitmap = CGBitmapContextCreateImage(bitmapctx);

    CGAffineTransform ctm = CGContextGetCTM(aCGContext);

    // We need to unflip, so that we can do a DrawImage without getting a
    // flipped image.
    CGContextTranslateCTM(aCGContext, 0.0f, aRect.size.height);
    CGContextScaleCTM(aCGContext, 1.0f, -1.0f);

    if (mirrorHorizontally) {
      CGContextTranslateCTM(aCGContext, aRect.size.width, 0);
      CGContextScaleCTM(aCGContext, -1.0f, 1.0f);
    }

    NSRect inflatedDrawRect =
        CGRectMake(-kMaxFocusRingWidth, -kMaxFocusRingWidth, w, h);
    CGContextDrawImage(aCGContext, inflatedDrawRect, bitmap);

    CGContextSetCTM(aCGContext, ctm);

    CGImageRelease(bitmap);
    CGContextRelease(bitmapctx);
  }

  CGContextSetCTM(aCGContext, savedCTM);
}

static void RenderButton(CGContextRef cgContext, const NSRect& aRenderRect,
                         void* aData) {
  HIThemeButtonDrawInfo* bdi = (HIThemeButtonDrawInfo*)aData;
  HIThemeDrawButton(&aRenderRect, bdi, cgContext, kHIThemeOrientationNormal,
                    NULL);
}

void nsNativeThemeCocoa::DrawHIThemeButton(
    CGContextRef cgContext, const NSRect& aRect, ThemeButtonKind aKind,
    ThemeButtonValue aValue, ThemeDrawState aState,
    ThemeButtonAdornment aAdornment, const ControlParams& aParams) {
  NS_OBJC_BEGIN_TRY_IGNORE_BLOCK;

  HIThemeButtonDrawInfo bdi;
  bdi.version = 0;
  bdi.kind = aKind;
  bdi.value = aValue;
  bdi.state = aState;
  bdi.adornment = aAdornment;

  if (aParams.focused && aParams.insideActiveWindow) {
    bdi.adornment |= kThemeAdornmentFocus;
  }

  RenderTransformedHIThemeControl(cgContext, aRect, RenderButton, &bdi,
                                  aParams.rtl);

#if DRAW_IN_FRAME_DEBUG
  CGContextSetRGBFillColor(cgContext, 0.0, 0.0, 0.5, 0.25);
  CGContextFillRect(cgContext, inBoxRect);
#endif

  NS_OBJC_END_TRY_IGNORE_BLOCK;
}

void nsNativeThemeCocoa::DrawButton(CGContextRef cgContext,
                                    const NSRect& inBoxRect,
                                    const ButtonParams& aParams) {
  ControlParams controlParams = aParams.controlParams;

  switch (aParams.button) {
    case ButtonType::eRegularPushButton:
    case ButtonType::eDefaultPushButton:
      DrawPushButton(cgContext, inBoxRect, aParams.button, controlParams);
      return;
    case ButtonType::eSquareBezelPushButton:
      DrawSquareBezelPushButton(cgContext, inBoxRect, controlParams);
      return;
    case ButtonType::eArrowButton:
      DrawHIThemeButton(cgContext, inBoxRect, kThemeArrowButton, kThemeButtonOn,
                        kThemeStateUnavailable, kThemeAdornmentArrowDownArrow,
                        controlParams);
      return;
    case ButtonType::eHelpButton:
      DrawHelpButton(cgContext, inBoxRect, controlParams);
      return;
    case ButtonType::eDisclosureButtonClosed:
      DrawDisclosureButton(cgContext, inBoxRect, controlParams,
                           NSControlStateValueOff);
      return;
    case ButtonType::eDisclosureButtonOpen:
      DrawDisclosureButton(cgContext, inBoxRect, controlParams,
                           NSControlStateValueOn);
      return;
  }
}

constexpr static CellRenderSettings dropdownSettings = {
    {
        NSSize{0, 16},  // mini
        NSSize{0, 19},  // small
        NSSize{0, 22}   // regular
    },
    {
        NSSize{18, 0},  // mini
        NSSize{38, 0},  // small
        NSSize{44, 0}   // regular
    },
    {
        IntMargin{1, 2, 1, 1},  // mini
        IntMargin{0, 3, 1, 3},  // small
        IntMargin{0, 3, 0, 3}   // regular
    },
};

constexpr static CellRenderSettings editableMenulistSettings = {
    {
        NSSize{0, 15},  // mini
        NSSize{0, 18},  // small
        NSSize{0, 21}   // regular
    },
    {
        NSSize{18, 0},  // mini
        NSSize{38, 0},  // small
        NSSize{44, 0}   // regular
    },
    {
        IntMargin{0, 2, 2, 0},  // mini
        IntMargin{0, 3, 2, 0},  // small
        IntMargin{1, 3, 3, 0}   // regular
    }};

void nsNativeThemeCocoa::DrawDropdown(CGContextRef cgContext,
                                      const NSRect& inBoxRect,
                                      const DropdownParams& aParams) {
  NS_OBJC_BEGIN_TRY_IGNORE_BLOCK;

  [mDropdownCell setPullsDown:aParams.pullsDown];
  NSCell* cell =
      aParams.editable ? (NSCell*)mComboBoxCell : (NSCell*)mDropdownCell;

  ApplyControlParamsToNSCell(aParams.controlParams, cell);

  if (aParams.controlParams.insideActiveWindow) {
    [cell setControlTint:[NSColor currentControlTint]];
  } else {
    [cell setControlTint:NSClearControlTint];
  }

  const CellRenderSettings& settings =
      aParams.editable ? editableMenulistSettings : dropdownSettings;

  if (mCellDrawWindow) {
    mCellDrawWindow.cellsShouldLookActive =
        aParams.controlParams.insideActiveWindow;
  }
  DrawCellWithSnapping(cell, cgContext, inBoxRect, settings, 0.5f,
                       mCellDrawView, aParams.controlParams.rtl);

  NS_OBJC_END_TRY_IGNORE_BLOCK;
}

void nsNativeThemeCocoa::DrawMultilineTextField(CGContextRef cgContext,
                                                const CGRect& inBoxRect,
                                                bool aIsFocused) {
  mTextFieldCell.enabled = YES;
  mTextFieldCell.showsFirstResponder = aIsFocused;

  if (mCellDrawWindow) {
    mCellDrawWindow.cellsShouldLookActive = YES;
  }

  // DrawCellIncludingFocusRing draws into the current NSGraphicsContext, so do
  // the usual save+restore dance.
  NSGraphicsContext* savedContext = NSGraphicsContext.currentContext;
  NSGraphicsContext.currentContext =
      [NSGraphicsContext graphicsContextWithCGContext:cgContext flipped:YES];
  DrawCellIncludingFocusRing(mTextFieldCell, inBoxRect, mCellDrawView);
  NSGraphicsContext.currentContext = savedContext;
}

static bool IsHiDPIContext(nsDeviceContext* aContext) {
  return AppUnitsPerCSSPixel() >=
         2 * aContext->AppUnitsPerDevPixelAtUnitFullZoom();
}

Maybe<nsNativeThemeCocoa::WidgetInfo> nsNativeThemeCocoa::ComputeWidgetInfo(
    nsIFrame* aFrame, StyleAppearance aAppearance, const nsRect& aRect) {
  NS_OBJC_BEGIN_TRY_BLOCK_RETURN;

  // setup to draw into the correct port
  int32_t p2a = aFrame->PresContext()->AppUnitsPerDevPixel();

  gfx::Rect nativeWidgetRect(aRect.x, aRect.y, aRect.width, aRect.height);
  nativeWidgetRect.Scale(1.0 / gfxFloat(p2a));
  float originalHeight = nativeWidgetRect.Height();
  nativeWidgetRect.Round();
  if (nativeWidgetRect.IsEmpty()) {
    return Nothing();  // Don't attempt to draw invisible widgets.
  }

  bool hidpi = IsHiDPIContext(aFrame->PresContext()->DeviceContext());
  if (hidpi) {
    // Use high-resolution drawing.
    nativeWidgetRect.Scale(0.5f);
    originalHeight *= 0.5f;
  }

  ElementState elementState = GetContentState(aFrame, aAppearance);

  switch (aAppearance) {
    case StyleAppearance::Menupopup:
    case StyleAppearance::Tooltip:
      return Nothing();

    case StyleAppearance::Checkbox:
    case StyleAppearance::Radio: {
      bool isCheckbox = aAppearance == StyleAppearance::Checkbox;

      CheckboxOrRadioParams params;
      params.state = CheckboxOrRadioState::eOff;
      if (isCheckbox && elementState.HasState(ElementState::INDETERMINATE)) {
        params.state = CheckboxOrRadioState::eIndeterminate;
      } else if (elementState.HasState(ElementState::CHECKED)) {
        params.state = CheckboxOrRadioState::eOn;
      }
      params.controlParams = ComputeControlParams(aFrame, elementState);
      params.verticalAlignFactor = VerticalAlignFactor(aFrame);
      if (isCheckbox) {
        return Some(WidgetInfo::Checkbox(params));
      }
      return Some(WidgetInfo::Radio(params));
    }

    case StyleAppearance::Button:
      if (IsDefaultButton(aFrame)) {
        // Check whether the default button is in a document that does not
        // match the :-moz-window-inactive pseudoclass. This activeness check
        // is different from the other "active window" checks in this file
        // because we absolutely need the button's default button appearance to
        // be in sync with its text color, and the text color is changed by
        // such a :-moz-window-inactive rule. (That's because on 10.10 and up,
        // default buttons in active windows have blue background and white
        // text, and default buttons in inactive windows have white background
        // and black text.)
        DocumentState docState = aFrame->PresContext()->Document()->State();
        ControlParams params = ComputeControlParams(aFrame, elementState);
        params.insideActiveWindow =
            !docState.HasState(DocumentState::WINDOW_INACTIVE);
        return Some(WidgetInfo::Button(
            ButtonParams{params, ButtonType::eDefaultPushButton}));
      }
      if (IsButtonTypeMenu(aFrame)) {
        ControlParams controlParams =
            ComputeControlParams(aFrame, elementState);
        controlParams.pressed = IsOpenButton(aFrame);
        DropdownParams params;
        params.controlParams = controlParams;
        params.pullsDown = true;
        params.editable = false;
        return Some(WidgetInfo::Dropdown(params));
      }
      if (originalHeight > DO_SQUARE_BUTTON_HEIGHT) {
        // If the button is tall enough, draw the square button style so that
        // buttons with non-standard content look good. Otherwise draw normal
        // rounded aqua buttons.
        // This comparison is done based on the height that is calculated
        // without the top, because the snapped height can be affected by the
        // top of the rect and that may result in different height depending on
        // the top value.
        return Some(WidgetInfo::Button(
            ButtonParams{ComputeControlParams(aFrame, elementState),
                         ButtonType::eSquareBezelPushButton}));
      }
      return Some(WidgetInfo::Button(
          ButtonParams{ComputeControlParams(aFrame, elementState),
                       ButtonType::eRegularPushButton}));

    case StyleAppearance::MozMacHelpButton:
      return Some(WidgetInfo::Button(
          ButtonParams{ComputeControlParams(aFrame, elementState),
                       ButtonType::eHelpButton}));

    case StyleAppearance::MozMacDisclosureButtonOpen:
    case StyleAppearance::MozMacDisclosureButtonClosed: {
      ButtonType buttonType =
          (aAppearance == StyleAppearance::MozMacDisclosureButtonClosed)
              ? ButtonType::eDisclosureButtonClosed
              : ButtonType::eDisclosureButtonOpen;
      return Some(WidgetInfo::Button(ButtonParams{
          ComputeControlParams(aFrame, elementState), buttonType}));
    }

    case StyleAppearance::MozSidebar:
    case StyleAppearance::MozWindowTitlebar: {
      return Nothing();
    }

    case StyleAppearance::Menulist: {
      ControlParams controlParams = ComputeControlParams(aFrame, elementState);
      controlParams.pressed = IsOpenButton(aFrame);
      DropdownParams params;
      params.controlParams = controlParams;
      params.pullsDown = false;
      params.editable = false;
      return Some(WidgetInfo::Dropdown(params));
    }

    case StyleAppearance::MozMenulistArrowButton:
      return Some(WidgetInfo::Button(
          ButtonParams{ComputeControlParams(aFrame, elementState),
                       ButtonType::eArrowButton}));

    case StyleAppearance::Textfield:
    case StyleAppearance::NumberInput:
    case StyleAppearance::PasswordInput:
      return Some(
          WidgetInfo::TextField(ComputeTextFieldParams(aFrame, elementState)));

    case StyleAppearance::Textarea:
      return Some(WidgetInfo::MultilineTextField(
          elementState.HasState(ElementState::FOCUS)));

    default:
      break;
  }

  return Nothing();

  NS_OBJC_END_TRY_BLOCK_RETURN(Nothing());
}

void nsNativeThemeCocoa::DrawWidgetBackground(
    gfxContext* aContext, nsIFrame* aFrame, StyleAppearance aAppearance,
    const nsRect& aRect, const nsRect& aDirtyRect, DrawOverflow aDrawOverflow) {
  NS_OBJC_BEGIN_TRY_IGNORE_BLOCK;

  if (IsWidgetAlwaysNonNative(aFrame, aAppearance)) {
    return ThemeCocoa::DrawWidgetBackground(aContext, aFrame, aAppearance,
                                            aRect, aDirtyRect, aDrawOverflow);
  }

  Maybe<WidgetInfo> widgetInfo = ComputeWidgetInfo(aFrame, aAppearance, aRect);

  if (!widgetInfo) {
    return;
  }

  int32_t p2a = aFrame->PresContext()->AppUnitsPerDevPixel();

  gfx::Rect nativeWidgetRect = NSRectToRect(aRect, p2a);
  nativeWidgetRect.Round();

  bool hidpi = IsHiDPIContext(aFrame->PresContext()->DeviceContext());

  auto colorScheme = LookAndFeel::ColorSchemeForFrame(aFrame);

  RenderWidget(*widgetInfo, colorScheme, *aContext->GetDrawTarget(),
               nativeWidgetRect, NSRectToRect(aDirtyRect, p2a),
               hidpi ? 2.0f : 1.0f);

  NS_OBJC_END_TRY_IGNORE_BLOCK
}

void nsNativeThemeCocoa::RenderWidget(const WidgetInfo& aWidgetInfo,
                                      LookAndFeel::ColorScheme aScheme,
                                      DrawTarget& aDrawTarget,
                                      const gfx::Rect& aWidgetRect,
                                      const gfx::Rect& aDirtyRect,
                                      float aScale) {
  // Some of the drawing below uses NSAppearance.currentAppearance behind the
  // scenes. Set it to the appearance we want, the same way as
  // nsLookAndFeel::NativeGetColor.
  NSAppearance.currentAppearance = NSAppearanceForColorScheme(aScheme);

  // Also set the cell draw window's appearance; this is respected by
  // NSTextFieldCell (and its subclass NSSearchFieldCell).
  if (mCellDrawWindow) {
    mCellDrawWindow.appearance = NSAppearance.currentAppearance;
  }

  const Widget widget = aWidgetInfo.Widget();

  AutoRestoreTransform autoRestoreTransform(&aDrawTarget);
  gfx::Rect widgetRect = aWidgetRect;
  gfx::Rect dirtyRect = aDirtyRect;

  dirtyRect.Scale(1.0f / aScale);
  widgetRect.Scale(1.0f / aScale);
  aDrawTarget.SetTransform(aDrawTarget.GetTransform().PreScale(aScale, aScale));

  // The remaining widgets require a CGContext.
  CGRect macRect = CGRectMake(widgetRect.X(), widgetRect.Y(),
                              widgetRect.Width(), widgetRect.Height());

  gfxQuartzNativeDrawing nativeDrawing(aDrawTarget, dirtyRect);

  CGContextRef cgContext = nativeDrawing.BeginNativeDrawing();
  if (cgContext == nullptr) {
    // The Quartz surface handles 0x0 surfaces by internally
    // making all operations no-ops; there's no cgcontext created for them.
    // Unfortunately, this means that callers that want to render
    // directly to the CGContext need to be aware of this quirk.
    return;
  }

  // Set the context's "base transform" to in order to get correctly-sized
  // focus rings.
  CGContextSetBaseCTM(cgContext, CGAffineTransformMakeScale(aScale, aScale));

  switch (widget) {
    case Widget::eCheckbox: {
      CheckboxOrRadioParams params =
          aWidgetInfo.Params<CheckboxOrRadioParams>();
      DrawCheckboxOrRadio(cgContext, true, macRect, params);
      break;
    }
    case Widget::eRadio: {
      CheckboxOrRadioParams params =
          aWidgetInfo.Params<CheckboxOrRadioParams>();
      DrawCheckboxOrRadio(cgContext, false, macRect, params);
      break;
    }
    case Widget::eButton: {
      ButtonParams params = aWidgetInfo.Params<ButtonParams>();
      DrawButton(cgContext, macRect, params);
      break;
    }
    case Widget::eDropdown: {
      DropdownParams params = aWidgetInfo.Params<DropdownParams>();
      DrawDropdown(cgContext, macRect, params);
      break;
    }
    case Widget::eTextField: {
      TextFieldParams params = aWidgetInfo.Params<TextFieldParams>();
      DrawTextField(cgContext, macRect, params);
      break;
    }
    case Widget::eMultilineTextField: {
      bool isFocused = aWidgetInfo.Params<bool>();
      DrawMultilineTextField(cgContext, macRect, isFocused);
      break;
    }
  }

  // Reset the base CTM.
  CGContextSetBaseCTM(cgContext, CGAffineTransformIdentity);

  nativeDrawing.EndNativeDrawing();
}

bool nsNativeThemeCocoa::CreateWebRenderCommandsForWidget(
    mozilla::wr::DisplayListBuilder& aBuilder,
    mozilla::wr::IpcResourceUpdateQueue& aResources,
    const mozilla::layers::StackingContextHelper& aSc,
    mozilla::layers::RenderRootStateManager* aManager, nsIFrame* aFrame,
    StyleAppearance aAppearance, const nsRect& aRect) {
  if (IsWidgetAlwaysNonNative(aFrame, aAppearance)) {
    return ThemeCocoa::CreateWebRenderCommandsForWidget(
        aBuilder, aResources, aSc, aManager, aFrame, aAppearance, aRect);
  }

  // This list needs to stay consistent with the list in DrawWidgetBackground.
  // For every switch case in DrawWidgetBackground, there are three choices:
  //  - If the case in DrawWidgetBackground draws nothing for the given widget
  //    type, then don't list it here. We will hit the "default: return true;"
  //    case.
  //  - If the case in DrawWidgetBackground draws something simple for the given
  //    widget type, imitate that drawing using WebRender commands.
  //  - If the case in DrawWidgetBackground draws something complicated for the
  //    given widget type, return false here.
  switch (aAppearance) {
    case StyleAppearance::Checkbox:
    case StyleAppearance::Radio:
    case StyleAppearance::Button:
    case StyleAppearance::MozMacHelpButton:
    case StyleAppearance::MozMacDisclosureButtonOpen:
    case StyleAppearance::MozMacDisclosureButtonClosed:
    case StyleAppearance::Menulist:
    case StyleAppearance::MozMenulistArrowButton:
    case StyleAppearance::Textfield:
    case StyleAppearance::NumberInput:
    case StyleAppearance::PasswordInput:
    case StyleAppearance::Textarea:
      return false;

    default:
      return true;
  }
}

LayoutDeviceIntMargin nsNativeThemeCocoa::DirectionAwareMargin(
    const LayoutDeviceIntMargin& aMargin, nsIFrame* aFrame) {
  // Assuming aMargin was originally specified for a horizontal LTR context,
  // reinterpret the values as logical, and then map to physical coords
  // according to aFrame's actual writing mode.
  WritingMode wm = aFrame->GetWritingMode();
  nsMargin m = LogicalMargin(wm, aMargin.top, aMargin.right, aMargin.bottom,
                             aMargin.left)
                   .GetPhysicalMargin(wm);
  return LayoutDeviceIntMargin(m.top, m.right, m.bottom, m.left);
}

static constexpr LayoutDeviceIntMargin kAquaDropdownBorder(1, 22, 2, 5);

LayoutDeviceIntMargin nsNativeThemeCocoa::GetWidgetBorder(
    nsDeviceContext* aContext, nsIFrame* aFrame, StyleAppearance aAppearance) {
  if (IsWidgetAlwaysNonNative(aFrame, aAppearance)) {
    return Theme::GetWidgetBorder(aContext, aFrame, aAppearance);
  }

  LayoutDeviceIntMargin result;

  NS_OBJC_BEGIN_TRY_BLOCK_RETURN;
  switch (aAppearance) {
    case StyleAppearance::Button: {
      if (IsButtonTypeMenu(aFrame)) {
        result = DirectionAwareMargin(kAquaDropdownBorder, aFrame);
      } else {
        result =
            DirectionAwareMargin(LayoutDeviceIntMargin(1, 7, 3, 7), aFrame);
      }
      break;
    }

    case StyleAppearance::Menulist:
    case StyleAppearance::MozMenulistArrowButton:
      result = DirectionAwareMargin(kAquaDropdownBorder, aFrame);
      break;

    case StyleAppearance::NumberInput:
    case StyleAppearance::PasswordInput:
    case StyleAppearance::Textfield: {
      SInt32 frameOutset = 0;
      ::GetThemeMetric(kThemeMetricEditTextFrameOutset, &frameOutset);

      SInt32 textPadding = 0;
      ::GetThemeMetric(kThemeMetricEditTextWhitespace, &textPadding);

      frameOutset += textPadding;

      result.SizeTo(frameOutset, frameOutset, frameOutset, frameOutset);
      break;
    }

    case StyleAppearance::Textarea:
      result.SizeTo(1, 1, 1, 1);
      break;

    default:
      break;
  }

  if (IsHiDPIContext(aContext)) {
    result = result + result;  // doubled
  }

  NS_OBJC_END_TRY_BLOCK_RETURN(result);
}

// Return false here to indicate that CSS padding values should be used. There
// is no reason to make a distinction between padding and border values, just
// specify whatever values you want in GetWidgetBorder and only use this to
// return true if you want to override CSS padding values.
bool nsNativeThemeCocoa::GetWidgetPadding(nsDeviceContext* aContext,
                                          nsIFrame* aFrame,
                                          StyleAppearance aAppearance,
                                          LayoutDeviceIntMargin* aResult) {
  if (IsWidgetAlwaysNonNative(aFrame, aAppearance)) {
    return Theme::GetWidgetPadding(aContext, aFrame, aAppearance, aResult);
  }

  // We don't want CSS padding being used for certain widgets.
  // See bug 381639 for an example of why.
  switch (aAppearance) {
    // Radios and checkboxes return a fixed size in GetMinimumWidgetSize
    // and have a meaningful baseline, so they can't have
    // author-specified padding.
    case StyleAppearance::Checkbox:
    case StyleAppearance::Radio:
      aResult->SizeTo(0, 0, 0, 0);
      return true;

    default:
      break;
  }
  return false;
}

bool nsNativeThemeCocoa::GetWidgetOverflow(nsDeviceContext* aContext,
                                           nsIFrame* aFrame,
                                           StyleAppearance aAppearance,
                                           nsRect* aOverflowRect) {
  if (IsWidgetAlwaysNonNative(aFrame, aAppearance)) {
    return ThemeCocoa::GetWidgetOverflow(aContext, aFrame, aAppearance,
                                         aOverflowRect);
  }
  nsIntMargin overflow;
  switch (aAppearance) {
    case StyleAppearance::Button:
    case StyleAppearance::MozMacDisclosureButtonOpen:
    case StyleAppearance::MozMacDisclosureButtonClosed:
    case StyleAppearance::MozMacHelpButton:
    case StyleAppearance::NumberInput:
    case StyleAppearance::PasswordInput:
    case StyleAppearance::Textfield:
    case StyleAppearance::Textarea:
    case StyleAppearance::Menulist:
    case StyleAppearance::MozMenulistArrowButton:
    case StyleAppearance::Checkbox:
    case StyleAppearance::Radio: {
      overflow.SizeTo(static_cast<int32_t>(kMaxFocusRingWidth),
                      static_cast<int32_t>(kMaxFocusRingWidth),
                      static_cast<int32_t>(kMaxFocusRingWidth),
                      static_cast<int32_t>(kMaxFocusRingWidth));
      break;
    }
    default:
      break;
  }

  if (IsHiDPIContext(aContext)) {
    // Double the number of device pixels.
    overflow += overflow;
  }

  if (overflow != nsIntMargin()) {
    int32_t p2a = aFrame->PresContext()->AppUnitsPerDevPixel();
    aOverflowRect->Inflate(nsMargin(NSIntPixelsToAppUnits(overflow.top, p2a),
                                    NSIntPixelsToAppUnits(overflow.right, p2a),
                                    NSIntPixelsToAppUnits(overflow.bottom, p2a),
                                    NSIntPixelsToAppUnits(overflow.left, p2a)));
    return true;
  }

  return false;
}

LayoutDeviceIntSize nsNativeThemeCocoa::GetMinimumWidgetSize(
    nsPresContext* aPresContext, nsIFrame* aFrame,
    StyleAppearance aAppearance) {
  NS_OBJC_BEGIN_TRY_BLOCK_RETURN;

  if (IsWidgetAlwaysNonNative(aFrame, aAppearance)) {
    return ThemeCocoa::GetMinimumWidgetSize(aPresContext, aFrame, aAppearance);
  }

  LayoutDeviceIntSize result;
  switch (aAppearance) {
    case StyleAppearance::Button: {
      result.SizeTo(pushButtonSettings.minimumSizes[CocoaSize::Mini].width,
                    pushButtonSettings.naturalSizes[CocoaSize::Mini].height);
      break;
    }

    case StyleAppearance::MozMacDisclosureButtonOpen:
    case StyleAppearance::MozMacDisclosureButtonClosed: {
      result.SizeTo(kDisclosureButtonSize.width, kDisclosureButtonSize.height);
      break;
    }

    case StyleAppearance::MozMacHelpButton: {
      result.SizeTo(kHelpButtonSize.width, kHelpButtonSize.height);
      break;
    }

    case StyleAppearance::Menulist: {
      SInt32 popupHeight = 0;
      ::GetThemeMetric(kThemeMetricPopupButtonHeight, &popupHeight);
      result.SizeTo(0, popupHeight);
      break;
    }

    case StyleAppearance::NumberInput:
    case StyleAppearance::PasswordInput:
    case StyleAppearance::Textfield:
    case StyleAppearance::Textarea: {
      // at minimum, we should be tall enough for 9pt text.
      // I'm using hardcoded values here because the appearance manager
      // values for the frame size are incorrect.
      result.SizeTo(0, (2 + 2) /* top */ + 9 + (1 + 1) /* bottom */);
      break;
    }

    case StyleAppearance::MozWindowButtonBox: {
      NSSize size = WindowButtonsSize(aFrame);
      result.SizeTo(size.width, size.height);
      break;
    }

    case StyleAppearance::MozMenulistArrowButton:
      return ThemeCocoa::GetMinimumWidgetSize(aPresContext, aFrame,
                                              aAppearance);

    default:
      break;
  }

  if (IsHiDPIContext(aPresContext->DeviceContext())) {
    result = result * 2;
  }

  return result;

  NS_OBJC_END_TRY_BLOCK_RETURN(LayoutDeviceIntSize());
}

bool nsNativeThemeCocoa::WidgetAttributeChangeRequiresRepaint(
    StyleAppearance aAppearance, nsAtom* aAttribute) {
  // Some widget types just never change state.
  switch (aAppearance) {
    case StyleAppearance::MozWindowTitlebar:
    case StyleAppearance::MozSidebar:
    case StyleAppearance::Tooltip:
    case StyleAppearance::Menupopup:
      return false;
    default:
      break;
  }
  return Theme::WidgetAttributeChangeRequiresRepaint(aAppearance, aAttribute);
}

bool nsNativeThemeCocoa::ThemeSupportsWidget(nsPresContext* aPresContext,
                                             nsIFrame* aFrame,
                                             StyleAppearance aAppearance) {
  if (IsWidgetAlwaysNonNative(aFrame, aAppearance)) {
    return ThemeCocoa::ThemeSupportsWidget(aPresContext, aFrame, aAppearance);
  }
  // if this is a dropdown button in a combobox the answer is always no
  if (aAppearance == StyleAppearance::MozMenulistArrowButton) {
    nsIFrame* parentFrame = aFrame->GetParent();
    if (parentFrame && parentFrame->IsComboboxControlFrame()) return false;
  }

  switch (aAppearance) {
    // Combobox dropdowns don't support native theming in vertical mode.
    case StyleAppearance::Menulist:
    case StyleAppearance::MozMenulistArrowButton:
      if (aFrame && aFrame->GetWritingMode().IsVertical()) {
        return false;
      }
      [[fallthrough]];

    case StyleAppearance::MozWindowButtonBox:
    case StyleAppearance::MozWindowTitlebar:
    case StyleAppearance::MozSidebar:
    case StyleAppearance::Menupopup:
    case StyleAppearance::Tooltip:

    case StyleAppearance::Checkbox:
    case StyleAppearance::Radio:
    case StyleAppearance::MozMacHelpButton:
    case StyleAppearance::MozMacDisclosureButtonOpen:
    case StyleAppearance::MozMacDisclosureButtonClosed:
    case StyleAppearance::MozMacWindow:
    case StyleAppearance::Button:
    case StyleAppearance::NumberInput:
    case StyleAppearance::PasswordInput:
    case StyleAppearance::Textfield:
    case StyleAppearance::Textarea:
      return !IsWidgetStyled(aPresContext, aFrame, aAppearance);

    default:
      break;
  }

  return false;
}

bool nsNativeThemeCocoa::WidgetIsContainer(StyleAppearance aAppearance) {
  // flesh this out at some point
  switch (aAppearance) {
    case StyleAppearance::MozMenulistArrowButton:
    case StyleAppearance::Radio:
    case StyleAppearance::Checkbox:
    case StyleAppearance::MozMacHelpButton:
    case StyleAppearance::MozMacDisclosureButtonOpen:
    case StyleAppearance::MozMacDisclosureButtonClosed:
      return false;
    default:
      break;
  }
  return true;
}

bool nsNativeThemeCocoa::ThemeDrawsFocusForWidget(nsIFrame*,
                                                  StyleAppearance aAppearance) {
  switch (aAppearance) {
    case StyleAppearance::Textarea:
    case StyleAppearance::Textfield:
    case StyleAppearance::NumberInput:
    case StyleAppearance::PasswordInput:
    case StyleAppearance::Menulist:
    case StyleAppearance::Button:
    case StyleAppearance::MozMacHelpButton:
    case StyleAppearance::MozMacDisclosureButtonOpen:
    case StyleAppearance::MozMacDisclosureButtonClosed:
    case StyleAppearance::Radio:
    case StyleAppearance::Range:
    case StyleAppearance::Checkbox:
      return true;
    default:
      return false;
  }
}

bool nsNativeThemeCocoa::ThemeNeedsComboboxDropmarker() { return false; }

bool nsNativeThemeCocoa::WidgetAppearanceDependsOnWindowFocus(
    StyleAppearance aAppearance) {
  switch (aAppearance) {
    case StyleAppearance::Menupopup:
    case StyleAppearance::Tooltip:
    case StyleAppearance::NumberInput:
    case StyleAppearance::PasswordInput:
    case StyleAppearance::Textfield:
    case StyleAppearance::Textarea:
      return false;
    default:
      return true;
  }
}

nsITheme::ThemeGeometryType nsNativeThemeCocoa::ThemeGeometryTypeForWidget(
    nsIFrame* aFrame, StyleAppearance aAppearance) {
  switch (aAppearance) {
    case StyleAppearance::MozSidebar:
      return eThemeGeometryTypeSidebar;
    case StyleAppearance::MozWindowTitlebar:
      return eThemeGeometryTypeTitlebar;
    case StyleAppearance::MozWindowButtonBox:
      return eThemeGeometryTypeWindowButtons;
    default:
      return eThemeGeometryTypeUnknown;
  }
}

nsITheme::Transparency nsNativeThemeCocoa::GetWidgetTransparency(
    nsIFrame* aFrame, StyleAppearance aAppearance) {
  if (IsWidgetScrollbarPart(aAppearance)) {
    return ThemeCocoa::GetWidgetTransparency(aFrame, aAppearance);
  }

  switch (aAppearance) {
    case StyleAppearance::Menupopup:
    case StyleAppearance::Tooltip:
      return eTransparent;
    case StyleAppearance::MozMacWindow:
      // We want these to be treated as opaque by Gecko. We ensure there's an
      // appropriate OS-level clear color to make sure that's the case.
      return eOpaque;

    default:
      return eUnknownTransparency;
  }
}

already_AddRefed<widget::Theme> do_CreateNativeThemeDoNotUseDirectly() {
  return do_AddRef(new nsNativeThemeCocoa());
}
