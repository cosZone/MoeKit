// swift-tools-version: 6.0
import PackageDescription

// The reviewed binary checksum is pinned in Sparkle's locked package manifest.
// Build the macOS app through Tuist; this is not a swift-run executable.
let package = Package(name: "MoeKit", dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
])
