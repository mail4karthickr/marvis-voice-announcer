// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WFFargoMarvisVoice",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "WFFargoMarvisVoice", targets: ["WFFargoMarvisVoice"]),
    ],
    dependencies: [
        .package(name: "MLXAudio", path: "../mlx-audio-swift"),
    ],
    targets: [
        .target(
            name: "WFFargoMarvisVoice",
            dependencies: [
                .product(name: "MLXAudioTTS", package: "MLXAudio"),
            ]
        ),
    ]
)
