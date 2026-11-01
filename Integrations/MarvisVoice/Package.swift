// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MarvisVoice",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "MarvisVoice", targets: ["MarvisVoice"]),
    ],
    dependencies: [
        .package(name: "MLXAudio", path: "../mlx-audio-swift"),
        // Same series mlx-audio-swift pins (see MARVIS_PATCHES.md item 6), so both resolve to the one copy of MLX in the app.
        .package(url: "https://github.com/ml-explore/mlx-swift.git", .upToNextMinor(from: "0.31.4")),
    ],
    targets: [
        .target(
            name: "MarvisVoice",
            dependencies: [
                .product(name: "MLXAudioTTS", package: "MLXAudio"),
                .product(name: "MLX", package: "mlx-swift"),
            ]
        ),
    ]
)
