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
        // The window. A library rather than part of the executable so SwiftUI previews can
        // build it: previews need a target Xcode can compile on its own, and an
        // executableTarget with @main is not one.
        //
        // It — not MicpegAudio — is where reading the default *output* device belongs. The
        // daemon links MicpegAudio, and the invariant that keeps "micpeg never touches your
        // speakers" honest is a grep for DefaultOutputDevice across everything the daemon
        // links. Putting the app's one read of it here keeps that grep meaningful.
        .target(name: "MicpegUI",
                dependencies: ["MicpegAudio"],
                path: "Sources/MicpegUI"),
        // Thin: @main, the app delegate, and the wiring between MicpegUI and the agent.
        .executableTarget(name: "MicpegApp",
                          dependencies: ["MicpegUI", "MicpegAudio"],
                          path: "Sources/MicpegApp")
    ]
)
