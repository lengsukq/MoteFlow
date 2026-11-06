#!/usr/bin/env python3
"""Rebuild MoteFlow's native macOS icon assets using AppKit vector drawing.

All output stays inside the Xcode asset catalog. Run on macOS:
    python3 scripts/generate_brand_assets.py

The logo is a compact hand-held remote with wireless arcs and an ocean-blue
flow ribbon. No third-party fonts, downloads, or image dependencies are used.
"""

import json
from pathlib import Path

from AppKit import (
    NSAffineTransform,
    NSBezierPath,
    NSBitmapImageRep,
    NSColor,
    NSGradient,
    NSGraphicsContext,
    NSBitmapImageFileTypePNG,
    NSDeviceRGBColorSpace,
)
from Foundation import NSMakePoint, NSMakeRect

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "GoogleRemote" / "Assets.xcassets"


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
    rep = canvas(size)

    # Square macOS icon with a gentle optical margin and curved corners.
    base = rounded(40, 40, 944, 944, 228)
    NSGradient.alloc().initWithStartingColor_endingColor_(
        color(23, 43, 112), color(97, 64, 225)
    ).drawInBezierPath_angle_(base, 132)

    # Subtle upper-light gradient (deliberately no noisy texture).
    glow = rounded(72, 485, 880, 470, 194)
    NSGradient.alloc().initWithStartingColor_endingColor_(
        color(99, 132, 255, 0.22), color(45, 77, 185, 0.00)
    ).drawInBezierPath_angle_(glow, 100)

    # The flowing cyan band links remote control and automation.
    flow = NSBezierPath.bezierPath()
    flow.moveToPoint_(NSMakePoint(40, 250))
    flow.curveToPoint_controlPoint1_controlPoint2_(
        NSMakePoint(984, 276), NSMakePoint(330, 395), NSMakePoint(640, 125)
    )
    flow.lineToPoint_(NSMakePoint(984, 95))
    flow.lineToPoint_(NSMakePoint(40, 95))
    flow.closePath()
    NSGradient.alloc().initWithStartingColor_endingColor_(
        color(25, 211, 243, 0.89), color(111, 109, 250, 0.54)
    ).drawInBezierPath_angle_(flow, 6)

    # Remote silhouette; small tilt gives motion without sacrificing legibility.
    rotate = NSAffineTransform.transform()
    rotate.translateXBy_yBy_(515, 470)
    rotate.rotateByDegrees_(-14)
    rotate.translateXBy_yBy_(-515, -470)
    rotate.concat()

    remote_shadow = rounded(392, 202, 270, 494, 129)
    fill(remote_shadow, color(11, 19, 66, 0.25))
    remote = rounded(378, 218, 270, 494, 129)
    NSGradient.alloc().initWithStartingColor_endingColor_(
        color(255, 255, 255), color(207, 224, 255)
    ).drawInBezierPath_angle_(remote, 80)
    fill(ellipse(453, 504, 122, 122), color(58, 59, 171))
    fill(ellipse(478, 529, 72, 72), color(127, 170, 255, 0.67))
    fill(ellipse(475, 382, 69, 69), color(72, 75, 174))
    fill(ellipse(488, 300, 28, 28), color(83, 94, 187))
    fill(ellipse(537, 300, 28, 28), color(83, 94, 187))
    fill(ellipse(463, 300, 28, 28), color(83, 94, 187))

    # Wireless signal glows above the remote, still crisp at 32px.
    arc(513, 706, 65, 43, 137, color(241, 249, 255), 30)
    arc(513, 703, 131, 43, 137, color(164, 234, 255), 29)
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
            if not destination.exists():
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
    print(f"Generated MoteFlow icon set, brand mark and menu-bar glyph in {CATALOG}")


if __name__ == "__main__":
    main()
