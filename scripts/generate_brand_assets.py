#!/usr/bin/env python3
"""Generate MoteFlow's macOS assets from the approved icon artwork.

All output stays inside the Xcode asset catalog. Run on macOS:
    python3 scripts/generate_brand_assets.py

Source: GoogleRemote/Branding/MoteFlow-Approved.webp (approved blue/cyan remote icon).
Do not redraw or substitute the formerly used purple/tilted remote.
The status-bar template is drawn separately because macOS menu-bar icons
need a monochrome shape, unlike the full-colour Dock icon.
"""

import json
import hashlib
from pathlib import Path

from AppKit import (
    NSAffineTransform,
    NSBezierPath,
    NSBitmapImageRep,
    NSColor,
    NSImage,
    NSCompositingOperationSourceOver,
    NSGraphicsContext,
    NSBitmapImageFileTypePNG,
    NSDeviceRGBColorSpace,
    NSEvenOddWindingRule,
)
from Foundation import NSMakePoint, NSMakeRect

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "GoogleRemote" / "Assets.xcassets"
SOURCE_ICON = ROOT / "GoogleRemote" / "Branding" / "MoteFlow-Approved.webp"


def color(red, green, blue, alpha=1):
    return NSColor.colorWithCalibratedRed_green_blue_alpha_(
        red / 255.0, green / 255.0, blue / 255.0, alpha
    )


def rounded(x, y, width, height, radius):
    return NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(
        NSMakeRect(x, y, width, height), radius, radius
    )


def ellipse(x, y, width, height):
    return NSBezierPath.bezierPathWithOvalInRect_(NSMakeRect(x, y, width, height))


def fill(path, paint):
    paint.setFill()
    path.fill()


def stroke(path, paint, thickness):
    paint.setStroke()
    path.setLineWidth_(thickness)
    path.setLineCapStyle_(1)  # round
    path.stroke()


def arc(cx, cy, radius, low, high, paint, thickness):
    path = NSBezierPath.bezierPath()
    path.appendBezierPathWithArcWithCenter_radius_startAngle_endAngle_(
        NSMakePoint(cx, cy), radius, low, high
    )
    stroke(path, paint, thickness)


def canvas(size):
    rep = NSBitmapImageRep.alloc().initWithBitmapDataPlanes_pixelsWide_pixelsHigh_bitsPerSample_samplesPerPixel_hasAlpha_isPlanar_colorSpaceName_bytesPerRow_bitsPerPixel_(
        None, size, size, 8, 4, True, False, NSDeviceRGBColorSpace, 0, 0
    )
    assert rep is not None
    ctx = NSGraphicsContext.graphicsContextWithBitmapImageRep_(rep)
    assert ctx is not None
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.setCurrentContext_(ctx)
    transform = NSAffineTransform.transform()
    transform.scaleBy_(size / 1024)
    transform.concat()
    return rep


