import XCTest

/// 本地化覆盖率：英文表（键 = 源码中文原文）、源码里的调用点、以及打包用的简体中文表必须对得上。
/// 这些检查都跑真实文件 / 真实脚本，翻译时漏键、占位符顺序写错、中文表过期都会让测试变红。
final class LocalizationCoverageTests: XCTestCase {
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let englishTableURL = repositoryRoot.appendingPathComponent("Resources/en.lproj/Localizable.strings")
    private static let sourcesURL = repositoryRoot.appendingPathComponent("Sources")

    // MARK: - 英文表

    func testEnglishTableIsNotEmptyAndHasNoEmptyKeys() throws {
        let table = try englishTable()
        XCTAssertFalse(table.isEmpty, "英文文案表不能为空")
        XCTAssertTrue(table.keys.allSatisfy { !$0.isEmpty }, "英文文案表里不能有空键")
    }

    /// 漏译（空值）和占位符被吞掉 / 换序 / 改成别的类型，都会让插值在运行时错位。
    func testEnglishTableKeepsValuesAndFormatPlaceholders() throws {
        let table = try englishTable()
        var failures: [String] = []
        for key in table.keys.sorted() {
            let value = try XCTUnwrap(table[key])
            if value.isEmpty {
                failures.append("译文为空：\(quoted(key))")
            }
            let keyFormat = scanFormatSpecifiers(key)
            let valueFormat = scanFormatSpecifiers(value)
            if !keyFormat.invalid.isEmpty {
                failures.append("键里有不认识的占位符 \(keyFormat.invalid)：\(quoted(key))")
            }
            if !valueFormat.invalid.isEmpty {
                failures.append("译文里有不认识的占位符 \(valueFormat.invalid)：\(quoted(key)) → \(quoted(value))")
            }
            if keyFormat.specifiers != valueFormat.specifiers {
                failures.append("占位符不一致：\(quoted(key)) → \(quoted(value))（\(keyFormat.specifiers) · \(valueFormat.specifiers)）")
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testEnglishTableKeepsKnownTranslation() throws {
        let table = try englishTable()
        XCTAssertEqual(table["启动浏览器"], "Launch Browser", "英文表不能只剩空壳")
    }

    // MARK: - 源码调用点

    /// `L10n.text("中文…")` 的第一个参数是纯字面量（含相邻字面量拼接）且在表里必须找得到。
    func testEveryL10nTextLiteralExistsInEnglishTable() throws {
        let table = try englishTable()
        let sources = try swiftSources()
        XCTAssertFalse(sources.isEmpty, "没有扫到 Sources 下的 Swift 源码")

        var checked = 0
        var missing: [String] = []
        for source in sources {
            for site in source.tokens.l10nTextSites where containsHan(site.key) {
                checked += 1
                if table[site.key] == nil {
                    missing.append("\(source.path):\(site.line) 缺少 L10n 键 \(quoted(site.key))")
                }
            }
        }
        XCTAssertGreaterThan(checked, 0, "没有扫到任何 L10n.text 中文字面量")
        XCTAssertTrue(missing.isEmpty, missing.joined(separator: "\n"))
    }

    /// SwiftUI 自己按字面量查表：`Text("中文…")`、`Button("中文…")`、`.help("中文…")` 等也必须在表里。
    func testEverySwiftUITextLiteralExistsInEnglishTable() throws {
        let table = try englishTable()
        let sources = try swiftSources()
        XCTAssertFalse(sources.isEmpty, "没有扫到 Sources 下的 Swift 源码")

        var checked = 0
        var missing: [String] = []
        for source in sources {
            for site in source.tokens.swiftUITextSites where containsHan(site.key) {
                checked += 1
                if table[site.key] == nil {
                    missing.append("\(source.path):\(site.line) 缺少 SwiftUI 键 \(quoted(site.key))")
                }
            }
        }
        XCTAssertGreaterThan(checked, 0, "没有扫到任何 SwiftUI 中文字面量")
        XCTAssertTrue(missing.isEmpty, missing.joined(separator: "\n"))
    }

    // MARK: - 简体中文表

    /// 开发区域是简体中文：`make-zh-strings.swift` 生成的表必须和英文表键集一致，且每个值就是键本身。
    func testGeneratedChineseTableMirrorsEnglishTable() throws {
        let english = try englishTable()
        let chinese = try generatedChineseTable()
        XCTAssertEqual(Set(chinese.keys), Set(english.keys), "简体中文表的键集和英文表不一致")
        var failures: [String] = []
        for key in chinese.keys.sorted() where chinese[key] != key {
            failures.append("\(quoted(key)) → \(quoted(try XCTUnwrap(chinese[key])))")
        }
        XCTAssertTrue(failures.isEmpty, "简体中文表的值必须就是键本身：\n" + failures.joined(separator: "\n"))
    }

    // MARK: - 文件

    private func englishTable() throws -> [String: String] {
        let data = try Data(contentsOf: Self.englishTableURL)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(plist as? [String: String], "\(Self.englishTableURL.path) 不是字符串表")
    }

    private func generatedChineseTable() throws -> [String: String] {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalizationCoverageTests-\(UUID().uuidString).strings")
        defer { try? FileManager.default.removeItem(at: output) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "swift",
            Self.repositoryRoot.appendingPathComponent("scripts/make-zh-strings.swift").path,
            Self.englishTableURL.path,
            output.path,
        ]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, message)

        let data = try Data(contentsOf: output)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(plist as? [String: String], "生成的中文表不是字符串表")
    }

    private struct ScannedSource {
        let path: String
        let tokens: [SwiftToken]
    }

    private func swiftSources() throws -> [ScannedSource] {
        guard let enumerator = FileManager.default.enumerator(at: Self.sourcesURL, includingPropertiesForKeys: nil) else {
            throw XCTSkip("找不到 Sources 目录")
        }
        var urls: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            urls.append(url)
        }
        urls.sort { $0.path < $1.path }
        return try urls.map { url in
            var lexer = SwiftLexer(source: try String(contentsOf: url, encoding: .utf8))
            let path = url.path.replacingOccurrences(of: Self.repositoryRoot.path + "/", with: "")
            return ScannedSource(path: path, tokens: lexer.lex())
        }
    }

    // MARK: - 文本判断

    private func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F:
                return true
            default:
                return false
            }
        }
    }

    private func quoted(_ text: String) -> String {
        "\"\(text)\""
    }

    private struct FormatScan {
        var specifiers: [String] = []
        var invalid: [String] = []
    }

    /// 只认 `%@` / `%lld` / `%lf` / `%d`；`%%` 是字面百分号，跳过。其它 `%` 写法算错误。
    private func scanFormatSpecifiers(_ text: String) -> FormatScan {
        let characters = Array(text)
        var result = FormatScan()
        var index = 0
        while index < characters.count {
            guard characters[index] == "%" else {
                index += 1
                continue
            }
            if index + 1 < characters.count, characters[index + 1] == "%" {
                index += 2
            } else if hasPrefix(characters, at: index, "%lld") {
                result.specifiers.append("%lld")
                index += 4
            } else if hasPrefix(characters, at: index, "%lf") {
                result.specifiers.append("%lf")
                index += 3
            } else if hasPrefix(characters, at: index, "%@") {
                result.specifiers.append("%@")
                index += 2
            } else if hasPrefix(characters, at: index, "%d") {
                result.specifiers.append("%d")
                index += 2
            } else {
                result.invalid.append(String(characters[index..<min(index + 4, characters.count)]))
                index += 1
            }
        }
        return result
    }

    private func hasPrefix(_ characters: [Character], at index: Int, _ prefix: String) -> Bool {
        let prefix = Array(prefix)
        guard index + prefix.count <= characters.count else { return false }
        return characters[index..<(index + prefix.count)].elementsEqual(prefix)
    }
}

