// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "native_pdf_kit_ocr",
    platforms: [
        .iOS("13.0"),
        .macOS("10.15"),
    ],
    products: [
        .library(name: "native-pdf-kit-ocr", targets: ["native_pdf_kit_ocr"]),
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
    ],
    targets: [
        .target(
            name: "native_pdf_kit_ocr",
            dependencies: [
                .product(
                    name: "FlutterFramework",
                    package: "FlutterFramework"
                ),
            ],
            path: "Sources/native_pdf_kit_ocr",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ImageIO"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Vision"),
                .linkedFramework("PDFKit"),
            ]
        ),
    ]
)
