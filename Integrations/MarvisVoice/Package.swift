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
        // Declared exactly as mlx-audio-swift declares it, so this adds nothing to dependency resolution.
        .package(url: "https://github.com/ml-explore/mlx-swift.git", .upToNextMajor(from: "0.30.6")),
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
