import XCTest
@testable import SafarierCore

final class MacDeviceModelTests: XCTestCase {
    func testPresetsMatchSpec() throws {
        XCTAssertEqual(MacDeviceModel.presets.count, 34)
        XCTAssertEqual(Set(MacDeviceModel.presets.map(\.id)).count, 34)
        // 旧数据里存的 4 个 id 必须还能找到。
        for id in ["macbook-pro-16-m3-max", "macbook-pro-14-m3-pro", "mac-studio-m2-ultra", "macbook-air-13-m2"] {
            XCTAssertNotNil(MacDeviceModel.preset(id), id)
        }

        let mbp16 = try XCTUnwrap(MacDeviceModel.preset("macbook-pro-16-m3-max"))
        XCTAssertEqual(mbp16.name, "MacBook Pro 16\" (M3 Max)")
        XCTAssertEqual(mbp16.chip, "Apple M3 Max")
        XCTAssertEqual([mbp16.cpuCores, mbp16.gpuCores], [16, 40])
        XCTAssertEqual([mbp16.viewportWidth, mbp16.viewportHeight, mbp16.pixelWidth, mbp16.pixelHeight], [1728, 1117, 3456, 2234])

        XCTAssertEqual(MacDeviceModel.preset("macbook-pro-14-m3-pro")?.viewportSize, CGSize(width: 1512, height: 982))
        XCTAssertEqual(MacDeviceModel.preset("mac-studio-m2-ultra")?.cpuCores, 24)
        XCTAssertEqual(MacDeviceModel.preset("mac-studio-m2-ultra")?.gpuCores, 76)
        XCTAssertEqual(MacDeviceModel.preset("macbook-air-13-m2")?.viewportSize, CGSize(width: 1470, height: 956))
        XCTAssertNil(MacDeviceModel.preset("iphone"))
    }

    /// MacBook Pro 是 XDR（P3 + HDR）；MacBook Air、iMac 是 P3 + SDR；Mac Studio 按接 Studio Display（5K Retina，P3，SDR）算。
    func testDisplayTraitsMatchRealHardware() throws {
        for model in MacDeviceModel.presets where model.id.hasPrefix("macbook-pro") {
            XCTAssertTrue(model.displayP3 && model.displayHDR, model.name)
            XCTAssertGreaterThan(model.maxEDRHeadroom, 1)
            XCTAssertEqual(model.scale, 2, model.name)
        }
        for model in MacDeviceModel.presets where model.id.hasPrefix("macbook-air") || model.id.hasPrefix("imac") {
            XCTAssertTrue(model.displayP3 && !model.displayHDR, model.name)
            XCTAssertEqual(model.scale, 2, model.name)
        }
        let studio = MacDeviceModel.macStudioM2Ultra
        XCTAssertEqual([studio.screenWidth, studio.screenHeight, studio.scale], [2560, 1440, 2], "Studio Display 5K 默认「看起来像」2560×1440")
        XCTAssertEqual([studio.viewportWidth, studio.viewportHeight], [1600, 960])
        XCTAssertTrue(studio.displayP3)
        XCTAssertFalse(studio.displayHDR)
        XCTAssertEqual([studio.cpuCores, studio.gpuCores], [24, 76])

        let mini = try XCTUnwrap(MacDeviceModel.preset("mac-mini-m2"))
        XCTAssertEqual(mini.scale, 2)
        XCTAssertFalse(mini.displayP3 || mini.displayHDR)
        let macPro = try XCTUnwrap(MacDeviceModel.preset("mac-pro-m2-ultra"))
        XCTAssertTrue(macPro.displayP3 && macPro.displayHDR)
    }

