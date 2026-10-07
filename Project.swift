import Foundation
import ProjectDescription

private struct SparklePublicConfiguration: Decodable {
    let publicEDKey: String
}

// Only the public verification key is consumed by project generation. The
// release helper separately validates every dependency/feed/security pin.
private let sparkleConfiguration = try JSONDecoder().decode(
    SparklePublicConfiguration.self,
    from: Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Configurations/Sparkle.json"))
)

let project = Project(
    name: "MoeKit",
    // Native SPM preserves SwiftTerm's required build-tool plugin and Metal resource.
    // Exact revisions are additionally enforced by resolve-native-packages.py.
    packages: [
        .remote(url: "https://github.com/migueldeicaza/SwiftTerm", requirement: .exact("1.20.0")),
        .remote(url: "https://github.com/apple/swift-argument-parser", requirement: .exact("1.6.1")),
        .remote(url: "https://github.com/apple/swift-docc-plugin", requirement: .exact("1.4.3")),
        .remote(url: "https://github.com/swiftlang/swift-docc-symbolkit", requirement: .exact("1.0.0")),
    ],
    settings: .settings(base: [
        "SWIFT_VERSION": "6.0",
        "SWIFT_STRICT_CONCURRENCY": "complete",
        "MACOSX_DEPLOYMENT_TARGET": "15.0",
        "MARKETING_VERSION": "0.1.0",
        "CURRENT_PROJECT_VERSION": "1",
        "CODE_SIGN_STYLE": "Automatic",
        "COPY_PHASE_STRIP": "NO",
        "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
        "DEVELOPMENT_TEAM": "",
        // Public verification key only. Missing setup keeps the updater inactive.
        "SPARKLE_ED_PUBLIC_KEY": .string(sparkleConfiguration.publicEDKey),
    ]),
    targets: [
        .target(
            name: "MoeKit",
            destinations: .macOS,
            product: .app,
            bundleId: "com.yusixian.MoeKit",
            deploymentTargets: .macOS("15.0"),
            // Tuist's macOS defaults include Main.storyboard; this app uses only
            // the SwiftUI App lifecycle, so declare the bundle keys explicitly.
            infoPlist: .dictionary([
                "CFBundleDisplayName": "MoeKit",
                "CFBundleDevelopmentRegion": "en",
                "CFBundleExecutable": "$(EXECUTABLE_NAME)",
                "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
                "CFBundleInfoDictionaryVersion": "6.0",
                "CFBundleName": "$(PRODUCT_NAME)",
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "CFBundleIconFile": "AppIcon",
                "CFBundleIconName": "AppIcon",
                "LSMinimumSystemVersion": "$(MACOSX_DEPLOYMENT_TARGET)",
                "NSHumanReadableCopyright": "Copyright © 2026 MoeKit",
                "NSHighResolutionCapable": true,
                "NSPrincipalClass": "NSApplication",
                "LSApplicationCategoryType": "public.app-category.developer-tools",
                "SUFeedURL": "https://raw.githubusercontent.com/cosZone/MoeKit/updates/appcast.xml",
                "SUPublicEDKey": "$(SPARKLE_ED_PUBLIC_KEY)",
                "SURequireSignedFeed": true,
                "SUVerifyUpdateBeforeExtraction": true,
                "SUSignedFeedFailureExpirationInterval": 0,
                "SUAutomaticallyUpdate": false,
                "SUEnableSystemProfiling": false,
                "SUEnableJavaScript": false,
            ]),
            sources: ["Sources/**"],
            resources: ["Resources/**"],
            scripts: [.post(
                script: """
                set -eu
                /bin/cp -p "${SCRIPT_INPUT_FILE_0}" "${SCRIPT_OUTPUT_FILE_0}"
                """,
                name: "Embed verified Mole analysis supervisor",
                inputPaths: ["$(MOLE_SUPERVISOR_SOURCE_DIR)/MoleAnalysisSupervisor"],
                outputPaths: ["$(TARGET_BUILD_DIR)/$(EXECUTABLE_FOLDER_PATH)/MoleAnalysisSupervisor"],
                basedOnDependencyAnalysis: true
            ), .post(
                script: """
                set -eu
                /bin/cp -p "${SCRIPT_INPUT_FILE_0}" "${SCRIPT_OUTPUT_FILE_0}"
                """,
                name: "Embed verified Git object inspector",
                inputPaths: ["$(GIT_INSPECTOR_SOURCE_DIR)/GitObjectInspector"],
                outputPaths: ["$(TARGET_BUILD_DIR)/$(EXECUTABLE_FOLDER_PATH)/GitObjectInspector"],
                basedOnDependencyAnalysis: true
            ), .post(
                script: """
                set -eu
                /bin/cp -p "${SCRIPT_INPUT_FILE_0}" "${SCRIPT_OUTPUT_FILE_0}"
                """,
                name: "Embed verified Git remote transport",
                inputPaths: ["$(GIT_TRANSPORT_SOURCE_DIR)/GitRemoteTransport"],
                outputPaths: ["$(TARGET_BUILD_DIR)/$(EXECUTABLE_FOLDER_PATH)/GitRemoteTransport"],
                basedOnDependencyAnalysis: true
            ), .post(
                script: """
                set -eu
                /bin/cp -p "${SCRIPT_INPUT_FILE_0}" "${SCRIPT_OUTPUT_FILE_0}"
                """,
                name: "Embed controlled operation terminal",
                inputPaths: ["$(OPERATION_TERMINAL_SOURCE_DIR)/OperationTerminal"],
                outputPaths: ["$(TARGET_BUILD_DIR)/$(EXECUTABLE_FOLDER_PATH)/OperationTerminal"],
                basedOnDependencyAnalysis: true
            )],
            dependencies: [.target(name: "OperationTerminal"), .package(product: "SwiftTerm", type: .runtime), .target(name: "MoleAnalysisSupervisor"), .target(name: "GitObjectInspector"), .target(name: "GitRemoteTransport"), .external(name: "Sparkle")],
            settings: .settings(base: [
                "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "",
                // Archive/install builds put SKIP_INSTALL helper products behind
                // a BUILT_PRODUCTS_DIR symlink. Declare the exact physical input
                // so the build script sandbox can read it without directory grants.
                "MOLE_SUPERVISOR_SOURCE_DIR": "$(MOLE_SUPERVISOR_SOURCE_DIR_$(DEPLOYMENT_LOCATION))",
                "MOLE_SUPERVISOR_SOURCE_DIR_NO": "$(BUILT_PRODUCTS_DIR)",
                "MOLE_SUPERVISOR_SOURCE_DIR_YES": "$(UNINSTALLED_PRODUCTS_DIR)/$(PLATFORM_NAME)",
                "GIT_INSPECTOR_SOURCE_DIR": "$(GIT_INSPECTOR_SOURCE_DIR_$(DEPLOYMENT_LOCATION))",
                "GIT_INSPECTOR_SOURCE_DIR_NO": "$(BUILT_PRODUCTS_DIR)",
                "GIT_INSPECTOR_SOURCE_DIR_YES": "$(UNINSTALLED_PRODUCTS_DIR)/$(PLATFORM_NAME)",
                "GIT_TRANSPORT_SOURCE_DIR": "$(GIT_TRANSPORT_SOURCE_DIR_$(DEPLOYMENT_LOCATION))",
                "GIT_TRANSPORT_SOURCE_DIR_NO": "$(BUILT_PRODUCTS_DIR)",
                "GIT_TRANSPORT_SOURCE_DIR_YES": "$(UNINSTALLED_PRODUCTS_DIR)/$(PLATFORM_NAME)",
                "OPERATION_TERMINAL_SOURCE_DIR": "$(OPERATION_TERMINAL_SOURCE_DIR_$(DEPLOYMENT_LOCATION))",
                "OPERATION_TERMINAL_SOURCE_DIR_NO": "$(BUILT_PRODUCTS_DIR)",
                "OPERATION_TERMINAL_SOURCE_DIR_YES": "$(UNINSTALLED_PRODUCTS_DIR)/$(PLATFORM_NAME)",
            ])
        ),
        .target(
            name: "MoleAnalysisSupervisor",
            destinations: .macOS,
            product: .commandLineTool,
            bundleId: "com.yusixian.MoeKit.MoleAnalysisSupervisor",
            deploymentTargets: .macOS("15.0"),
            sources: ["Helpers/MoleAnalysisSupervisor/main.c"],
            settings: .settings(base: [
                "SKIP_INSTALL": "YES",
                "CODE_SIGN_INJECT_BASE_ENTITLEMENTS": "NO",
                "OTHER_CFLAGS": "$(inherited) -Wall -Wextra -Werror",
                "OTHER_CODE_SIGN_FLAGS": "$(inherited) -i $(PRODUCT_BUNDLE_IDENTIFIER)",
            ])
        ),
        .target(
            name: "GitObjectInspector",
            destinations: .macOS,
            product: .commandLineTool,
            bundleId: "com.yusixian.MoeKit.GitObjectInspector",
            deploymentTargets: .macOS("15.0"),
            sources: ["Helpers/GitObjectInspector/main.c"],
            settings: .settings(base: [
                "SKIP_INSTALL": "YES",
                "CODE_SIGN_INJECT_BASE_ENTITLEMENTS": "NO",
                "OTHER_CFLAGS": "$(inherited) -Wall -Wextra -Werror",
                "OTHER_CODE_SIGN_FLAGS": "$(inherited) -i $(PRODUCT_BUNDLE_IDENTIFIER)",
            ])
        ),
        .target(
            name: "GitRemoteTransport",
            destinations: .macOS,
            product: .commandLineTool,
            bundleId: "com.yusixian.MoeKit.GitRemoteTransport",
            deploymentTargets: .macOS("15.0"),
            sources: ["Helpers/GitRemoteTransport/main.c"],
            settings: .settings(base: [
                "SKIP_INSTALL": "YES",
                "CODE_SIGN_INJECT_BASE_ENTITLEMENTS": "NO",
                "OTHER_CFLAGS": "$(inherited) -Wall -Wextra -Werror",
                "OTHER_CODE_SIGN_FLAGS": "$(inherited) -i $(PRODUCT_BUNDLE_IDENTIFIER)",
            ])
        ),
        .target(
            name: "OperationTerminal",
            destinations: .macOS,
            product: .commandLineTool,
            bundleId: "com.yusixian.MoeKit.OperationTerminal",
            deploymentTargets: .macOS("15.0"),
            sources: ["Helpers/OperationTerminal/main.c"],
            settings: .settings(base: [
                "SKIP_INSTALL": "YES",
                "CODE_SIGN_INJECT_BASE_ENTITLEMENTS": "NO",
                "OTHER_CFLAGS": "$(inherited) -Wall -Wextra -Werror",
                "OTHER_CODE_SIGN_FLAGS": "$(inherited) -i $(PRODUCT_BUNDLE_IDENTIFIER)",
            ])
        ),
        .target(
            name: "MoeKitTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.yusixian.MoeKitTests",
            deploymentTargets: .macOS("15.0"),
            sources: ["Tests/**/*.swift"],
            resources: ["Tests/Resources/**"],
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
