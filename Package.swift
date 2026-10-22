// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Loupe",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Loupe", targets: ["Loupe"]),
        .executable(name: "LoupeBench", targets: ["LoupeBench"]),
    ],
    // lts/macos26: the kits' LTS branches, which take the same backports as this one (LTS_POLICY.md in FrameScrub).
    dependencies: [
        .package(url: "https://github.com/ampire5/HomeScreenKit.git", branch: "lts/macos26"),
        .package(url: "https://github.com/ampire5/InfoPanelKit.git", branch: "lts/macos26"),
        .package(url: "https://github.com/ampire5/LogiHIDPP.git", branch: "lts/macos26"),
        .package(url: "https://github.com/ampire5/SettingsKit.git", branch: "lts/macos26"),
        .package(url: "https://github.com/ampire5/StashKit.git", branch: "lts/macos26"),
    ],
    targets: [
        .systemLibrary(name: "CTurboJPEG", pkgConfig: "libturbojpeg", providers: [.brew(["jpeg-turbo"])]),
        .systemLibrary(name: "CHeif", pkgConfig: "libheif", providers: [.brew(["libheif"])]),
        .systemLibrary(name: "CJXL", pkgConfig: "libjxl libjxl_threads", providers: [.brew(["jpeg-xl"])]),
        .target(name: "LoupeCore", dependencies: ["CTurboJPEG", "CJXL", .product(name: "LogiHIDPP", package: "LogiHIDPP"),
                                                 .product(name: "InfoPanelModel", package: "InfoPanelKit"),
                                                 .product(name: "HomeScreenModel", package: "HomeScreenKit"),
                                                 .product(name: "FilmstripModel", package: "HomeScreenKit")]),
        .target(name: "LoupeRender", dependencies: ["LoupeCore"]),
        .target(name: "LoupeSettings", dependencies: ["LoupeCore", .product(name: "SettingsKit", package: "SettingsKit"),
                                                     .product(name: "LogiHIDPP", package: "LogiHIDPP"),
                                                     .product(name: "StashKit", package: "StashKit")]),
        .executableTarget(name: "Loupe", dependencies: ["LoupeCore", "LoupeRender", "LoupeSettings",
                                                        .product(name: "LogiHIDPP", package: "LogiHIDPP"),
                                                        .product(name: "InfoPanelKit", package: "InfoPanelKit"),
                                                        .product(name: "HomeScreenKit", package: "HomeScreenKit"),
                                                        .product(name: "Filmstrip", package: "HomeScreenKit"),
                                                        .product(name: "StashKit", package: "StashKit"),
                                                        .product(name: "StashKitUI", package: "StashKit")]),
        .executableTarget(name: "LoupeBench", dependencies: ["LoupeCore", "LoupeRender", "CTurboJPEG", "CHeif", "CJXL",
                                                             .product(name: "FilmstripModel", package: "HomeScreenKit")]),
        .testTarget(name: "LoupeCoreTests", dependencies: ["LoupeCore", .product(name: "LogiHIDPP", package: "LogiHIDPP"),
                                                     .product(name: "HomeScreenModel", package: "HomeScreenKit"),
                                                     .product(name: "FilmstripModel", package: "HomeScreenKit")]),
        .testTarget(name: "LoupeSettingsTests", dependencies: ["LoupeSettings", "LoupeCore", .product(name: "SettingsKit", package: "SettingsKit"),
                                                               .product(name: "LogiHIDPP", package: "LogiHIDPP")]),
        .testTarget(name: "LoupeRenderTests", dependencies: ["LoupeRender", "LoupeCore"]),
    ],
    swiftLanguageModes: [.v5]
)
