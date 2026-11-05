import Foundation

/// 界面文案的英文翻译在 Resources/en.lproj/Localizable.strings，键就是源码里的中文原文：
/// SwiftUI 的 `Text("…")` 等按字面量自动查表，普通 `String` 和带插值的文案走 `L10n.text`。
/// 需要插值时键里写 `%@` / `%lld` / `%lf`（和 SwiftUI 的 `LocalizedStringKey` 一致），调用处传参数。
/// 查不到翻译时返回中文原文，等同于没做本地化。
public enum L10n {
    public static func text(_ key: String, _ arguments: CVarArg...) -> String {
        let format = NSLocalizedString(key, comment: "")
        guard !arguments.isEmpty else { return format }
        return String(format: format, arguments: arguments)
    }
}
