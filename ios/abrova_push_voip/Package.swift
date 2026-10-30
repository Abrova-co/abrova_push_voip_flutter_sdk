// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "abrova_push_voip",
    platforms: [.iOS("13.0")],
    products: [
        .library(name: "abrova-push-voip", targets: ["abrova_push_voip"])
    ],
    dependencies: [
        .package(url: "https://center.abrova.ir/abrova/abrova-push-voip-ios-sdk.git", from: "0.1.2")
    ],
    targets: [
        .target(
            name: "abrova_push_voip",
            dependencies: [.product(name: "AbrovaPushVoip", package: "abrova-push-voip-ios-sdk")]
        )
    ]
)
