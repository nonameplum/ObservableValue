// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

#if compiler(<6.0)
let swiftSettings: [PackageDescription.SwiftSetting] = [
  .enableUpcomingFeature("InferSendableFromCaptures"),
  .enableUpcomingFeature("IsolatedDefaultValues"),
  .enableUpcomingFeature("RegionBasedIsolation"),
]
#else
let swiftSettings: [PackageDescription.SwiftSetting] = []
#endif

let package = Package(
  name: "ObservableValue",
  platforms: [
    .iOS(.v16),
    .macOS(.v13),
    .watchOS(.v10),
    .tvOS(.v16),
    .visionOS(.v1),
  ],
  products: [
    .library(
      name: "ObservableValue",
      targets: ["ObservableValue"]
    )
  ],
  targets: [
    .target(
      name: "ObservableValue",
      dependencies: [],
      swiftSettings: swiftSettings
    ),
    .testTarget(
      name: "ObservableValueTests",
      dependencies: ["ObservableValue"],
      swiftSettings: swiftSettings
    ),
  ]
)
