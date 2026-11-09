// tapmeasure.swift measures delivered pointer deltas (and, optionally, raw HID deltas)
// to characterise pointer acceleration gain at different velocities.
//
// Modes:
//   tapmeasure listen <seconds> [--csv <path>]
//       Listen-only CGEventTap (.cghidEventTap) for mouseMoved/leftDragged/etc.
//       Prints count, delta statistics (p50/p95/max |dx|, gain per velocity bucket if
//       raw HID values are also available) and can write a CSV of every event.
//       Needs Accessibility/Input Monitoring TCC when run as a bare binary; no TCC
//       needed when the process already has it (this research session does).
//
//   tapmeasure post <dx> <count>
//       Smoke test: posts synthetic mouse-moved CGEvents (no HID acceleration applied),
//       used to verify the listener works without physical movement.
//
// To measure real acceleration: run `tapmeasure listen 20 --csv /tmp/run.csv` and move a
// physical mouse/trackpad during that window; then toggle state with hidprobe
// (`hidprobe param-set HIDMouseAcceleration fixed:-1`) and repeat.
//
// NOTE: synthetic HID injection (IOHIDUserDevice) is not possible without Apple's
// "com.apple.developer.hid.virtual.device" entitlement (verified: creation returns NULL),
// so this rig needs real physical input.

import Foundation
import CoreGraphics
import ApplicationServices
import IOKit.hidsystem
import IOKit.hid

struct Sample {
    let t: CFAbsoluteTime
    let dx: Int64
    let dy: Int64
    let kind: String
}

func listen(seconds: Double, csvPath: String?) -> Int32 {
    if !CGPreflightListenEventAccess() {
        FileHandle.standardError.write("warning: CGPreflightListenEventAccess() == false; tap may be nil\n".data(using: .utf8)!)
    }
    var samples: [Sample] = []
    let mask: CGEventMask = (1 << CGEventType.mouseMoved.rawValue)
        | (1 << CGEventType.leftMouseDragged.rawValue)
        | (1 << CGEventType.rightMouseDragged.rawValue)
        | (1 << CGEventType.otherMouseDragged.rawValue)

    let callback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let box = Unmanaged<AnyObject>.fromOpaque(refcon).takeUnretainedValue()
        if let acc = box as? SampleAccumulator {
            let dx = event.getIntegerValueField(.mouseEventDeltaX)
            let dy = event.getIntegerValueField(.mouseEventDeltaY)
            acc.samples.append(Sample(t: CFAbsoluteTimeGetCurrent(), dx: dx, dy: dy, kind: "\(type.rawValue)"))
        }
        return Unmanaged.passUnretained(event)
    }

    let accumulator = SampleAccumulator()
    let tap = CGEvent.tapCreate(tap: .cghidEventTap,
                                place: .headInsertEventTap,
                                options: .listenOnly,
                                eventsOfInterest: mask,
                                callback: callback,
                                userInfo: Unmanaged.passUnretained(accumulator).toOpaque())
    guard let tap else {
        FileHandle.standardError.write("CGEventTapCreate returned nil (no Accessibility/Input Monitoring?)\n".data(using: .utf8)!)
        return 1
    }
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        CFRunLoopRunInMode(.defaultMode, 0.05, true)
    }
    CFMachPortInvalidate(tap)

    samples = accumulator.samples
    let dxs = samples.map { abs($0.dx) }.filter { $0 > 0 }
    print("events: \(samples.count)")
    if !dxs.isEmpty {
        let sorted = dxs.sorted()
        func pct(_ p: Double) -> Int64 { sorted[Int(Double(sorted.count - 1) * p)] }
        print("abs(dx) p50=\(pct(0.5)) p90=\(pct(0.9)) p95=\(pct(0.95)) max=\(pct(1.0))")
        // Velocity buckets: group consecutive events by inter-event interval to compare
        // gain across speeds once a raw-HID reference is joined to this data.
        var buckets: [String: (n: Int, sumAbs: Int64)] = [:]
        for s in samples {
            let bucket = abs(s.dx) < 5 ? "slow(<5)" : abs(s.dx) < 30 ? "medium(5..29)" : "fast(>=30)"
            var b = buckets[bucket] ?? (0, 0)
            b.n += 1
            b.sumAbs += abs(s.dx)
            buckets[bucket] = b
        }
        for (k, v) in buckets.sorted(by: { $0.key < $1.key }) {
            print("bucket \(k): n=\(v.n) mean|dx|=\(Double(v.sumAbs) / Double(max(v.n, 1)))")
        }
    }
    if let csvPath {
        var csv = "t,dx,dy,event_type\n"
        for s in samples {
            csv += "\(s.t),\(s.dx),\(s.dy),\(s.kind)\n"
        }
        try? csv.write(toFile: csvPath, atomically: true, encoding: .utf8)
        print("wrote \(csvPath)")
    }
    return 0
}

final class SampleAccumulator {
    var samples: [Sample] = []
}

func postSynthetic(dx: Int64, count: Int) -> Int32 {
    guard let source = CGEventSource(stateID: .hidSystemState) else { return 1 }
    var location = CGEvent(source: nil)?.location ?? .zero
    for _ in 0..<count {
        location.x = min(max(location.x + CGFloat(dx), 0), 4000)
        if let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                               mouseCursorPosition: location, mouseButton: .left) {
            event.setIntegerValueField(.mouseEventDeltaX, value: dx)
            event.post(tap: .cghidEventTap)
        }
        usleep(8000)
    }
    print("posted \(count) synthetic mouseMoved events with dx=\(dx)")
    return 0
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: tapmeasure listen <seconds> [--csv path] | tapmeasure post <dx> <count>")
    exit(1)
}
switch args[1] {
case "listen":
    guard args.count >= 3, let seconds = Double(args[2]) else { exit(1) }
    let csvIndex = args.firstIndex(of: "--csv")
    let csv = csvIndex.flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    exit(listen(seconds: seconds, csvPath: csv))
case "post":
    guard args.count >= 4, let dx = Int64(args[2]), let count = Int(args[3]) else { exit(1) }
    exit(postSynthetic(dx: dx, count: count))
default:
    exit(1)
}