    /// M4 / M5 世代：MacBook Pro 是 XDR，MacBook Air 是 P3 + SDR，Mac Studio 按 Studio Display（2560×1440 @2x，P3，SDR，初始窗口 1600×960）。
    func testLatestGenerationPresets() throws {
        let expected: [(id: String, name: String, chip: String, cpu: Int, gpu: Int, size: CGSize)] = [
            ("macbook-pro-16-m5-max", "MacBook Pro 16\" (M5 Max)", "Apple M5 Max", 16, 40, CGSize(width: 1728, height: 1117)),
            ("macbook-pro-16-m5-pro", "MacBook Pro 16\" (M5 Pro)", "Apple M5 Pro", 14, 20, CGSize(width: 1728, height: 1117)),
            ("macbook-pro-14-m5-max", "MacBook Pro 14\" (M5 Max)", "Apple M5 Max", 14, 32, CGSize(width: 1512, height: 982)),
            ("macbook-pro-14-m5-pro", "MacBook Pro 14\" (M5 Pro)", "Apple M5 Pro", 12, 16, CGSize(width: 1512, height: 982)),
            ("macbook-pro-14-m5", "MacBook Pro 14\" (M5)", "Apple M5", 10, 10, CGSize(width: 1512, height: 982)),
            ("macbook-air-15-m4", "MacBook Air 15\" (M4)", "Apple M4", 10, 10, CGSize(width: 1710, height: 1107)),
            ("macbook-air-13-m4", "MacBook Air 13\" (M4)", "Apple M4", 10, 10, CGSize(width: 1470, height: 956)),
            ("mac-studio-m3-ultra", "Mac Studio (M3 Ultra · Studio Display)", "Apple M3 Ultra", 28, 60, CGSize(width: 1600, height: 960)),
            ("mac-studio-m4-max", "Mac Studio (M4 Max · Studio Display)", "Apple M4 Max", 16, 40, CGSize(width: 1600, height: 960)),
        ]
        for item in expected {
            let model = try XCTUnwrap(MacDeviceModel.preset(item.id), item.id)
            XCTAssertEqual(model.name, item.name)
            XCTAssertEqual(model.chip, item.chip)
            XCTAssertEqual([model.cpuCores, model.gpuCores], [item.cpu, item.gpu], item.id)
            XCTAssertEqual(model.viewportSize, item.size, item.id)
            XCTAssertEqual(model.scale, 2, item.id)
            XCTAssertTrue(model.displayP3, item.id)
            XCTAssertEqual(model.displayHDR, item.id.hasPrefix("macbook-pro"), item.id)
        }
        // 每组里新机型排在前面。
        XCTAssertEqual(MacDeviceModel.presets.first?.id, "macbook-pro-16-m5-max")
        XCTAssertEqual(MacDeviceModel.presets.first { $0.category == "MacBook Air" }?.id, "macbook-air-15-m4")
        XCTAssertEqual(MacDeviceModel.presets.first { $0.id.hasPrefix("mac-studio") }?.id, "mac-studio-m4-max")
    }

    func testEveryPresetHasAKnownCategory() {
        for model in MacDeviceModel.presets {
            XCTAssertTrue(MacDeviceModel.categories.contains(model.category), "\(model.id): \(model.category)")
        }
        XCTAssertEqual(MacDeviceModel.preset("macbook-air-15-m3")?.viewportSize, CGSize(width: 1710, height: 1107))
        XCTAssertEqual(MacDeviceModel.preset("imac-24-m4")?.viewportSize, CGSize(width: 1600, height: 900))
    }

    /// 旧 JSON 里没有 category 字段也能解码。
    // MARK: - 显示器几何（Issue #1）

    /// 笔记本：显示器就是内建屏，屏幕等于初始视口；刘海屏菜单栏 37（M1 款 Air 没有刘海，25）。
    func testLaptopScreenGeometry() {
        let laptops = MacDeviceModel.presets.filter { $0.id.hasPrefix("macbook") }
        XCTAssertEqual(laptops.count, 23)
        for model in laptops {
            XCTAssertEqual(model.screenSize, model.viewportSize, model.id)
            XCTAssertEqual(model.menuBarHeight, model.id == "macbook-air-13-m1" ? 25 : 37, model.id)
            XCTAssertEqual(model.availWidth, model.screenWidth, model.id)
            XCTAssertEqual(model.availHeight, model.screenHeight - model.menuBarHeight, model.id)
        }
        let mbp16 = MacDeviceModel.macBookPro16M3Max
        XCTAssertEqual([mbp16.screenWidth, mbp16.screenHeight, mbp16.availWidth, mbp16.availHeight], [1728, 1117, 1728, 1080])
        let air = MacDeviceModel.macBookAir13M2
        XCTAssertEqual([air.screenWidth, air.screenHeight, air.availHeight], [1470, 956, 919])
    }

