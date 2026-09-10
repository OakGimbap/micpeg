// swift-tools-version:5.7
import PackageDescription

// micpin links only CoreAudio + Foundation. No AppKit, no third-party dependencies.
// Frameworks are auto-linked from the `import` statements — no -framework flags needed.
let package = Package(
    name: "micpin",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(name: "micpin", path: "Sources/micpin")
    ]
)
