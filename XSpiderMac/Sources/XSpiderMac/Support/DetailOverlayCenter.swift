import SwiftUI

/// 推文详情浮层的全局中枢：任何页面都能打开；ContentView 在 NavigationSplitView 之上挂全窗浮层。
/// 挂在全窗层级 = 浮层覆盖边栏,点击边栏/任何非卡区都会命中浮层命中层 → 退出。
@MainActor
@Observable
final class DetailOverlayCenter {
    static let shared = DetailOverlayCenter()

    var post: TwitterPost?
    var initialMediaIndex: Int = 0

    /// 点击头像 → 搜索该用户(由 ContentView 注入,内部转通知)
    var onSearchUser: ((String) -> Void)?

    func open(_ post: TwitterPost, mediaIndex: Int = 0) {
        initialMediaIndex = mediaIndex
        self.post = post
    }

    func close() {
        post = nil
    }
}
