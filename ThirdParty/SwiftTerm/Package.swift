// swift-tools-version:5.9
import PackageDescription
// iOS-only subset of SwiftTerm v1.9.0 (8840e3596739adfe9599c0e7fff89f4fa88bedcf).
// Excludes desktop subprocess dependencies; original sources and MIT license preserved.
let package = Package(name: "SwiftTerm", platforms: [.iOS(.v16)],
    products: [.library(name: "SwiftTerm", targets: ["SwiftTerm"])],
    targets: [.target(name: "SwiftTerm", path: "Sources/SwiftTerm", exclude: ["Mac/README.md", "LocalProcess.swift"])])