    /// 台式机和 iMac：屏幕是搭配的显示器的「看起来像」分辨率，初始窗口比屏幕小，菜单栏 25。
    func testDesktopScreenGeometry() throws {
        let expected: [(prefix: String, screen: [Int], viewport: [Int])] = [
            ("mac-mini-m4", [1920, 1080], [1440, 820]),
            ("mac-mini-m4-pro", [1920, 1080], [1440, 820]),
            ("mac-mini-m2", [1920, 1080], [1440, 810]),
            ("mac-studio-", [2560, 1440], [1600, 960]),
            ("mac-pro-m2-ultra", [3008, 1692], [1680, 1000]),
            ("imac-24-", [2240, 1260], [1600, 900]),
        ]
        var covered = Set<String>()
        for item in expected {
            let models = MacDeviceModel.presets.filter { item.prefix.hasSuffix("-") ? $0.id.hasPrefix(item.prefix) : $0.id == item.prefix }
            XCTAssertFalse(models.isEmpty, item.prefix)
            for model in models {
                covered.insert(model.id)
                XCTAssertEqual([model.screenWidth, model.screenHeight], item.screen, model.id)
                XCTAssertEqual([model.viewportWidth, model.viewportHeight], item.viewport, model.id)
                XCTAssertEqual(model.menuBarHeight, 25, model.id)
                XCTAssertEqual(model.availHeight, model.screenHeight - 25, model.id)
                // 关闭高级隐私保护时 outer（视口 + 52pt 工具栏）不能比可用区域还大，否则真机上不可能出现。
                XCTAssertLessThanOrEqual(model.viewportWidth, model.availWidth, model.id)
                XCTAssertLessThanOrEqual(model.viewportHeight + 52, model.availHeight, model.id)
            }
        }
        let desktops = MacDeviceModel.presets.filter { $0.category == "台式主机" || $0.category == "iMac 24\"" }
        XCTAssertEqual(Set(desktops.map(\.id)), covered, "每台台式机 / iMac 都有显示器几何")
        XCTAssertEqual(try XCTUnwrap(MacDeviceModel.preset("mac-studio-m4-max")).screenSize, CGSize(width: 2560, height: 1440))
    }

    /// 旧 JSON 没有屏幕几何：屏幕退回视口尺寸，菜单栏 25；新字段能原样读回。
    func testDecodesModelWithoutScreenGeometry() throws {
        let json = #"{"id":"x","name":"X","chip":"Apple M1","cpuCores":8,"gpuCores":8,"viewportWidth":1440,"viewportHeight":900,"scale":2}"#
        let model = try JSONDecoder().decode(MacDeviceModel.self, from: Data(json.utf8))
        XCTAssertEqual([model.screenWidth, model.screenHeight, model.menuBarHeight], [1440, 900, 25])
        XCTAssertEqual(model.availHeight, 875)

        let studio = try XCTUnwrap(MacDeviceModel.preset("mac-studio-m3-ultra"))
        let decoded = try JSONDecoder().decode(MacDeviceModel.self, from: JSONEncoder().encode(studio))
        XCTAssertEqual(decoded, studio)
        XCTAssertEqual([decoded.screenWidth, decoded.screenHeight, decoded.menuBarHeight], [2560, 1440, 25])
        XCTAssertEqual(MacDeviceModel(id: "y", name: "Y", chip: "c", cpuCores: 1, gpuCores: 1, viewportWidth: 10, viewportHeight: 10, scale: 1,
                                      menuBarHeight: 40).availHeight, 0, "不会是负数")
    }

    func testDecodesModelWithoutCategory() throws {
        let json = #"{"id":"x","name":"X","chip":"Apple M1","cpuCores":8,"gpuCores":8,"viewportWidth":1440,"viewportHeight":900,"scale":2}"#
        let model = try JSONDecoder().decode(MacDeviceModel.self, from: Data(json.utf8))
        XCTAssertEqual(model.category, "")
        XCTAssertFalse(model.displayP3)
    }

    func testCodableRoundTrip() throws {
        let data = try JSONEncoder().encode(MacDeviceModel.presets)
        XCTAssertEqual(try JSONDecoder().decode([MacDeviceModel].self, from: data), MacDeviceModel.presets)
    }

