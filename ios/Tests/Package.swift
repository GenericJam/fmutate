// swift-tools-version:5.9
// FMutate's pure Swift logic, tested on a Mac without the Mob app build: `swift test --package-path ios/Tests`.
// Sources/FMutateCore holds symlinks to the app's own ios/*.swift files (the UIKit-free ones), not copies; the app
// build compiles ios/FMutate*.swift only (mob.exs `project_swift_sources`), so nothing here goes into the app.

import PackageDescription

let package = Package(
    name: "FMutateTests",
    // the app targets iOS 17 (ios/build.zig); macOS 14 has the same Foundation and CoreGraphics
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "FMutateCore"),
        .testTarget(name: "FMutateCoreTests", dependencies: ["FMutateCore"])
    ]
)