// MARK: - 轻量 Swift 词法

/// 只做定位字面量需要的事：跳过注释，识别标识符、标点、单行 / 多行 / raw 字符串和插值。
/// 这样注释或文档字符串里出现的 `Text("…")` 不会算成调用点，结构变化也不会被正则误吞。
private struct SwiftToken {
    enum Kind {
        case identifier(String)
        case string(String)
        case interpolatedString
        case punctuation(Character)
    }

    let kind: Kind
    let line: Int
}

private func isPunctuation(_ token: SwiftToken, _ character: Character) -> Bool {
    if case .punctuation(let value) = token.kind {
        return value == character
    }
    return false
}

private struct LocalizationSite {
    let key: String
    let line: Int
}

private extension Array where Element == SwiftToken {
    /// `L10n.text("…")` 的第一个参数是纯字面量；相邻字面量用 `+` 拼接时合成一个键。
    var l10nTextSites: [LocalizationSite] {
        var sites: [LocalizationSite] = []
        var index = 0
        while index + 3 < count {
            if case .identifier("L10n") = self[index].kind,
               isPunctuation(self[index + 1], "."),
               case .identifier("text") = self[index + 2].kind,
               isPunctuation(self[index + 3], "(") {
                var argument = index + 4
                if argument < count, case .string(let first) = self[argument].kind {
                    let line = self[argument].line
                    var key = first
                    argument += 1
                    while argument + 1 < count,
                          isPunctuation(self[argument], "+"),
                          case .string(let next) = self[argument + 1].kind {
                        key += next
                        argument += 2
                    }
                    if argument < count,
                       isPunctuation(self[argument], ",") || isPunctuation(self[argument], ")") {
                        sites.append(LocalizationSite(key: key, line: line))
                    }
                }
            }
            index += 1
        }
        return sites
    }

