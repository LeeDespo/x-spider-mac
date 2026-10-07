import Foundation

/// 契约参数与结果的**值类型**。
///
/// # 为什么不用 `[String: Any]`
///
/// `Any` 不是 `Sendable`：Swift 6 的严格并发检查会拒绝把它跨 actor 边界传递
/// （`sending 'params' risks causing data races`）。而 `XSpiderAPI` 是 actor，
/// 组件客户端是另一个隔离域——这正是会踩到的地方。
///
/// 换成受限的枚举顺带还有两个好处：
/// 1. **契约里本来就只有这几种 JSON 类型**，枚举让"能传什么"一目了然；
/// 2. 调用方不会因为手滑传了个 `Date` 进去而在运行期才炸（编译期就过不去）。
enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// 从 `JSONSerialization` 的输出转换（只在组件客户端内部用一次）。
    static func from(_ any: Any) -> JSONValue {
        if any is NSNull { return .null }
        if let number = any as? NSNumber {
            // Bool 在 JSONSerialization 里也是 NSNumber，必须靠 CFBoolean 判类型
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            let double = number.doubleValue
            if double.rounded() == double, abs(double) < 9_007_199_254_740_992 {
                return .int(number.intValue)
            }
            return .double(double)
        }
        if let text = any as? String { return .string(text) }
        if let items = any as? [Any] { return .array(items.map(JSONValue.from)) }
        if let object = any as? [String: Any] {
            return .object(object.mapValues(JSONValue.from))
        }
        return .null
    }

    /// 交给 `JSONSerialization` 用。
    var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case let .bool(value): return value
        case let .int(value): return value
        case let .double(value): return value
        case let .string(value): return value
        case let .array(items): return items.map(\.anyValue)
        case let .object(fields): return fields.mapValues(\.anyValue)
        }
    }

    var asString: String? { if case let .string(value) = self { return value }; return nil }
    var asInt: Int? {
        switch self {
        case let .int(value): return value
        case let .double(value): return Int(value)
        default: return nil
        }
    }
    var asDouble: Double? {
        switch self {
        case let .double(value): return value
        case let .int(value): return Double(value)
        default: return nil
        }
    }
    var asBool: Bool? { if case let .bool(value) = self { return value }; return nil }
    var asArray: [JSONValue]? { if case let .array(items) = self { return items }; return nil }
    var asObject: [String: JSONValue]? { if case let .object(fields) = self { return fields }; return nil }
    var isNull: Bool { if case .null = self { return true }; return false }
}

extension Dictionary where Key == String, Value == JSONValue {
    /// 便捷取值：`params["cursor"]?.asString`
    subscript(string key: String) -> String? { self[key]?.asString }
    subscript(int key: String) -> Int? { self[key]?.asInt }
    subscript(bool key: String) -> Bool? { self[key]?.asBool }
    subscript(object key: String) -> [String: JSONValue]? { self[key]?.asObject }
    subscript(array key: String) -> [JSONValue]? { self[key]?.asArray }
}
