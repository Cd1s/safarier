import XCTest
@testable import SafarierCore

final class SPIFeaturesTests: XCTestCase {
    func testParsing() throws {
        XCTAssertEqual(try SPIFeatures(parsing: "all"), .all)
        XCTAssertEqual(try SPIFeatures(parsing: "none"), [])
        XCTAssertEqual(try SPIFeatures(parsing: " AFP , tz "), [.fingerprintingProtections, .engineTimeZone])
        XCTAssertEqual(try SPIFeatures(parsing: "webrtc"), .disableWebRTC)
        XCTAssertThrowsError(try SPIFeatures(parsing: "afp,canvas")) {
            XCTAssertEqual($0 as? SPIFeaturesParseError, .unknownToken("canvas"))
        }
        XCTAssertThrowsError(try SPIFeatures(parsing: "  ")) {
            XCTAssertEqual($0 as? SPIFeaturesParseError, .empty)
        }
    }

    func testDescriptionRoundTrips() throws {
        for features in [SPIFeatures(), .all, [.engineTimeZone, .disableWebRTC]] {
            XCTAssertEqual(try SPIFeatures(parsing: features.description), features)
        }
        XCTAssertEqual(SPIFeatures.all.description, "afp,tz,webrtc,safari,webgpu,fontlist")
        XCTAssertEqual(try SPIFeatures(parsing: "webgpu"), .webGPU)
        XCTAssertEqual(try SPIFeatures(parsing: "afp,safari"), [.fingerprintingProtections, .safariAPIs])
        XCTAssertEqual(SPIFeatures().description, "none")
    }

    /// fontlist 现在包含在 all 和默认集合里。
    func testFontAllowlistIsInAllAndDefaults() throws {
        XCTAssertEqual(try SPIFeatures(parsing: "fontlist"), .fontAllowlist)
        XCTAssertEqual(try SPIFeatures(parsing: " SAFARI , FontList "), [.safariAPIs, .fontAllowlist])
        let combined: SPIFeatures = [.safariAPIs, .fontAllowlist]
        XCTAssertEqual(combined.description, "safari,fontlist")
        XCTAssertEqual(try SPIFeatures(parsing: combined.description), combined)

        XCTAssertTrue(SPIFeatures.all.contains(.fontAllowlist))
        XCTAssertEqual(try SPIFeatures(parsing: "afp,tz,webrtc,safari,webgpu,fontlist"), .all)
    }

    /// 新建环境默认：高级隐私保护、引擎层时区、Safari 专有接口与字体、按语言收窄字体；WebRTC 关闭和 WebGPU 不默认开。
    func testDefaultFeatures() throws {
        XCTAssertEqual(SPIFeatures.defaultFeatures, [.fingerprintingProtections, .engineTimeZone, .safariAPIs, .fontAllowlist])
        XCTAssertFalse(SPIFeatures.defaultFeatures.contains(.disableWebRTC))
        XCTAssertFalse(SPIFeatures.defaultFeatures.contains(.webGPU))
        XCTAssertEqual(try SPIFeatures(parsing: "default"), .defaultFeatures)
        XCTAssertEqual(Profile(name: "p", mode: .ephemeral).spi, .defaultFeatures)
    }

    func testCodableUsesTokensAndIgnoresUnknown() throws {
        let data = try JSONEncoder().encode(SPIFeatures([.fingerprintingProtections, .disableWebRTC]))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"["afp","webrtc"]"#)
        let decoded = try JSONDecoder().decode(SPIFeatures.self, from: Data(#"["tz","future-thing"]"#.utf8))
        XCTAssertEqual(decoded, .engineTimeZone)
    }

    func testProfileWithoutSPIKeyDecodesAsNone() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"old","mode":"persistent","createdAt":0}"#
        XCTAssertEqual(try JSONDecoder().decode(Profile.self, from: Data(json.utf8)).spi, [])

        let profile = Profile(name: "p", mode: .ephemeral, spi: .all)
        let decoded = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(decoded.spi, .all)
    }
}