    /// SwiftUI 按 `LocalizedStringKey` 字面量查表的入口。只收单个字面量；插值和非字面量不在这里管。
    var swiftUITextSites: [LocalizationSite] {
        let initializers: Set<String> = ["Text", "Button", "Label", "Section", "Toggle", "Picker", "ContentUnavailableView"]
        let modifiers: Set<String> = ["help", "navigationTitle"]
        var sites: [LocalizationSite] = []
        for index in indices {
            if case .identifier(let name) = self[index].kind,
               initializers.contains(name),
               index + 3 < count,
               isPunctuation(self[index + 1], "("),
               case .string(let key) = self[index + 2].kind,
               isPunctuation(self[index + 3], ",") || isPunctuation(self[index + 3], ")") {
                sites.append(LocalizationSite(key: key, line: self[index + 2].line))
            }
            if isPunctuation(self[index], "."),
               index + 4 < count,
               case .identifier(let name) = self[index + 1].kind,
               modifiers.contains(name),
               isPunctuation(self[index + 2], "("),
               case .string(let key) = self[index + 3].kind,
               isPunctuation(self[index + 4], ",") || isPunctuation(self[index + 4], ")") {
                sites.append(LocalizationSite(key: key, line: self[index + 3].line))
            }
        }
        return sites
    }
}

private struct SwiftLexer {
    private struct StringDelimiter {
        let hashes: Int
        let quoteOffset: Int
        let isMultiline: Bool
    }

    private let characters: [Character]
    private var index = 0
    private var line = 1

    init(source: String) {
        characters = Array(source)
    }

