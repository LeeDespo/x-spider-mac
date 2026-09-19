import Foundation
import AVFoundation

/// 视频字幕（闭路字幕 / 字幕轨）支持。
///
/// ## 可用性
///
/// 用的是 AVFoundation 的媒体选择 API：
/// `AVPlayerItem.select(_:in:)` 与 `AVAsset.mediaSelectionGroup(forMediaCharacteristic:)`，
/// 二者均为 **macOS 10.8+**（`AVMediaSelectionGroup` 也是 10.8+）。
/// 项目基线是 **macOS 15.0**，因此**无需任何版本判断或降级分支**——
/// 直接使用即可（符合 AGENTS.md「不要为版本差异写降级分支」）。
///
/// 注意：这里选的是**视频自带的字幕轨**（作者内嵌的），
/// 不是翻译功能——若视频没有字幕轨，按钮根本不显示。
/// X 的视频通常**没有**内嵌字幕，所以此功能多数时候不会出现，
/// 这是正常现象，不是 bug。
enum SubtitleSupport {

    /// 取「可读文本」媒体选择组（字幕/闭路字幕都属于 legible）
    static func legibleGroup(for item: AVPlayerItem) -> AVMediaSelectionGroup? {
        item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible)
    }

    /// 列出该视频可选的字幕（不含「自动」「关闭字幕」这类占位项）
    static func availableOptions(for item: AVPlayerItem) async -> [SubtitleOption] {
        guard let group = legibleGroup(for: item) else { return [] }
        return group.options
            .filter { !$0.isMediaSelectionOptionEmpty }
            .map { SubtitleOption(option: $0) }
    }
}

/// 一条可选字幕。用 `AVMediaSelectionOption` 的稳定标识做 `id`，
/// 便于菜单勾选当前项。
struct SubtitleOption: Identifiable, Hashable {
    let option: AVMediaSelectionOption

    var id: String {
        // locale 可能为 nil，用语言标签兜底；再不行用 displayName
        option.extendedLanguageTag ?? option.locale?.identifier ?? option.displayName
    }

    /// 展示名：优先本地化语言名（用户看得懂），否则用轨道自带名
    var displayName: String {
        if let tag = option.extendedLanguageTag,
           let name = Locale.current.localizedString(forLanguageCode: tag) {
            return name
        }
        if let id = option.locale?.identifier,
           let name = Locale.current.localizedString(forIdentifier: id) {
            return name
        }
        return option.displayName
    }

    static func == (lhs: SubtitleOption, rhs: SubtitleOption) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

private extension AVMediaSelectionOption {
    /// 是否为「占位/不可用」轨道。
    ///
    /// 字幕组里可能混入几类不是真实语言轨的选项（如名为 "Off" 的关闭项、
    /// 以及强制字幕 forced-only）。这类展示在菜单里会让用户困惑，
    /// 因此过滤掉——只留真正能选的语言轨。
    var isMediaSelectionOptionEmpty: Bool {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return true }
        // 各语言下的 "Off" / "关闭" 这类占位项
        if name.caseInsensitiveCompare("off") == .orderedSame { return true }
        return false
    }
}
