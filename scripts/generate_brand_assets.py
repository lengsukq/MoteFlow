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


def draw_status(size, path):
    rep = canvas(size)
    monochrome = NSColor.blackColor()
    # Menu-bar template mark: remote + two signal waves, no background.
    fill(rounded(430, 125, 180, 570, 85), monochrome)
    arc(520, 700, 106, 48, 132, monochrome, 55)
    arc(520, 696, 185, 47, 133, monochrome, 48)
    write_bitmap(rep, path)


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


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

    status = CATALOG / "MoteFlowStatusIcon.imageset"
    draw_status(64, status / "mote-flow-status.png")
    write_json(status / "Contents.json", {
        "images": [{"idiom": "universal", "filename": "mote-flow-status.png"}],
        "info": {"author": "xcode", "version": 1},
        "properties": {"template-rendering-intent": "template"},
    })
    print(f"Approved source: {SOURCE_ICON.name}")
    print(f"Source SHA256: {hashlib.sha256(SOURCE_ICON.read_bytes()).hexdigest()}")
    print(f"Generated MoteFlow icon set, brand mark and menu-bar glyph in {CATALOG}")


if __name__ == "__main__":
    main()
