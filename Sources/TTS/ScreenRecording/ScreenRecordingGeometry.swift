import AppKit
import CoreGraphics

enum ScreenRecordingGeometry {
    static func appKitRect(fromQuartzRect rect: CGRect, primaryScreenMaxY: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryScreenMaxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    static func sourceRect(for selectionRect: CGRect, in displayFrame: CGRect) -> CGRect? {
        let display = displayFrame.standardized
        let clipped = selectionRect.standardized.intersection(display)
        guard !clipped.isNull, clipped.width >= 2, clipped.height >= 2 else {
            return nil
        }

        return CGRect(
            x: clipped.minX - display.minX,
            y: display.maxY - clipped.maxY,
            width: clipped.width,
            height: clipped.height
        )
    }

    static func evenPixelSize(for pointSize: CGSize, scale: CGFloat) -> CGSize {
        let width = max(2, Int(ceil(pointSize.width * max(scale, 1))))
        let height = max(2, Int(ceil(pointSize.height * max(scale, 1))))
        return CGSize(
            width: width.isMultiple(of: 2) ? width : width + 1,
            height: height.isMultiple(of: 2) ? height : height + 1
        )
    }

    static func clampedRegion(_ rect: CGRect, to displayFrame: CGRect) -> CGRect? {
        let clipped = rect.standardized.intersection(displayFrame.standardized)
        guard !clipped.isNull, clipped.width >= 40, clipped.height >= 40 else {
            return nil
        }
        return clipped
    }

    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }
}
