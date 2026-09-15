import Foundation
import CoreGraphics

/// Where the ZenScreen sits in global display space, in points.
public struct DisplayGeometry: Equatable {
    /// CGDisplayBounds of the target display (or of the mirror set's primary).
    public var frame: CGRect
    /// CGDisplayRotation, one of 0, 90, 180, 270.
    public var rotation: Int

    public init(frame: CGRect, rotation: Int = 0) {
        self.frame = frame
        self.rotation = rotation
    }
}

/// Linear correction from raw panel coordinates to the unit square.
public struct Calibration: Codable, Equatable {
    public var rawMinX: Double = 0
    public var rawMaxX: Double = Double(ReportLayout.maxCoordinate)
    public var rawMinY: Double = 0
    public var rawMaxY: Double = Double(ReportLayout.maxCoordinate)
    public var swapXY: Bool = false
    public var invertX: Bool = false
    public var invertY: Bool = false
    /// Contacts that begin within this fraction of the panel's width or height from an edge are
    /// treated as a palm or a gripping hand. 0.008 is about 3 mm on the MB16AMT and 9 points at
    /// 1080p, below the menu bar and well inside the Dock. 0 disables edge rejection.
    public var edgeRejectFraction: Double = 0.008

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rawMinX = try c.decodeIfPresent(Double.self, forKey: .rawMinX) ?? rawMinX
        rawMaxX = try c.decodeIfPresent(Double.self, forKey: .rawMaxX) ?? rawMaxX
        rawMinY = try c.decodeIfPresent(Double.self, forKey: .rawMinY) ?? rawMinY
        rawMaxY = try c.decodeIfPresent(Double.self, forKey: .rawMaxY) ?? rawMaxY
        swapXY = try c.decodeIfPresent(Bool.self, forKey: .swapXY) ?? swapXY
        invertX = try c.decodeIfPresent(Bool.self, forKey: .invertX) ?? invertX
        invertY = try c.decodeIfPresent(Bool.self, forKey: .invertY) ?? invertY
        edgeRejectFraction = try c.decodeIfPresent(Double.self, forKey: .edgeRejectFraction) ?? edgeRejectFraction
    }
}

/// Maps raw contact coordinates onto the display rectangle.
///
/// Rotation convention: `rotation` is the display's software rotation in degrees clockwise.
/// With 90, the image's top edge lies along the panel's physical right edge, so a finger at
/// the physical top-right corner maps to the image's top-left. If the panel turns out to
/// use the opposite convention, `Calibration.swapXY` and the invert flags correct it.
public struct DisplayMapper: Equatable {
    public var geometry: DisplayGeometry
    public var calibration: Calibration

    public init(geometry: DisplayGeometry, calibration: Calibration = Calibration()) {
        self.geometry = geometry
        self.calibration = calibration
    }

    /// Normalized panel coordinates in 0...1 after calibration, before rotation.
    public func unit(forX x: UInt16, y: UInt16) -> (u: Double, v: Double) {
        let cal = calibration
        var u = (Double(x) - cal.rawMinX) / max(cal.rawMaxX - cal.rawMinX, 1)
        var v = (Double(y) - cal.rawMinY) / max(cal.rawMaxY - cal.rawMinY, 1)
        if cal.swapXY { swap(&u, &v) }
        if cal.invertX { u = 1 - u }
        if cal.invertY { v = 1 - v }
        return (min(max(u, 0), 1), min(max(v, 0), 1))
    }

    /// True when the raw contact lies within `calibration.edgeRejectFraction` of any panel edge.
    public func isNearEdge(x: UInt16, y: UInt16) -> Bool {
        let f = calibration.edgeRejectFraction
        guard f > 0 else { return false }
        let (u, v) = unit(forX: x, y: y)
        return u < f || u > 1 - f || v < f || v > 1 - f
    }

    public func point(forX x: UInt16, y: UInt16) -> CGPoint {
        let (u, v) = unit(forX: x, y: y)
        let (sx, sy): (Double, Double)
        switch ((geometry.rotation % 360) + 360) % 360 {
        case 90: (sx, sy) = (v, 1 - u)
        case 180: (sx, sy) = (1 - u, 1 - v)
        case 270: (sx, sy) = (1 - v, u)
        default: (sx, sy) = (u, v)
        }
        let f = geometry.frame
        // Clamp to the last addressable point so a finger sliding off the bezel never lands on a neighbor.
        let px = min(max(f.minX + sx * f.width, f.minX), f.maxX - 1)
        let py = min(max(f.minY + sy * f.height, f.minY), f.maxY - 1)
        return CGPoint(x: px, y: py)
    }
}
