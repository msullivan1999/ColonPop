// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ColonPop",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "ColonPop", targets: ["ColonPop"])],
    targets: [
        .executableTarget(name: "ColonPop", resources: [.copy("Resources/emoji.tsv")]),
        .testTarget(name: "ColonPopTests", dependencies: ["ColonPop"])
    ]
)
