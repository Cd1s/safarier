#!/usr/bin/env swift
import Foundation

/// 开发区域是简体中文：界面文案的键就是中文原文，中文表把每个键原样写成值。
/// 打包脚本和 scripts/dev.sh 用它在 Resources 里生成 zh-Hans.lproj，避免仓库里再放一份会漂移的副本。
/// 用法：scripts/make-zh-strings.swift <en.lproj/Localizable.strings> <输出文件>
let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("用法：scripts/make-zh-strings.swift <en Localizable.strings> <输出路径>\n".utf8))
    exit(2)
}

let source = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
guard let table = try PropertyListSerialization.propertyList(from: source, format: nil) as? [String: String] else {
    FileHandle.standardError.write(Data("无法解析 \(arguments[1])：不是 .strings 表\n".utf8))
    exit(1)
}

func escape(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
}

var lines = ["/* 自动生成：简体中文是开发区域，键就是文案本身。改文案请改 Resources/en.lproj/Localizable.strings。 */\n"]
for key in table.keys.sorted() {
    lines.append("\"\(escape(key))\" = \"\(escape(key))\";\n")
}
try Data(lines.joined().utf8).write(to: URL(fileURLWithPath: arguments[2]))
