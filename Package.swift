// swift-tools-version:5.7
import PackageDescription

// micpeg links only CoreAudio + Foundation. No AppKit, no third-party dependencies.
// Frameworks are auto-linked from the `import` statements — no -framework flags needed.
let package = Package(
    name: "micpeg",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(name: "micpeg", path: "Sources/micpeg")
    ]
)
