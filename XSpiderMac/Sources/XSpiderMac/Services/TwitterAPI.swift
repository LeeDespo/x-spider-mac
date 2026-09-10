import Foundation

actor TwitterAPI {
    static let shared = TwitterAPI()

    private let host = "x.com"
    private var client = NetworkClient()
    private var cookieString: String = ""

    func configure(cookie: String, proxy: ProxySettings) {
        self.cookieString = cookie
        self.client = NetworkClient(proxy: proxy)
    }

    private func commonHeaders(withCredentials: Bool = true) -> [String: String] {
        var headers: [String: String] = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
            "Referer": "https://\(host)",
        ]
        if withCredentials {
            headers["Authorization"] = "Bearer AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZzSnriE"
            headers["Cookie"] = cookieString
            headers["X-Csrf-Token"] = parseCookie(cookieString)["ct0"] ?? ""
        }
        return headers
    }

    func getAccountInfo(cookieString: String? = nil) async throws -> TwitterAccountInfo {
        let url = URL(string: "https://\(host)")!
        var headers = commonHeaders(withCredentials: false)
        if let cookie = cookieString { headers["Cookie"] = cookie }
        let resp = try await client.request(url: url, headers: headers, responseType: .text)
        let html = resp.text()
        let screenName = extract(pattern: #""screen_name":"(.*?)""#, from: html) ?? ""
        let avatar = extract(pattern: #""profile_image_url_https":"(.*?)""#, from: html) ?? ""
        if screenName.isEmpty { throw TwitterAPIError.missingScreenName }
        return TwitterAccountInfo(screenName: screenName, avatar: avatar)
    }

    func getUser(screenName: String) async throws -> TwitterUser {
        let url = URL(string: "https://\(host)/i/api/graphql/NimuplG1OB7Fd2btCLdBOw/UserByScreenName")!
        let variables = "{\"screen_name\":\"\(screenName)\"}"
        let resp = try await client.request(
            url: url,
            query: ["variables": variables],
            headers: commonHeaders(),
            responseType: .json
        )
        guard let json = (try? resp.json()) as? [String: Any],
              let data = json["data"] as? [String: Any],
              let user = data["user"] as? [String: Any],
              let result = user["result"] as? [String: Any],
              let legacy = result["legacy"] as? [String: Any],
              let restId = result["rest_id"] as? String else {
            throw TwitterAPIError.userNotFound
        }
        return TwitterUser(
            screenName: legacy["screen_name"] as? String ?? screenName,
            avatar: legacy["profile_image_url_https"] as? String ?? "",
            name: legacy["name"] as? String ?? "",
            id: restId,
            mediaCount: legacy["media_count"] as? Int,
            registerTime: parseTwitterDate(legacy["created_at"] as? String)
        )
    }
}

enum TwitterAPIError: Error {
    case parseFailure
    case missingScreenName
    case userNotFound
}

private func parseCookie(_ string: String) -> [String: String] {
    var result: [String: String] = [:]
    for part in string.split(separator: ";") {
        let kv = part.split(separator: "=", maxSplits: 1)
        if kv.count == 2 {
            result[String(kv[0]).trimmingCharacters(in: .whitespaces)] = String(kv[1])
        }
    }
    return result
}

private func extract(pattern: String, from: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
          let match = regex.firstMatch(in: from, options: [], range: NSRange(from.startIndex..., in: from)) else { return nil }
    let range = Range(match.range(at: 1), in: from)
    return range.map { String(from[$0]) }
}

private func parseTwitterDate(_ string: String?) -> Date? {
    guard let string else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "EEE MMM dd HH:mm:ss zzz yyyy"
    return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
}
