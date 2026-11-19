// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "native_pdf_kit",
    platforms: [
        .iOS("13.0"),
        .macOS("10.15"),
    ],
    products: [
        .library(name: "native-pdf-kit", targets: ["native_pdf_kit"]),
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
    ],
    targets: [
        .target(
            name: "native_pdf_kit",
            dependencies: [
                .product(
                    name: "FlutterFramework",
                    package: "FlutterFramework"
                ),
            ],
            path: "Sources/native_pdf_kit",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ImageIO"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
    ]
)
