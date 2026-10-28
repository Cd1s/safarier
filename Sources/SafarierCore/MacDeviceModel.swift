import Foundation
import CoreGraphics

/// 模拟的 Mac 机型：目标显示器的几何（逻辑分辨率、菜单栏占掉的高度）和浏览窗口的初始视口分开描述。
/// 笔记本的显示器就是内建屏，视口默认等于屏幕；台式机按常见搭配的显示器算，初始窗口比屏幕小。
/// 网页能读到的硬件信息（CPU 核数、WebGL 渲染器）由 WebKit 自己给出，这里不改写。
public struct MacDeviceModel: Codable, Equatable, Identifiable, Sendable {
    /// 存进 `Profile.deviceModel` 的标识。
    public let id: String
    public let name: String
    public let chip: String
    public let cpuCores: Int
    public let gpuCores: Int
    /// 浏览窗口的初始视口（点）。
    public let viewportWidth: Int
    public let viewportHeight: Int
    /// 目标显示器的逻辑分辨率（点，默认缩放下的「看起来像」分辨率）：关闭高级隐私保护时网页的 `screen.width/height`。
    public let screenWidth: Int
    public let screenHeight: Int
    /// 菜单栏高度（点）：刘海屏 MacBook 是 37，其它是 25。`screen.availHeight` 扣掉它（按程序坞隐藏或放在侧边算）。
    public let menuBarHeight: Int
    /// 屏幕像素与点的比例：Retina 为 2。
    public let scale: Int
    /// 内建屏能显示 P3 色域（网页 `color-gamut: p3`）。
    public let displayP3: Bool
    /// 内建屏是 HDR（XDR）屏（网页 `dynamic-range: high`）。
    public let displayHDR: Bool
    /// XDR 屏的 EDR 余量：最大可能值和当前值（当前值随亮度变化，取常见亮度下的值）。只在 `displayHDR` 时用。
    public let maxEDRHeadroom: Double
    public let currentEDRHeadroom: Double
    /// 界面分组（MacBook Pro 16"、MacBook Air、iMac、台式主机……），只用于展示。
    public let category: String

    public init(
        id: String, name: String, chip: String, cpuCores: Int, gpuCores: Int,
        viewportWidth: Int, viewportHeight: Int, scale: Int,
        displayP3: Bool = false, displayHDR: Bool = false, maxEDRHeadroom: Double = 1, currentEDRHeadroom: Double = 1,
        category: String = "",
        screenWidth: Int? = nil, screenHeight: Int? = nil, menuBarHeight: Int = 25
    ) {
        self.id = id
        self.name = name
        self.chip = chip
        self.cpuCores = cpuCores
        self.gpuCores = gpuCores
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
        self.screenWidth = screenWidth ?? viewportWidth
        self.screenHeight = screenHeight ?? viewportHeight
        self.menuBarHeight = menuBarHeight
        self.scale = scale
        self.displayP3 = displayP3
        self.displayHDR = displayHDR
        self.maxEDRHeadroom = maxEDRHeadroom
        self.currentEDRHeadroom = currentEDRHeadroom
        self.category = category
    }