def write_bitmap(rep, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    data = rep.representationUsingType_properties_(NSBitmapImageFileTypePNG, {})
    if data is None:
        raise RuntimeError(f"Unable to encode PNG {path}")
    path.write_bytes(bytes(data))
    NSGraphicsContext.restoreGraphicsState()


def draw_icon(size, path):
    """Rasterize the user-approved image into a native PNG AppIcon slot."""
    if not SOURCE_ICON.is_file():
        raise FileNotFoundError(f"Approved icon artwork not found: {SOURCE_ICON}")
    source_image = NSImage.alloc().initWithContentsOfFile_(str(SOURCE_ICON))
    if source_image is None:
        raise RuntimeError(f"Cannot decode approved icon artwork: {SOURCE_ICON}")
    rep = canvas(size)
    source_image.drawInRect_fromRect_operation_fraction_(
        NSMakeRect(0, 0, 1024, 1024),
        NSMakeRect(0, 0, 0, 0),
        NSCompositingOperationSourceOver,
        1.0
    )
    write_bitmap(rep, path)


def arrow(start, end, head_a, head_b, paint, thickness):
    shaft = NSBezierPath.bezierPath()
    shaft.moveToPoint_(NSMakePoint(*start))
    shaft.lineToPoint_(NSMakePoint(*end))
    shaft.setLineCapStyle_(1)  # round
    shaft.setLineJoinStyle_(1)  # round
    stroke(shaft, paint, thickness)

    head = NSBezierPath.bezierPath()
    head.moveToPoint_(NSMakePoint(*head_a))
    head.lineToPoint_(NSMakePoint(*end))
    head.lineToPoint_(NSMakePoint(*head_b))
    head.setLineCapStyle_(1)  # round
    head.setLineJoinStyle_(1)  # round
    stroke(head, paint, thickness)


def draw_status(size, path):
    """Make a true 18pt menu-bar template from the approved logo's motif.

    Preserve its remote, circular primary key, four secondary keys and two
    radio arcs. Unlike the Dock icon, use a transparent, monochrome silhouette
    with transparent button cutouts so macOS can tint it for dark/light mode.
    """
    rep = canvas(size)
    monochrome = NSColor.blackColor()
    body = NSBezierPath.bezierPath()
    body.setWindingRule_(NSEvenOddWindingRule)
    body.appendBezierPath_(rounded(339, 103, 346, 555, 135))
    # Cutouts must be transparent, not painted white; this is a template image.
    body.appendBezierPath_(ellipse(445, 467, 134, 134))
    for x in (438, 549):
        for y in (246, 320):
            body.appendBezierPath_(ellipse(x, y, 39, 39))
    fill(body, monochrome)
    arc(512, 660, 141, 48, 132, monochrome, 72)
    arc(512, 665, 232, 48, 132, monochrome, 62)
    write_bitmap(rep, path)


def draw_status_remote(size, path):
    """18pt menu-bar template when forwarding control to a remote Mac.

    Uses a hollow outlined remote silhouette paired with an outgoing top-right
    arrow so the user can tell at a glance that focus is on the other Mac.
    """
    rep = canvas(size)
    monochrome = NSColor.blackColor()
    outline = rounded(135, 105, 366, 566, 140)
    stroke(outline, monochrome, 76)
    # Primary D-pad dot + two lower buttons keep the remote silhouette clear at 18pt.
    fill(ellipse(255, 442, 126, 126), monochrome)
    fill(ellipse(238, 240, 56, 56), monochrome)
    fill(ellipse(342, 240, 56, 56), monochrome)
    # Outgoing arrow pointing top-right (control forwarded out to remote Mac).
    arrow((595, 595), (895, 895), (655, 895), (895, 655), monochrome, 84)
    write_bitmap(rep, path)


def draw_status_controlled(size, path):
    """18pt menu-bar template when this Mac is being controlled by a peer Mac.

    Uses the solid remote silhouette paired with an incoming top-right arrow
    pointing into the remote to indicate incoming peer control.
    """
    rep = canvas(size)
    monochrome = NSColor.blackColor()
    body = NSBezierPath.bezierPath()
    body.setWindingRule_(NSEvenOddWindingRule)
    body.appendBezierPath_(rounded(112, 86, 392, 594, 148))
    body.appendBezierPath_(ellipse(238, 466, 140, 140))
    for x in (232, 344):
        for y in (238, 318):
            body.appendBezierPath_(ellipse(x, y, 42, 42))
    fill(body, monochrome)
    # Incoming arrow pointing bottom-left toward the remote body.
    arrow((895, 895), (595, 595), (595, 835), (835, 595), monochrome, 84)
    write_bitmap(rep, path)


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def write_status_imageset(name, prefix, drawer):
    imageset = CATALOG / f"{name}.imageset"
    status_images = []
    for scale in (1, 2, 3):
        filename = f"{prefix}-{scale}x.png"
        drawer(18 * scale, imageset / filename)
        status_images.append({
            "idiom": "universal", "filename": filename, "scale": f"{scale}x",
        })
    write_json(imageset / "Contents.json", {
        "images": status_images,
        "info": {"author": "xcode", "version": 1},
        "properties": {"template-rendering-intent": "template"},
    })
    return imageset


def main():
    appicon = CATALOG / "AppIcon.appiconset"
    appicons = []
    for logical_size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            physical_size = logical_size * scale
            filename = f"mote-flow-{physical_size}.png"
            destination = appicon / filename
            draw_icon(physical_size, destination)
            appicons.append({
                "idiom": "mac",
                "size": f"{logical_size}x{logical_size}",
                "scale": f"{scale}x",
                "filename": filename,
            })
    write_json(appicon / "Contents.json", {
        "images": appicons,
        "info": {"author": "xcode", "version": 1},
    })

    brand = CATALOG / "MoteFlowMark.imageset"
    draw_icon(256, brand / "mote-flow-mark.png")
    write_json(brand / "Contents.json", {
        "images": [{"idiom": "universal", "filename": "mote-flow-mark.png"}],
        "info": {"author": "xcode", "version": 1},
    })

    # 18 pt is the intended AppKit menu-bar size. Using a lone 64px 1x asset
    # gave the icon a 64pt intrinsic size and made it look oversized/cropped.
    status = write_status_imageset("MoteFlowStatusIcon", "mote-flow-status", draw_status)
    (status / "mote-flow-status.png").unlink(missing_ok=True)
    write_status_imageset("MoteFlowStatusIconRemote", "mote-flow-status-remote", draw_status_remote)
    write_status_imageset("MoteFlowStatusIconControlled", "mote-flow-status-controlled", draw_status_controlled)
    print(f"Approved source: {SOURCE_ICON.name}")
    print(f"Source SHA256: {hashlib.sha256(SOURCE_ICON.read_bytes()).hexdigest()}")
    print(f"Generated MoteFlow icon set, brand mark and menu-bar glyphs in {CATALOG}")


if __name__ == "__main__":
    main()
