import XCTest

/// `scripts/build-app.sh` 生成的 Info.plist：允许系统框架按进程语言本地化，并声明和 Safari.app 一样的语言。
/// 只写开发区域 zh-Hans 时 CFBundle 把 App 锁成简体中文，WebKit 跟着走，英文 / 繁体环境的网页也会读到
/// 简体中文的 navigator.mimeTypes 描述和表单校验提示，和真 Safari 对不上。
final class BuildAppInfoPlistTests: XCTestCase {
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// 跑真正的打包脚本（只生成 Info.plist 的模式），读出生成的字典。
    private func generatedInfoPlist() throws -> [String: Any] {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("BuildAppInfoPlistTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: output) }
        let plist = output.appendingPathComponent("Contents/Info.plist")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Self.repositoryRoot.appendingPathComponent("scripts/build-app.sh").path, "--info-plist", plist.path]
        var environment = ProcessInfo.processInfo.environment
        environment["SAFARIER_VERSION"] = "9.9.9"
        environment["SAFARIER_BUILD"] = "42"
        process.environment = environment
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, message)
        let data = try Data(contentsOf: plist)
        return try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func testInfoPlistAllowsMixedLocalizationsAndDeclaresSafariLanguages() throws {
        let info = try generatedInfoPlist()
        XCTAssertEqual(info["CFBundleAllowMixedLocalizations"] as? Bool, true)
        XCTAssertEqual(info["CFBundleDevelopmentRegion"] as? String, "zh-Hans", "界面文案仍是简体中文")

        let localizations = try XCTUnwrap(info["CFBundleLocalizations"] as? [String])
        XCTAssertEqual(localizations.count, Set(localizations).count, "没有重复")
        for language in ["en", "en_GB", "zh-Hans", "zh-Hant", "zh_CN", "zh_HK", "zh_TW", "ja", "ko", "fr", "de", "es", "pt_PT", "th", "vi"] {
            XCTAssertTrue(localizations.contains(language), "缺少 \(language)")
        }
        XCTAssertEqual(localizations.count, 42)

        // 模板里的变量照常替换，其它键不受影响。
        XCTAssertEqual(info["CFBundleShortVersionString"] as? String, "9.9.9")
        XCTAssertEqual(info["CFBundleVersion"] as? String, "42")
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, "sh.safarier.app")
        XCTAssertEqual(info["CFBundleExecutable"] as? String, "Safarier")
    }

    /// 本机装着 Safari 时，它带的每一种语言（Resources 下的 .lproj，Base 除外）都要在声明里。
    func testDeclaredLanguagesCoverInstalledSafari() throws {
        let resources = URL(fileURLWithPath: "/Applications/Safari.app/Contents/Resources")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: resources.path) else {
            throw XCTSkip("本机没有 /Applications/Safari.app")
        }
        let safariLanguages = Set(entries.filter { $0.hasSuffix(".lproj") }.map { String($0.dropLast(".lproj".count)) }).subtracting(["Base"])
        XCTAssertFalse(safariLanguages.isEmpty)
        let declared = Set(try XCTUnwrap(try generatedInfoPlist()["CFBundleLocalizations"] as? [String]))
        XCTAssertTrue(safariLanguages.isSubset(of: declared), "Safari 有而我们没声明：\(safariLanguages.subtracting(declared).sorted())")
    }

    func testInfoPlistModeRequiresPath() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Self.repositoryRoot.appendingPathComponent("scripts/build-app.sh").path, "--info-plist"]
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 2, "没给路径时报用法错误，不去编译打包")
    }
}
