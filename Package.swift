// swift-tools-version:5.7
import PackageDescription

// micpeg links only CoreAudio + Foundation. No AppKit, no third-party dependencies.
// Frameworks are auto-linked from the `import` statements — no -framework flags needed.
//
// platforms stays at macOS 12 until the app target arrives: SwiftPM's `platforms:` is
// package-wide, so raising it for @Observable would move the daemon too. See
// docs/app-design.md, "Deployment target".
let package = Package(
    name: "micpeg",
    platforms: [.macOS(.v12)],
    targets: [
        // Read-only CoreAudio helpers, shared by the daemon and (from stage 2) the app.
        // Static: the daemon stays a single self-contained binary.
        .target(name: "MicpegAudio", path: "Sources/MicpegAudio"),
        .executableTarget(name: "micpeg",
                          dependencies: ["MicpegAudio"],
                          path: "Sources/micpeg")
    ]
)