    /// 旧版 JSON（没有 category、屏幕几何）也能解码：屏幕退回视口尺寸，菜单栏 25。
    private enum CodingKeys: String, CodingKey {
        case id, name, chip, cpuCores, gpuCores, viewportWidth, viewportHeight, scale
        case displayP3, displayHDR, maxEDRHeadroom, currentEDRHeadroom, category
        case screenWidth, screenHeight, menuBarHeight
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id), name: try c.decode(String.self, forKey: .name),
            chip: try c.decode(String.self, forKey: .chip), cpuCores: try c.decode(Int.self, forKey: .cpuCores),
            gpuCores: try c.decode(Int.self, forKey: .gpuCores), viewportWidth: try c.decode(Int.self, forKey: .viewportWidth),
            viewportHeight: try c.decode(Int.self, forKey: .viewportHeight), scale: try c.decode(Int.self, forKey: .scale),
            displayP3: try c.decodeIfPresent(Bool.self, forKey: .displayP3) ?? false,
            displayHDR: try c.decodeIfPresent(Bool.self, forKey: .displayHDR) ?? false,
            maxEDRHeadroom: try c.decodeIfPresent(Double.self, forKey: .maxEDRHeadroom) ?? 1,
            currentEDRHeadroom: try c.decodeIfPresent(Double.self, forKey: .currentEDRHeadroom) ?? 1,
            category: try c.decodeIfPresent(String.self, forKey: .category) ?? "",
            screenWidth: try c.decodeIfPresent(Int.self, forKey: .screenWidth),
            screenHeight: try c.decodeIfPresent(Int.self, forKey: .screenHeight),
            menuBarHeight: try c.decodeIfPresent(Int.self, forKey: .menuBarHeight) ?? 25
        )
    }

    // MARK: - 机型库
    //
    // 屏幕取各显示器默认缩放下的「看起来像」分辨率（点），scale 是像素比。MacBook Pro 是 XDR（P3 + HDR）；
    // MacBook Air、iMac 是 P3 + SDR。笔记本的初始视口等于内建屏；刘海屏（MacBook Pro 14"/16"、M2 起的 MacBook Air）菜单栏 37。
    // 台式主机按常见搭配的显示器算，初始窗口比屏幕小：Studio Display 5K（2560×1440，P3，SDR）、
    // 4K 显示器（1920×1080 @2x；Retina 款 P3，SDR 款 sRGB）、Pro Display XDR 6K（3008×1692，P3 + HDR）、iMac 24" 4.5K（2240×1260）。

    static let mbp16 = "MacBook Pro 16\"", mbp14 = "MacBook Pro 14\"", air = "MacBook Air", imac = "iMac 24\"", desktop = "台式主机"

    private static func pro16(_ id: String, _ chip: String, _ cpu: Int, _ gpu: Int) -> MacDeviceModel {
        MacDeviceModel(id: id, name: "MacBook Pro 16\" (\(chip))", chip: "Apple \(chip)", cpuCores: cpu, gpuCores: gpu,
                       viewportWidth: 1728, viewportHeight: 1117, scale: 2, displayP3: true, displayHDR: true,
                       maxEDRHeadroom: 16, currentEDRHeadroom: 2, category: mbp16, menuBarHeight: 37)
    }
    private static func pro14(_ id: String, _ chip: String, _ cpu: Int, _ gpu: Int) -> MacDeviceModel {
        MacDeviceModel(id: id, name: "MacBook Pro 14\" (\(chip))", chip: "Apple \(chip)", cpuCores: cpu, gpuCores: gpu,
                       viewportWidth: 1512, viewportHeight: 982, scale: 2, displayP3: true, displayHDR: true,
                       maxEDRHeadroom: 16, currentEDRHeadroom: 2, category: mbp14, menuBarHeight: 37)
    }
    /// M1 款 MacBook Air 没有刘海，菜单栏 25；M2 起是刘海屏，菜单栏 37。
    private static func macBookAir(_ id: String, _ size: String, _ chip: String, _ cpu: Int, _ gpu: Int, _ width: Int, _ height: Int, notch: Bool = true) -> MacDeviceModel {
        MacDeviceModel(id: id, name: "MacBook Air \(size)\" (\(chip))", chip: "Apple \(chip)", cpuCores: cpu, gpuCores: gpu,
                       viewportWidth: width, viewportHeight: height, scale: 2, displayP3: true, category: air,
                       menuBarHeight: notch ? 37 : 25)
    }
    /// iMac 24" 4.5K Retina：屏幕 2240×1260，初始窗口 1600×900。
    private static func iMac(_ id: String, _ chip: String, _ cpu: Int, _ gpu: Int) -> MacDeviceModel {
        MacDeviceModel(id: id, name: "iMac 24\" (\(chip))", chip: "Apple \(chip)", cpuCores: cpu, gpuCores: gpu,
                       viewportWidth: 1600, viewportHeight: 900, scale: 2, displayP3: true, category: imac,
                       screenWidth: 2240, screenHeight: 1260)
    }

    public static let macBookPro16M3Max = pro16("macbook-pro-16-m3-max", "M3 Max", 16, 40)
    public static let macBookPro14M3Pro = pro14("macbook-pro-14-m3-pro", "M3 Pro", 12, 18)
    /// Mac Studio 搭配 Studio Display（5K Retina：屏幕 2560×1440，P3，SDR），初始窗口 1600×960。
    private static func studio(_ id: String, _ chip: String, _ cpu: Int, _ gpu: Int) -> MacDeviceModel {
        MacDeviceModel(id: id, name: "Mac Studio (\(chip) · Studio Display)", chip: "Apple \(chip)", cpuCores: cpu, gpuCores: gpu,
                       viewportWidth: 1600, viewportHeight: 960, scale: 2, displayP3: true, category: desktop,
                       screenWidth: 2560, screenHeight: 1440)
    }

    public static let macStudioM2Ultra = studio("mac-studio-m2-ultra", "M2 Ultra", 24, 76)
    public static let macBookAir13M2 = macBookAir("macbook-air-13-m2", "13", "M2", 8, 10, 1470, 956)

    /// 不含"跟随系统"：那是 `Profile.deviceModel == nil`。按界面分组排好序，每组里新机型在前。
    public static let presets: [MacDeviceModel] = [
        pro16("macbook-pro-16-m5-max", "M5 Max", 16, 40),
        pro16("macbook-pro-16-m5-pro", "M5 Pro", 14, 20),
        pro16("macbook-pro-16-m4-max", "M4 Max", 16, 40),
        pro16("macbook-pro-16-m4-pro", "M4 Pro", 14, 20),
        macBookPro16M3Max,
        pro16("macbook-pro-16-m2-max", "M2 Max", 12, 38),
        pro16("macbook-pro-16-m1-pro", "M1 Pro", 10, 16),
        pro14("macbook-pro-14-m5-max", "M5 Max", 14, 32),
        pro14("macbook-pro-14-m5-pro", "M5 Pro", 12, 16),
        pro14("macbook-pro-14-m5", "M5", 10, 10),
        pro14("macbook-pro-14-m4-max", "M4 Max", 14, 32),
        pro14("macbook-pro-14-m4-pro", "M4 Pro", 12, 16),
        pro14("macbook-pro-14-m4", "M4", 10, 10),
        macBookPro14M3Pro,
        pro14("macbook-pro-14-m2-pro", "M2 Pro", 10, 16),
        pro14("macbook-pro-14-m1-pro", "M1 Pro", 8, 14),
        macBookAir("macbook-air-15-m4", "15", "M4", 10, 10, 1710, 1107),
        macBookAir("macbook-air-15-m3", "15", "M3", 8, 10, 1710, 1107),
        macBookAir("macbook-air-15-m2", "15", "M2", 8, 10, 1710, 1107),
        macBookAir("macbook-air-13-m4", "13", "M4", 10, 10, 1470, 956),
        macBookAir("macbook-air-13-m3", "13", "M3", 8, 10, 1470, 956),
        macBookAir13M2,
        macBookAir("macbook-air-13-m1", "13", "M1", 8, 7, 1440, 900, notch: false),
        iMac("imac-24-m4", "M4", 10, 10),
        iMac("imac-24-m3", "M3", 8, 10),
        iMac("imac-24-m1", "M1", 8, 8),
        studio("mac-studio-m4-max", "M4 Max", 16, 40),
        studio("mac-studio-m3-ultra", "M3 Ultra", 28, 60),
        macStudioM2Ultra,
        studio("mac-studio-m2-max", "M2 Max", 12, 30),
        MacDeviceModel(id: "mac-mini-m4-pro", name: "Mac mini (M4 Pro · 4K Retina)", chip: "Apple M4 Pro",
                       cpuCores: 12, gpuCores: 16, viewportWidth: 1440, viewportHeight: 820, scale: 2, displayP3: true, category: desktop,
                       screenWidth: 1920, screenHeight: 1080),
        MacDeviceModel(id: "mac-mini-m4", name: "Mac mini (M4 · 4K Retina)", chip: "Apple M4",
                       cpuCores: 10, gpuCores: 10, viewportWidth: 1440, viewportHeight: 820, scale: 2, displayP3: true, category: desktop,
                       screenWidth: 1920, screenHeight: 1080),
        MacDeviceModel(id: "mac-mini-m2", name: "Mac mini (M2 · 4K SDR)", chip: "Apple M2",
                       cpuCores: 8, gpuCores: 10, viewportWidth: 1440, viewportHeight: 810, scale: 2, category: desktop,
                       screenWidth: 1920, screenHeight: 1080),
        MacDeviceModel(id: "mac-pro-m2-ultra", name: "Mac Pro (M2 Ultra · Pro Display XDR)", chip: "Apple M2 Ultra",
                       cpuCores: 24, gpuCores: 76, viewportWidth: 1680, viewportHeight: 1000, scale: 2, displayP3: true, displayHDR: true,
                       maxEDRHeadroom: 16, currentEDRHeadroom: 2, category: desktop,
                       screenWidth: 3008, screenHeight: 1692),
    ]

    /// 界面分组的顺序。
    public static let categories: [String] = [mbp16, mbp14, air, imac, desktop]

    public static func preset(_ id: String) -> MacDeviceModel? {
        presets.first { $0.id == id }
    }

    /// 网页读到的 navigator.hardwareConcurrency：WebKit 只会给 4 或 8（核数少于 8 报 4，否则 8），
    /// 见 WebKit Source/WebCore/page/NavigatorBase.cpp。所以这几款机型在真 Safari 里都是 8。
    public static func webVisibleCPUCores(hostCores: Int = ProcessInfo.processInfo.processorCount) -> Int {
        hostCores < 8 ? 4 : 8
    }

    /// WebGL 的 UNMASKED_RENDERER_WEBGL：WebKit 写死为 "Apple GPU"（WebGLRenderingContextBase.cpp），所有 Mac 都一样。
    public static let webVisibleGPU = "Apple GPU"

    public var viewportSize: CGSize { CGSize(width: viewportWidth, height: viewportHeight) }
    public var screenSize: CGSize { CGSize(width: screenWidth, height: screenHeight) }
    /// 网页的 `screen.availWidth`：程序坞隐藏或放在侧边时等于屏幕宽度。
    public var availWidth: Int { screenWidth }
    /// 网页的 `screen.availHeight`：屏幕高度减去菜单栏。
    public var availHeight: Int { max(0, screenHeight - menuBarHeight) }
    public var pixelWidth: Int { viewportWidth * scale }
    public var pixelHeight: Int { viewportHeight * scale }

    /// 在 `available`（屏幕可用区域减去窗口自己的工具栏）里放得下的最大视口：
    /// 放得下就用推荐尺寸，放不下就按原纵横比等比缩小。
    public func viewport(fitting available: CGSize) -> CGSize {
        let ratio = min(1, available.width / viewportSize.width, available.height / viewportSize.height)
        guard ratio > 0 else { return viewportSize }
        return CGSize(width: (viewportSize.width * ratio).rounded(.down), height: (viewportSize.height * ratio).rounded(.down))
    }
}