    mutating func lex() -> [SwiftToken] {
        var tokens: [SwiftToken] = []
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace {
                advance()
                continue
            }
            if character == "/", peek(1) == "/" {
                skipLineComment()
                continue
            }
            if character == "/", peek(1) == "*" {
                skipBlockComment()
                continue
            }
            if let delimiter = stringDelimiter() {
                tokens.append(scanString(delimiter))
                continue
            }
            if isIdentifierStart(character) {
                let start = index
                let startLine = line
                while index < characters.count, isIdentifierPart(characters[index]) {
                    advance()
                }
                tokens.append(SwiftToken(kind: .identifier(String(characters[start..<index])), line: startLine))
                continue
            }
            tokens.append(SwiftToken(kind: .punctuation(character), line: line))
            advance()
        }
        return tokens
    }

    // MARK: 扫描基础

    private func peek(_ offset: Int) -> Character? {
        let position = index + offset
        return position < characters.count ? characters[position] : nil
    }

    private mutating func advance() {
        if characters[index] == "\n" {
            line += 1
        }
        index += 1
    }

    private mutating func advance(_ count: Int) {
        for _ in 0..<count {
            advance()
        }
    }

    private func isIdentifierStart(_ character: Character) -> Bool {
        character == "_" || character.isLetter
    }

    private func isIdentifierPart(_ character: Character) -> Bool {
        character == "_" || character.isLetter || character.isNumber
    }

    private mutating func skipLineComment() {
        advance(2)
        while index < characters.count, !characters[index].isNewline {
            advance()
        }
    }

    private mutating func skipBlockComment() {
        advance(2)
        var depth = 1
        while index < characters.count, depth > 0 {
            if characters[index] == "/", peek(1) == "*" {
                depth += 1
                advance(2)
            } else if characters[index] == "*", peek(1) == "/" {
                depth -= 1
                advance(2)
            } else {
                advance()
            }
        }
    }

    // MARK: 字符串

    private func stringDelimiter() -> StringDelimiter? {
        var cursor = index
        var hashes = 0
        while cursor < characters.count, characters[cursor] == "#" {
            hashes += 1
            cursor += 1
        }
        guard cursor < characters.count, characters[cursor] == "\"" else { return nil }
        let isMultiline = cursor + 2 < characters.count
            && characters[cursor + 1] == "\""
            && characters[cursor + 2] == "\""
        return StringDelimiter(hashes: hashes, quoteOffset: cursor - index, isMultiline: isMultiline)
    }

    private mutating func scanString(_ delimiter: StringDelimiter) -> SwiftToken {
        let startLine = line
        advance(delimiter.quoteOffset)
        advance(delimiter.isMultiline ? 3 : 1)

        var decoded = ""
        var interpolated = false

        if delimiter.isMultiline {
            // 起始 `"""` 后紧跟的换行不属于内容。
            if index < characters.count, characters[index] == "\r", peek(1) == "\n" {
                advance(2)
            } else if index < characters.count, characters[index].isNewline {
                advance()
            }
        }

        while index < characters.count {
            if isClosingDelimiter(delimiter) {
                advance(delimiter.isMultiline ? 3 : 1)
                advance(delimiter.hashes)
                let content = delimiter.isMultiline ? stripMultilineIndentation(decoded) : decoded
                return SwiftToken(kind: interpolated ? .interpolatedString : .string(content), line: startLine)
            }
            if isInterpolationStart(delimiter) {
                interpolated = true
                skipInterpolation(delimiter)
                continue
            }
            if characters[index] == "\\" {
                if let escape = consumeEscape(delimiter) {
                    decoded.append(escape)
                } else {
                    // raw 字符串里不构成转义的反斜杠是普通字符。
                    decoded.append("\\")
                    advance()
                }
                continue
            }
            if !delimiter.isMultiline, characters[index].isNewline {
                // 单行字符串没闭合（源码本身编译不过）；停止，别把后面的文件吞掉。
                break
            }
            decoded.append(characters[index])
            advance()
        }

        return SwiftToken(kind: interpolated ? .interpolatedString : .string(decoded), line: startLine)
    }

    private func isClosingDelimiter(_ delimiter: StringDelimiter) -> Bool {
        if delimiter.isMultiline {
            guard index + 2 < characters.count,
                  characters[index] == "\"",
                  characters[index + 1] == "\"",
                  characters[index + 2] == "\"" else { return false }
            return hashesFollow(count: delimiter.hashes, from: index + 3)
        }
        guard characters[index] == "\"" else { return false }
        return hashesFollow(count: delimiter.hashes, from: index + 1)
    }

    private func hashesFollow(count: Int, from position: Int) -> Bool {
        guard position + count <= characters.count else { return false }
        for offset in 0..<count where characters[position + offset] != "#" {
            return false
        }
        return true
    }

    private func isInterpolationStart(_ delimiter: StringDelimiter) -> Bool {
        guard characters[index] == "\\" else { return false }
        var cursor = index + 1
        for _ in 0..<delimiter.hashes {
            guard cursor < characters.count, characters[cursor] == "#" else { return false }
            cursor += 1
        }
        return cursor < characters.count && characters[cursor] == "("
    }

    /// 返回 nil 表示这个反斜杠不是转义（raw 字符串里的普通字符）。
    private mutating func consumeEscape(_ delimiter: StringDelimiter) -> String? {
        var cursor = index + 1
        for _ in 0..<delimiter.hashes {
            guard cursor < characters.count, characters[cursor] == "#" else { return nil }
            cursor += 1
        }
        guard cursor < characters.count else { return nil }
        let escaped = characters[cursor]

        if delimiter.isMultiline, escaped.isNewline {
            // 反斜杠换行：吞掉换行和下一行缩进。
            advance(cursor - index + 1)
            while index < characters.count, characters[index] == " " || characters[index] == "\t" {
                advance()
            }
            return ""
        }

        if escaped == "u", cursor + 1 < characters.count, characters[cursor + 1] == "{" {
            var end = cursor + 2
            var hex = ""
            while end < characters.count, characters[end] != "}" {
                hex.append(characters[end])
                end += 1
            }
            if end < characters.count, let value = UInt32(hex, radix: 16), let scalar = UnicodeScalar(value) {
                advance(end - index + 1)
                return String(Character(scalar))
            }
        }

        guard let decoded = Self.decodeEscape(escaped) else { return nil }
        advance(cursor - index + 1)
        return decoded
    }

    private static func decodeEscape(_ character: Character) -> String? {
        switch character {
        case "0": return "\0"
        case "\\": return "\\"
        case "t": return "\t"
        case "n": return "\n"
        case "r": return "\r"
        case "\"": return "\""
        case "'": return "'"
        default: return nil
        }
    }

    private mutating func skipInterpolation(_ delimiter: StringDelimiter) {
        // 跳过 `\(` / `\#(` 本身。
        advance(1 + delimiter.hashes + 1)
        var depth = 1
        while index < characters.count, depth > 0 {
            if let nested = stringDelimiter() {
                _ = scanString(nested)
                continue
            }
            if characters[index] == "/", peek(1) == "/" {
                skipLineComment()
            } else if characters[index] == "/", peek(1) == "*" {
                skipBlockComment()
            } else if characters[index] == "(" {
                depth += 1
                advance()
            } else if characters[index] == ")" {
                depth -= 1
                advance()
            } else {
                advance()
            }
        }
    }

    /// Swift 多行字面量会去掉闭合 `"""` 所在行的缩进；数据库里的键就是去掉缩进后的结果。
    private func stripMultilineIndentation(_ content: String) -> String {
        guard let lastNewline = content.lastIndex(where: { $0.isNewline }) else {
            return content
        }
        let indentation = String(content[content.index(after: lastNewline)...])
        let body = String(content[..<lastNewline])
        return body
            .components(separatedBy: "\n")
            .map { $0.hasPrefix(indentation) ? String($0.dropFirst(indentation.count)) : $0 }
            .joined(separator: "\n")
    }
}
