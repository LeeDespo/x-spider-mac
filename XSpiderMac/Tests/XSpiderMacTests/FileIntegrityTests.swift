import XCTest
@testable import XSpiderMac

/// 下载完整性校验回归测试。
///
/// 背景：实测（2026-09-17）aria2next 对不可达 URL 下载失败后会留下 **0 字节文件**，
/// 而旧代码把"文件存在"当作成功（还额外放行 exit 1）→ 坏文件被标记完成、写入下载记录、
/// 永不重试。这是成批出现损坏文件的根因。以下测试锁死新的判据。
final class FileIntegrityTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileIntegrityTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func write(_ bytes: [UInt8], name: String = "f.jpg") throws -> String {
        let url = tempDir.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url.path
    }

    // MARK: - 空文件（损坏的第一现场）

    /// 0 字节必须判失败——这正是实测复现出来的 aria2 失败残留
    func testEmptyFileIsRejected() throws {
        let path = try write([])
        let result = FileIntegrity.verify(path: path, expectedTotal: 0, type: .photo)
        guard case .failure(let reason) = result else {
            return XCTFail("0 字节文件必须判失败")
        }
        XCTAssertEqual(reason, .empty)
    }

    func testMissingFileIsRejected() {
        let path = tempDir.appendingPathComponent("nope.jpg").path
        let result = FileIntegrity.verify(path: path, expectedTotal: 0, type: .photo)
        guard case .failure(let reason) = result else {
            return XCTFail("缺失文件必须判失败")
        }
        XCTAssertEqual(reason, .missing)
    }

    /// 大小不符（下了一半）必须判失败
    func testTruncatedFileIsRejected() throws {
        // JPEG 魔数 + 少量数据，但声称应有 1MB
        let path = try write([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01])
        let result = FileIntegrity.verify(path: path, expectedTotal: 1_048_576, type: .photo)
        guard case .failure(let reason) = result else {
            return XCTFail("大小不符必须判失败")
        }
        if case .truncated(let expected, let actual) = reason {
            XCTAssertEqual(expected, 1_048_576)
            XCTAssertEqual(actual, 12)
        } else {
            XCTFail("应为 truncated，实际 \(reason)")
        }
    }

    // MARK: - 内容级伪装（CDN 返回错误页却 200）

    /// HTML 错误页：旧代码只看"文件存在"会放行，必须被拦下
    func testHTMLErrorPageIsRejected() throws {
        let html = Array("<html><body>Rate limited</body></html>".utf8)
        let path = try write(html)
        let result = FileIntegrity.verify(path: path, expectedTotal: 0, type: .photo)
        guard case .failure(let reason) = result else {
            return XCTFail("HTML 错误页必须判失败")
        }
        XCTAssertEqual(reason, .htmlErrorPage)
    }

    /// JSON 错误响应（X 的 CDN 有时返回 JSON）
    func testJSONErrorPayloadIsRejected() throws {
        let json = Array(#"{"error":"rate limited"}"#.utf8)
        let path = try write(json)
        let result = FileIntegrity.verify(path: path, expectedTotal: 0, type: .photo)
        guard case .failure(let reason) = result else {
            return XCTFail("JSON 错误响应必须判失败")
        }
        XCTAssertEqual(reason, .htmlErrorPage)
    }

    /// 照片位置却是非图片内容 → 判失败
    func testNonImageContentRejectedForPhoto() throws {
        let junk = Array("this is definitely not an image".utf8)
        let path = try write(junk)
        let result = FileIntegrity.verify(path: path, expectedTotal: 0, type: .photo)
        guard case .failure(let reason) = result else {
            return XCTFail("非图片内容在 photo 类型上必须判失败")
        }
        XCTAssertEqual(reason, .notAnImage)
    }

    // MARK: - 正常图片通过（各种魔数）

    func testValidJPEGPasses() throws {
        let path = try write([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01])
        guard case .success(let size) = FileIntegrity.verify(path: path, expectedTotal: 0, type: .photo) else {
            return XCTFail("有效 JPEG 应通过")
        }
        XCTAssertEqual(size, 12)
    }

    func testValidPNGPasses() throws {
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D]
        let path = try write(png, name: "f.png")
        guard case .success = FileIntegrity.verify(path: path, expectedTotal: 0, type: .photo) else {
            return XCTFail("有效 PNG 应通过")
        }
    }

    func testValidGIFPasses() throws {
        let gif: [UInt8] = Array("GIF89a".utf8) + [0x01, 0x00, 0x01, 0x00, 0x00]
        let path = try write(gif, name: "f.gif")
        guard case .success = FileIntegrity.verify(path: path, expectedTotal: 0, type: .photo) else {
            return XCTFail("有效 GIF 应通过")
        }
    }

    func testValidWebPPasses() throws {
        var webp: [UInt8] = Array("RIFF".utf8) + [0x00, 0x00, 0x00, 0x00] + Array("WEBP".utf8)
        webp.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        let path = try write(webp, name: "f.webp")
        guard case .success = FileIntegrity.verify(path: path, expectedTotal: 0, type: .photo) else {
            return XCTFail("有效 WebP 应通过")
        }
    }

    /// 视频不做魔数校验（容器多样：mp4/webm/m3u8 分片），只校验非空与非错误页
    func testVideoSkipsMagicCheck() throws {
        let mp4: [UInt8] = [0x00, 0x00, 0x00, 0x18] + Array("ftypisom".utf8) + [0x00] 
        let path = try write(mp4, name: "f.mp4")
        guard case .success = FileIntegrity.verify(path: path, expectedTotal: 0, type: .video) else {
            return XCTFail("视频文件不应因魔数校验被拒")
        }
    }

    /// 期望大小完全匹配时通过（且不影响魔数校验）
    func testExactSizeMatchPasses() throws {
        let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01]
        let path = try write(jpeg)
        guard case .success(let size) = FileIntegrity.verify(path: path, expectedTotal: 12, type: .photo) else {
            return XCTFail("大小匹配应通过")
        }
        XCTAssertEqual(size, 12)
    }
}
