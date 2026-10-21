// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyAITeacher",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MyAITeacher", targets: ["MyAITeacher"]),
    ],
    targets: [
        .executableTarget(
            name: "MyAITeacher",
            path: "Sources/MyAITeacher",
            swiftSettings: [
                .unsafeFlags(["-wmo"], .when(configuration: .release)),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "MyAITeacherTests",
            dependencies: ["MyAITeacher"],
            path: "Tests/MyAITeacherTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
