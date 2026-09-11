import Foundation

extension String {
    /// 路径组件安全化：替换 / 与非法字符，用于「昵称-@用户名」目录名
    func safePathComponent() -> String {
        let invalid = CharacterSet(charactersIn: #"/\"#).union(.controlCharacters)
        let cleaned = unicodeScalars.map { invalid.contains($0) ? "-" : String($0) }.joined()
        return cleaned.isEmpty ? "unknown-user" : cleaned
    }
}
