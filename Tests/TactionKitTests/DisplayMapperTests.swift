import Testing
import CoreGraphics
@testable import TactionKit

@Suite struct DisplayMapperTests {
    let frame = CGRect(x: 1800, y: 0, width: 1920, height: 1080)

    func near(_ a: CGPoint, _ b: CGPoint, tolerance: Double = 1.0) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
    }

    @Test func cornersAtRotationZero() {
        let m = DisplayMapper(geometry: DisplayGeometry(frame: frame))
        #expect(near(m.point(forX: 0, y: 0), CGPoint(x: 1800, y: 0)))
        #expect(near(m.point(forX: 4095, y: 0), CGPoint(x: 1800 + 1919, y: 0)))
        #expect(near(m.point(forX: 0, y: 4095), CGPoint(x: 1800, y: 1079)))
        #expect(near(m.point(forX: 2048, y: 2048), CGPoint(x: 1800 + 960, y: 540)))
    }

    @Test func rotationNinetyPutsPhysicalTopRightAtImageTopLeft() {
        let portrait = CGRect(x: 0, y: 0, width: 1080, height: 1920)
        let m = DisplayMapper(geometry: DisplayGeometry(frame: portrait, rotation: 90))
        #expect(near(m.point(forX: 4095, y: 0), CGPoint(x: 0, y: 0)))
        #expect(near(m.point(forX: 0, y: 0), CGPoint(x: 0, y: 1919)))
        #expect(near(m.point(forX: 4095, y: 4095), CGPoint(x: 1079, y: 0)))
    }

    @Test func rotationOneEightyFlipsBoth() {
        let m = DisplayMapper(geometry: DisplayGeometry(frame: frame, rotation: 180))
        #expect(near(m.point(forX: 0, y: 0), CGPoint(x: 1800 + 1919, y: 1079)))
    }

    @Test func rotationTwoSeventy() {
        let portrait = CGRect(x: 0, y: 0, width: 1080, height: 1920)
        let m = DisplayMapper(geometry: DisplayGeometry(frame: portrait, rotation: 270))
        #expect(near(m.point(forX: 0, y: 4095), CGPoint(x: 0, y: 0)))
        #expect(near(m.point(forX: 4095, y: 0), CGPoint(x: 1079, y: 1919)))
    }

    @Test func calibrationBoundsAndFlags() {
        var cal = Calibration()
        cal.rawMinX = 40; cal.rawMaxX = 4060
        cal.rawMinY = 30; cal.rawMaxY = 4070
        let m = DisplayMapper(geometry: DisplayGeometry(frame: frame), calibration: cal)
        #expect(near(m.point(forX: 40, y: 30), CGPoint(x: 1800, y: 0)))
        #expect(near(m.point(forX: 4060, y: 4070), CGPoint(x: 1800 + 1919, y: 1079)))
        // Below the minimum clamps rather than leaving the display.
        #expect(near(m.point(forX: 0, y: 0), CGPoint(x: 1800, y: 0)))

        var flipped = Calibration()
        flipped.invertX = true
        flipped.invertY = true
        let mf = DisplayMapper(geometry: DisplayGeometry(frame: frame), calibration: flipped)
        #expect(near(mf.point(forX: 0, y: 0), CGPoint(x: 1800 + 1919, y: 1079)))

        var swapped = Calibration()
        swapped.swapXY = true
        let ms = DisplayMapper(geometry: DisplayGeometry(frame: frame), calibration: swapped)
        #expect(near(ms.point(forX: 4095, y: 0), CGPoint(x: 1800, y: 1079)))
    }

    @Test func neverLandsOnNeighborDisplay() {
        let m = DisplayMapper(geometry: DisplayGeometry(frame: frame))
        for x: UInt16 in [0, 1, 4094, 4095] {
            for y: UInt16 in [0, 1, 4094, 4095] {
                let p = m.point(forX: x, y: y)
                #expect(frame.contains(p), "(\(x),\(y)) mapped to \(p) outside \(frame)")
            }
        }
    }
}
