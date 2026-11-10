import AppKit

// Development runs never touch the real API keys.
if CommandLine.arguments.contains("--snapshot") || CommandLine.arguments.contains("--check-navigation")
    || CommandLine.arguments.contains("--film") || CommandLine.arguments.contains("--product-shots") {
    SecretStore.disabled = true
}

// `Murmur --snapshot <dir>` draws the interface offscreen to PNGs and quits
// (a development aid: it needs no screen-recording permission).
// `--configured`: draw the app as someone who has set it up sees it, with
// placeholder keys and both permissions shown as granted.
if CommandLine.arguments.contains("--configured") || CommandLine.arguments.contains("--product-shots") {
    SecretStore.placeholders = ["doubao": "placeholder-key", "llm": "placeholder-key"]
    Permissions.assumeGranted = true
}

if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1], isDirectory: true)
    MainActor.assumeIsolated { Snapshots.run(into: dir) }
    exit(0)
}

// `Murmur --product-shots <dir>` draws the README's still pictures.
if let i = CommandLine.arguments.firstIndex(of: "--product-shots"), i + 1 < CommandLine.arguments.count {
    let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1], isDirectory: true)
    MainActor.assumeIsolated { ProductShots.run(into: dir) }
    exit(0)
}

// `Murmur --film <dir> [--only name]` records the README's demos as frames.
if let i = CommandLine.arguments.firstIndex(of: "--film"), i + 1 < CommandLine.arguments.count {
    let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1], isDirectory: true)
    let only = CommandLine.arguments.firstIndex(of: "--only").map { CommandLine.arguments[$0 + 1] }
    MainActor.assumeIsolated { Films.run(into: dir, only: only) }
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
