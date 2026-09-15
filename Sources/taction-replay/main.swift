import Foundation
import CoreGraphics
import TactionKit

// taction-replay: run a fixture (or a synthetic gesture) through the full pipeline and print
// what the daemon would have posted. No IOKit, no event posting.

let usage = """
usage: taction-replay <fixture.bin> [options]
       taction-replay --synthetic <name> [--out FILE] [options]
         names: tap slow-press long-press drag two-finger-tap two-finger-scroll flick
                late-second-finger pinch-out pinch-in three-finger-swipe-left three-finger-swipe-up palm edge

options:
  --frame X,Y,W,H     display rectangle in points (default 0,0,1920,1080)
  --rotation R        0, 90, 180, 270 (default 0)
  --config PATH       read gestures and calibration from a config.json
  --verbose           print every frame and touch event, not just actions
"""

var args = Array(CommandLine.arguments.dropFirst())
var fixture: String?
var synthetic: String?
var out: String?
var frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
var rotation = 0
var configPath: String?
var verbose = false

var i = 0
while i < args.count {
    let a = args[i]
    switch a {
    case "--synthetic": i += 1; synthetic = args[i]
    case "--out": i += 1; out = args[i]
    case "--frame":
        i += 1
        let p = args[i].split(separator: ",").compactMap { Double($0) }
        guard p.count == 4 else { fputs(usage, stderr); exit(1) }
        frame = CGRect(x: p[0], y: p[1], width: p[2], height: p[3])
    case "--rotation": i += 1; rotation = Int(args[i]) ?? 0
    case "--config": i += 1; configPath = args[i]
    case "--verbose", "-v": verbose = true
    case "-h", "--help": print(usage); exit(0)
    default:
        if a.hasPrefix("-") { fputs("unknown option \(a)\n\(usage)", stderr); exit(1) }
        fixture = a
    }
    i += 1
}

var config = TactionConfig()
if let path = configPath {
    do { config = try TactionConfig.load(from: URL(fileURLWithPath: path)) } catch { fputs("config: \(error)\n", stderr); exit(1) }
}

let reports: [CapturedReport]
if let name = synthetic {
    guard let r = Synthetic.make(name) else { fputs("unknown synthetic gesture \(name)\n\(usage)", stderr); exit(1) }
    reports = r
    if let out = out {
        do { try FixtureFile.write(reports, to: URL(fileURLWithPath: out)); print("wrote \(reports.count) reports to \(out)") } catch { fputs("\(error)\n", stderr); exit(1) }
    }
} else if let path = fixture {
    do { reports = try FixtureFile.read(from: URL(fileURLWithPath: path)) } catch { fputs("fixture: \(error)\n", stderr); exit(1) }
} else {
    print(usage)
    exit(1)
}

let mapper = DisplayMapper(geometry: DisplayGeometry(frame: frame, rotation: rotation), calibration: config.calibration)
var pipeline = Pipeline(mapper: mapper, gestures: config.gestures)

guard let first = reports.first else { print("no reports"); exit(0) }
let t0 = first.seconds
var clock = t0
var actionCount = 0

func fmt(_ t: Double) -> String { String(format: "%8.3f", t - t0) }

func emit(_ actions: [OutputAction], at t: Double) {
    for a in actions {
        actionCount += 1
        print("\(fmt(t))    -> \(Formatting.describe(a))")
    }
}

for r in reports {
    // Advance the engine's timers across the gap before this report, in 10 ms steps like the daemon does.
    while pipeline.engine.needsTick && clock + 0.010 <= r.seconds {
        clock += 0.010
        emit(pipeline.tick(now: clock), at: clock)
    }
    clock = r.seconds
    let result = pipeline.ingest(report: r.bytes, at: r.seconds)
    if verbose {
        if let f = result.frame { print("\(fmt(r.seconds)) frame \(Formatting.describe(f))") } else { print("\(fmt(r.seconds)) unparsable report \(Formatting.hex(r.bytes))") }
        for te in result.touches { print("\(fmt(r.seconds))   \(Formatting.describe(te))") }
    }
    emit(result.actions, at: r.seconds)
    if verbose { print("\(fmt(r.seconds))   state \(Formatting.describe(pipeline.engine.state))") }
}

// Let pending timers run out after the last report (long press, momentum), up to 5 s.
var settle = 0
while pipeline.engine.needsTick && settle < 500 {
    clock += 0.010
    emit(pipeline.tick(now: clock), at: clock)
    settle += 1
}

print("\(reports.count) reports, \(pipeline.framesSeen) frames, \(pipeline.parseErrors) parse errors, \(actionCount) actions, final state \(Formatting.describe(pipeline.engine.state)), button \(pipeline.engine.isLeftButtonDown ? "DOWN" : "up")")
if pipeline.engine.isLeftButtonDown { exit(2) }

