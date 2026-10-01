import Foundation

/// 给一段异步操作加**整体超时**。
///
/// 从已删除的 `NetworkClient` 搬出来：它与 HTTP 层无关，是通用的并发工具，
/// 而 `SyncStore` 用它给"单用户同步"设上限（150s）——同步卡住时不能让整个队列干等。
func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw URLError(.timedOut)
        }
        guard let result = try await group.next() else {
            throw URLError(.timedOut)
        }
        group.cancelAll()
        return result
    }
}
