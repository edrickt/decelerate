// windowshot.swift captures a single app window (not the whole screen).
//
// Usage: swift Scripts/windowshot.swift <owner-name> <output.png>
// Finds the largest on-screen window owned by <owner-name> and asks
// screencapture to write just that window.

import AppKit
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: windowshot <owner-name> <output.png>\n".utf8))
    exit(64)
}
let owner = args[1]
let output = args[2]

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
    FileHandle.standardError.write(Data("could not list windows\n".utf8))
    exit(1)
}

struct Candidate {
    let id: Int
    let bounds: CGRect
    let name: String
}

var candidates: [Candidate] = []
for info in raw {
    guard let windowOwner = info[kCGWindowOwnerName as String] as? String,
          windowOwner == owner,
          let windowID = info[kCGWindowNumber as String] as? Int,
          let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
          let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
    let layer = info[kCGWindowLayer as String] as? Int ?? 0
    guard layer == 0 else { continue }
    let name = info[kCGWindowName as String] as? String ?? ""
    candidates.append(Candidate(id: windowID, bounds: bounds, name: name))
}

guard let target = candidates.max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) else {
    FileHandle.standardError.write(Data("no window found for \(owner)\n".utf8))
    exit(2)
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
process.arguments = ["-x", "-o", "-l", "\(target.id)", output]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("screencapture failed (\(process.terminationStatus))\n".utf8))
    exit(3)
}
print("captured \(owner) window '\(target.name)' \(Int(target.bounds.width))x\(Int(target.bounds.height)) -> \(output)")