/// Synthetic gesture scripts in raw panel coordinates.
enum Synthetic {
    static func make(_ name: String) -> [CapturedReport]? {
        var c = SyntheticCapture()
        func f(_ id: UInt8, _ x: UInt16, _ y: UInt16) -> Contact { Contact(id: id, tip: true, x: x, y: y) }
        switch name {
        case "tap":
            c.frame([f(0, 2048, 1024)])
            c.frame([f(0, 2050, 1025)])
            c.frame([f(0, 2050, 1025)])
            c.frame([Contact(id: 0, tip: false, x: 2050, y: 1025)], contactCount: 0)
        case "slow-press":
            c.frame([f(0, 2048, 1024)])
            for _ in 0..<40 { c.frame([f(0, 2048, 1024)]) }   // 400 ms
            c.allUp()
        case "drag":
            c.frame([f(0, 500, 500)])
            for k in 1...30 { c.frame([f(0, 500 + UInt16(k * 40), 500 + UInt16(k * 10))]) }
            c.allUp()
        case "two-finger-tap":
            c.frame([f(0, 2000, 1000)])
            c.frame([f(0, 2000, 1000), f(1, 2300, 1000)], dtMs: 15)
            c.frame([f(0, 2001, 1000), f(1, 2300, 1001)])
            c.frame([f(1, 2300, 1001)])
            c.allUp()
        case "two-finger-scroll":
            c.frame([f(0, 2000, 1000)])
            c.frame([f(0, 2000, 1000), f(1, 2300, 1000)], dtMs: 15)
            for k in 1...25 { c.frame([f(0, 2000, 1000 + UInt16(k * 30)), f(1, 2300, 1000 + UInt16(k * 30))]) }
            c.frame([f(1, 2300, 1750)])
            c.allUp()
        case "late-second-finger":
            c.frame([f(0, 2000, 1000)])
            for _ in 0..<20 { c.frame([f(0, 2000, 1000)]) }   // 200 ms
            c.frame([f(0, 2000, 1000), f(1, 2300, 1000)])
            c.frame([f(0, 2100, 1000), f(1, 2300, 1000)])
            c.frame([f(1, 2300, 1000)])
            c.allUp()
        case "long-press":
            c.frame([f(0, 2048, 1024)])
            for _ in 0..<70 { c.frame([f(0, 2048, 1024)]) }   // 700 ms still
            c.allUp()
        case "flick":
            c.frame([f(0, 2000, 800)])
            c.frame([f(0, 2000, 800), f(1, 2300, 800)], dtMs: 15)
            for k in 1...12 { c.frame([f(0, 2000, 800 + UInt16(k * 120)), f(1, 2300, 800 + UInt16(k * 120))], dtMs: 8) }
            c.allUp(dtMs: 8)
        case "pinch-out":
            c.frame([f(0, 1900, 1000)])
            c.frame([f(0, 1900, 1000), f(1, 2200, 1000)], dtMs: 15)
            for k in 1...12 { c.frame([f(0, 1900 - UInt16(k * 40), 1000), f(1, 2200 + UInt16(k * 40), 1000)]) }
            c.allUp()
        case "pinch-in":
            // Fingers start 1000 raw units (about 8.5 cm) apart and close to 40.
            c.frame([f(0, 1550, 1000)])
            c.frame([f(0, 1550, 1000), f(1, 2550, 1000)], dtMs: 15)
            for k in 1...12 { c.frame([f(0, 1550 + UInt16(k * 40), 1000), f(1, 2550 - UInt16(k * 40), 1000)]) }
            c.allUp()
        case "three-finger-swipe-left":
            c.frame([f(0, 2000, 1000)])
            c.frame([f(0, 2000, 1000), f(1, 2250, 1000)], dtMs: 12)
            c.frame([f(0, 2000, 1000), f(1, 2250, 1000), f(2, 2500, 1000)], dtMs: 12)
            for k in 1...10 { c.frame([f(0, 2000 - UInt16(k * 40), 1000), f(1, 2250 - UInt16(k * 40), 1000), f(2, 2500 - UInt16(k * 40), 1000)]) }
            c.allUp()
        case "three-finger-swipe-up":
            c.frame([f(0, 2000, 2000)])
            c.frame([f(0, 2000, 2000), f(1, 2250, 2000)], dtMs: 12)
            c.frame([f(0, 2000, 2000), f(1, 2250, 2000), f(2, 2500, 2000)], dtMs: 12)
            for k in 1...10 { c.frame([f(0, 2000, 2000 - UInt16(k * 40)), f(1, 2250, 2000 - UInt16(k * 40)), f(2, 2500, 2000 - UInt16(k * 40))]) }
            c.allUp()
        case "palm":
            for k in 0..<30 { c.frame([f(0, 1400 + UInt16(k * 5), 1900), f(1, 2400 + UInt16(k * 5), 3700)]) }
            c.allUp()
        case "edge":
            c.frame([f(0, 10, 2000)])       // on the left bezel
            for _ in 0..<10 { c.frame([f(0, 12, 2000)]) }
            c.allUp()
        default:
            return nil
        }
        return c.reports
    }
}
