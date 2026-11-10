import AppKit

// Development runs never touch the real API keys.
if CommandLine.arguments.contains("--snapshot") || CommandLine.arguments.contains("--check-navigation") {
    SecretStore.disabled = true
}

// `Murmur --snapshot <dir>` draws the interface offscreen to PNGs and quits
// (a development aid: it needs no screen-recording permission).
if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1], isDirectory: true)
    MainActor.assumeIsolated { Snapshots.run(into: dir) }
    exit(0)
}

if CommandLine.arguments.contains("--check-navigation") {
    let ok = MainActor.assumeIsolated { Snapshots.checkNavigation() }
    exit(ok ? 0 : 1)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
