import SwiftUI
import AppKit

/// 文件名模板输入框。
///
/// **为什么不用 SwiftUI 的 `TextField`**：点"可用变量"要把 `%XXX%` 插到**光标处**，
/// 而 SwiftUI 的 `TextField` 不暴露选区。这里包一层 `NSTextField`，
/// 通过 `currentEditor()`（字段编辑器）拿到当前选区来插入。
///
/// 语义（用户要求）：**输入框没有聚焦时，点变量什么都不做**——
/// `currentEditor()` 为 nil 就是"没在编辑"，此时直接返回 false，不产生任何副作用。
struct TemplateTextField: NSViewRepresentable {
    @Binding var text: String
    /// 创建后把"插入器"交回给父视图，父视图点变量时调用它。
    var onReady: (Inserter) -> Void

    /// 往输入框光标处插入片段的入口。
    final class Inserter {
        fileprivate weak var field: NSTextField?
        fileprivate var onChange: ((String) -> Void)?

        /// 把 `snippet` 插到光标处（有选区则替换选区）。
        /// **未聚焦时什么都不做**并返回 `false`——这正是用户要的语义。
        @discardableResult
        func insert(_ snippet: String) -> Bool {
            guard let field, let editor = field.currentEditor() as? NSTextView else { return false }
            let range = editor.selectedRange()
            editor.replaceCharacters(in: range, with: snippet)
            // 光标落到插入内容之后，连着点两个变量不会挤在一起
            let caret = range.location + (snippet as NSString).length
            editor.setSelectedRange(NSRange(location: caret, length: 0))
            onChange?(field.stringValue)
            return true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.delegate = context.coordinator
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.placeholderString = "%POST_TIME% %USER_SCREEN_NAME% %POST_ID%-%MEDIA_INDEX%%EXT%"
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        context.coordinator.inserter.field = field
        context.coordinator.inserter.onChange = { [weak coordinator = context.coordinator] value in
            coordinator?.parent.text = value
        }
        // 交给父视图（异步一拍：makeNSView 期间不能改父视图的 @State）
        let inserter = context.coordinator.inserter
        DispatchQueue.main.async { onReady(inserter) }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        // 外部改动了文本（例如以后有"恢复默认"按钮）→ 同步到控件；
        // 正在编辑时不覆盖，否则会把用户的光标挤掉。
        if field.currentEditor() == nil, field.stringValue != text {
            field.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TemplateTextField
        let inserter = Inserter()

        init(_ parent: TemplateTextField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
    }
}