    func testViewportKeepsRecommendedSizeWhenItFits() {
        let model = MacDeviceModel.macBookPro14M3Pro
        XCTAssertEqual(model.viewport(fitting: CGSize(width: 2560, height: 1400)), CGSize(width: 1512, height: 982))
    }

    func testViewportScalesDownPreservingAspectRatio() {
        let model = MacDeviceModel.macBookPro16M3Max
        let fitted = model.viewport(fitting: CGSize(width: 1920, height: 960))
        XCTAssertEqual(fitted.height, 960, accuracy: 1)
        XCTAssertLessThanOrEqual(fitted.width, 1920)
        XCTAssertEqual(fitted.width / fitted.height, 1728.0 / 1117.0, accuracy: 0.002)
    }

    func testProfileStoresDeviceAndNodeBindingAndOldJSONStillDecodes() throws {
        let subscriptionID = UUID()
        let profile = Profile(
            name: "p", mode: .persistent, subscriptionID: subscriptionID,
            nodeName: "lan-20001 edge-v6 20001", deviceModel: MacDeviceModel.macBookAir13M2.id
        )
        XCTAssertNoThrow(try profile.validate())
        let data = try JSONDocumentStore<Profile>.encode([profile])
        XCTAssertEqual(try JSONDocumentStore<Profile>.decode(data), [profile])

        let old = """
        {"version":1,"records":[{"id":"\(UUID().uuidString)","name":"old","mode":"ephemeral","createdAt":0}]}
        """
        let decoded = try XCTUnwrap(JSONDocumentStore<Profile>.decode(Data(old.utf8)).first)
        XCTAssertNil(decoded.deviceModel)
        XCTAssertNil(decoded.subscriptionID)
        XCTAssertNil(decoded.nodeName)
    }

    func testProfileValidationOfDeviceAndOutbound() {
        XCTAssertThrowsError(try Profile(name: "p", mode: .ephemeral, deviceModel: "iphone-15").validate()) {
            XCTAssertEqual($0 as? ProfileValidationError, .unknownDeviceModel("iphone-15"))
        }
        XCTAssertThrowsError(try Profile(name: "p", mode: .ephemeral, proxyID: UUID(), subscriptionID: UUID(), nodeName: "n").validate()) {
            XCTAssertEqual($0 as? ProfileValidationError, .conflictingOutbound)
        }
        XCTAssertThrowsError(try Profile(name: "p", mode: .ephemeral, subscriptionID: UUID()).validate()) {
            XCTAssertEqual($0 as? ProfileValidationError, .missingNodeName)
        }
        XCTAssertThrowsError(try Profile(name: "p", mode: .ephemeral, nodeName: "n").validate()) {
            XCTAssertEqual($0 as? ProfileValidationError, .missingNodeName)
        }
    }

    func testWorkspaceResolvesBoundNodeByName() throws {
        let workspace = SafarierWorkspace(root: FileManager.default.temporaryDirectory.appendingPathComponent("ws-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let node = SubscriptionNode(name: "lan-20002 edge-v6 20002", type: .socks, server: "192.0.2.6", serverPort: 20002)
        let subscription = Subscription(name: "lan", url: URL(string: "https://sub.example/s")!, nodes: [node])
        try workspace.subscriptions.insert(subscription)

        XCTAssertNil(try workspace.boundNode(for: Profile(name: "direct", mode: .ephemeral)))
        let bound = try XCTUnwrap(workspace.boundNode(for: Profile(name: "p", mode: .ephemeral, subscriptionID: subscription.id, nodeName: node.name)))
        XCTAssertEqual(bound.node, node)

        XCTAssertThrowsError(try workspace.boundNode(for: Profile(name: "p", mode: .ephemeral, subscriptionID: subscription.id, nodeName: "gone"))) {
            XCTAssertEqual($0 as? WorkspaceError, .nodeNotFound(subscription: "lan", node: "gone"))
        }
        let missing = UUID()
        XCTAssertThrowsError(try workspace.boundNode(for: Profile(name: "p", mode: .ephemeral, subscriptionID: missing, nodeName: "x"))) {
            XCTAssertEqual($0 as? WorkspaceError, .subscriptionNotFound(missing))
        }
    }
}
