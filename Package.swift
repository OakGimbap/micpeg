// swift-tools-version:5.9
import PackageDescription

// swift-tools-version is 5.9 because `.macOS(.v14)` does not exist in PackageDescription
// 5.7 ("'v14' is unavailable ... introduced in PackageDescription 5.9"). Building from
// source therefore needs Swift 5.9 or later, which every macOS 14 toolchain has.
//
// micpeg links only CoreAudio + Foundation. No AppKit, no third-party dependencies.
// The app target adds SwiftUI, AppKit and ServiceManagement, and nothing else.
// Frameworks are auto-linked from the `import` statements — no -framework flags needed.
//
// platforms is package-wide in SwiftPM, so the daemon inherits the app's minimum. macOS 14
// rather than 13 (which SMAppService alone would have allowed) because @Observable is
// 14-only; see docs/app-design.md, "Deployment target". This makes README's "macOS 12
// (Monterey) or later" false, including for the source-build path in scripts/install.sh —
// that README fix is stage 5.
let package = Package(
    name: "micpeg",
    platforms: [.macOS(.v14)],
    targets: [
        // Read-only CoreAudio helpers, shared by the daemon and (from stage 4) the app.
        // Static: the daemon stays a single self-contained binary.
        .target(name: "MicpegAudio", path: "Sources/MicpegAudio"),
        .executableTarget(name: "micpeg",
                          dependencies: ["MicpegAudio"],
                          path: "Sources/micpeg"),
        // The settings app. Deliberately does not depend on MicpegAudio yet: stage 2 only
        // registers and unregisters the agent, and a dependency it does not use would make
        // the invariant greps look like they are proving more than they are.
        .executableTarget(name: "MicpegApp", path: "Sources/MicpegApp")
    ]
)
