import AppKit
import Foundation

// A development-only command-line switch. It snapshots our own view tree and
// never requests screen-recording access or captures another application's UI.
@MainActor
func captureRequestedWindowIfNeeded() async {
    let args = CommandLine.arguments
    guard let flag = args.firstIndex(of: "--screenshot") else { return }
    let next = args.index(after: flag)
    let destination: String
    if next < args.endIndex && !args[next].hasPrefix("--") {
        destination = args[next]
    } else {
        destination = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("outputs/GPUCheck-Preview.png").path
    }

    // Allow the initial SSH result, native window layout, and chart transition
    // to finish before capture. Normal application launches never enter here.
    do {
        try await Task.sleep(nanoseconds: 12_000_000_000)
    } catch {
        return
    }
    guard let window = NSApp.windows.first(where: {
        $0.isVisible && $0.contentView != nil && $0.sheetParent == nil && $0.canBecomeMain
    }), let content = window.contentView else {
        fputs("GPUCheck snapshot failed: no application window.\n", stderr)
        return
    }
    content.layoutSubtreeIfNeeded()
    content.displayIfNeeded()
    guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
        fputs("GPUCheck snapshot failed: cannot create bitmap.\n", stderr)
        return
    }
    content.cacheDisplay(in: content.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        fputs("GPUCheck snapshot failed: cannot encode PNG.\n", stderr)
        return
    }
    let url = URL(fileURLWithPath: destination)
    do {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                               withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        print("GPUCheck snapshot saved: \(url.path)")
    } catch {
        fputs("GPUCheck snapshot failed: \(error.localizedDescription)\n", stderr)
    }
    if args.contains("--screenshot-exit") {
        NSApp.terminate(nil)
    }
}
