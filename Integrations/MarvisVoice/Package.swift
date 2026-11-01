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
    ],
    targets: [
        .target(
            name: "MarvisVoice",
            dependencies: [
                .product(name: "MLXAudioTTS", package: "MLXAudio"),
            ]
        ),
    ]
)
