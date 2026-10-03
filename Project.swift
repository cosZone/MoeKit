import ProjectDescription

let project = Project(
    name: "MoeKit",
    settings: .settings(base: [
        "SWIFT_VERSION": "6.0",
        "SWIFT_STRICT_CONCURRENCY": "complete",
        "MACOSX_DEPLOYMENT_TARGET": "15.0",
        "MARKETING_VERSION": "0.1.0",
        "CURRENT_PROJECT_VERSION": "1",
        "CODE_SIGN_STYLE": "Automatic",
        "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
        "DEVELOPMENT_TEAM": "",
    ]),
    targets: [
        .target(
            name: "MoeKit",
            destinations: .macOS,
            product: .app,
            bundleId: "com.yusixian.MoeKit",
            deploymentTargets: .macOS("15.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "MoeKit",
                "CFBundleDevelopmentRegion": "en",
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "NSHumanReadableCopyright": "Copyright © 2026 MoeKit",
                "LSApplicationCategoryType": "public.app-category.developer-tools",
            ]),
            sources: ["Sources/**"],
            resources: ["Resources/**"],
            dependencies: [],
            settings: .settings(base: ["ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon", "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": ""])
        ),
        .target(
            name: "MoeKitTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.yusixian.MoeKitTests",
            deploymentTargets: .macOS("15.0"),
            sources: ["Tests/**"],
            dependencies: [.target(name: "MoeKit")]
        ),
    ],
    schemes: [
        .scheme(
            name: "MoeKit",
            shared: true,
            buildAction: .buildAction(targets: ["MoeKit"]),
            testAction: .targets(["MoeKitTests"]),
            runAction: .runAction(configuration: .debug)
        ),
    ]
)
