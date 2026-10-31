#import <Foundation/Foundation.h>
#include <stdint.h>
#include <stddef.h>

NS_ASSUME_NONNULL_BEGIN

/// 原生引擎桥接层的运行时字节解码；空输入或无效 UTF-8 返回空字符串。
FOUNDATION_EXPORT NSString *SFRDecodeEngineSymbol(const uint8_t * _Nullable bytes, size_t count);

/// 动态调用原生引擎接口的结果。所有函数都不会因为接口不存在、签名不符或抛出 NSException 而崩溃。
typedef NS_ENUM(NSInteger, SFRCallStatus) {
    SFRCallStatusOK = 0,
    /// NSClassFromString 找不到类。
    SFRCallStatusMissingClass = 1,
    /// 对象（或类的实例）不响应这个 selector。
    SFRCallStatusMissingSelector = 2,
    /// selector 存在，但参数或返回值的类型编码和预期不同；没有调用。
    SFRCallStatusSignatureMismatch = 3,
    /// 调用时抛出了 NSException，或初始化器返回 nil。
    SFRCallStatusException = 4,
    /// 需要的 C 导出不存在。
    SFRCallStatusMissingSymbol = 5,
};

/// `-(void)<selector>(NSUInteger)`
FOUNDATION_EXPORT SFRCallStatus SFRSetUnsignedInteger(id target, NSString *selectorName, NSUInteger value, NSString * _Nullable * _Nullable detail);
/// `-(NSUInteger)<selector>`
FOUNDATION_EXPORT SFRCallStatus SFRGetUnsignedInteger(id target, NSString *selectorName, NSUInteger *value, NSString * _Nullable * _Nullable detail);
/// `-(void)<selector>(BOOL)`
FOUNDATION_EXPORT SFRCallStatus SFRSetBool(id target, NSString *selectorName, BOOL value, NSString * _Nullable * _Nullable detail);
/// `-(BOOL)<selector>`
FOUNDATION_EXPORT SFRCallStatus SFRGetBool(id target, NSString *selectorName, BOOL *value, NSString * _Nullable * _Nullable detail);
/// `-(void)<selector>(double)`（CGFloat）
FOUNDATION_EXPORT SFRCallStatus SFRSetDouble(id target, NSString *selectorName, double value, NSString * _Nullable * _Nullable detail);
/// `-(double)<selector>`
FOUNDATION_EXPORT SFRCallStatus SFRGetDouble(id target, NSString *selectorName, double *value, NSString * _Nullable * _Nullable detail);
/// `-(void)<selector>(BOOL, id)`
FOUNDATION_EXPORT SFRCallStatus SFRSetBoolWithObject(id target, NSString *selectorName, BOOL value, id argument, NSString * _Nullable * _Nullable detail);
/// `-(BOOL)<selector>(id)`
FOUNDATION_EXPORT SFRCallStatus SFRGetBoolWithObject(id target, NSString *selectorName, id argument, BOOL *value, NSString * _Nullable * _Nullable detail);
/// `-(void)<selector>(id)`
FOUNDATION_EXPORT SFRCallStatus SFRSetObject(id target, NSString *selectorName, id _Nullable value, NSString * _Nullable * _Nullable detail);
/// `-(id)<selector>`
FOUNDATION_EXPORT SFRCallStatus SFRGetObject(id target, NSString *selectorName, id _Nullable __autoreleasing * _Nonnull value, NSString * _Nullable * _Nullable detail);
/// `[[NSClassFromString(className) alloc] init]`
FOUNDATION_EXPORT SFRCallStatus SFRNewInstance(NSString *className, id _Nullable __autoreleasing * _Nonnull instance, NSString * _Nullable * _Nullable detail);
/// `[[NSClassFromString(className) alloc] <initializer>argument]`；initializer 必须是 init 家族、返回对象、只有一个对象参数。
FOUNDATION_EXPORT SFRCallStatus SFRAllocInitWithObject(NSString *className, NSString *initializerName, id argument, id _Nullable __autoreleasing * _Nonnull instance, NSString * _Nullable * _Nullable detail);
/// `[[NSClassFromString(className) alloc] <initializer>]`；initializer 必须是 init 家族、返回对象、没有参数。
FOUNDATION_EXPORT SFRCallStatus SFRAllocInitWithoutArguments(NSString *className, NSString *initializerName, id _Nullable __autoreleasing * _Nonnull instance, NSString * _Nullable * _Nullable detail);

/// 模拟显示器能力（进程级）：替换 `-[NSScreen canRepresentDisplayGamut:]`（P3）、NSScreen 的两个 EDR 余量属性，
/// 以及视频动态范围查询。引擎的 UI 进程收集屏幕能力时调用这些方法，
/// 再把结果发给 WebContent / GPU 进程，所以必须在第一个 WKWebView 创建之前安装。
/// 四个查询始终替换：p3 为 NO 时 P3 查询报不支持，hdr 为 NO 时 EDR 余量报 1.0、视频范围报 SDR，宿主机屏幕再好也不漏出来。
/// `maxHeadroom`/`currentHeadroom` 只在 `hdr` 为 YES 时生效，直接作为两个 EDR 余量返回（不混入宿主机屏幕的值）。重复调用会先撤销上一次。
///
/// `screenWidth` / `screenHeight` 都大于 0 时，同时替换 `-[NSScreen frame]`（返回 `0, 0, screenWidth, screenHeight`）
/// 和 `-[NSScreen visibleFrame]`（返回 `0, 0, screenWidth, availHeight`；`availHeight` 不大于 0 时用 `screenHeight`）：
/// WebKit 收集 ScreenProperties 时读这两个方法，关闭高级隐私保护时网页的 `screen` / `avail*` 就是目标机型的显示器。
/// 只有 WebKit（以及测试等不在系统框架里的调用方）看到模拟的几何；AppKit 等系统框架和主程序自己的窗口布局
/// 仍然拿到宿主机的真实屏幕，窗口居中、缩放、全屏、菜单定位不受影响。
FOUNDATION_EXPORT SFRCallStatus SFRInstallDisplayOverride(BOOL p3, BOOL hdr, double maxHeadroom, double currentHeadroom, double screenWidth, double screenHeight, double availHeight, NSString * _Nullable * _Nullable detail);
/// 撤销 `SFRInstallDisplayOverride`，恢复原来的实现（包括 `frame` / `visibleFrame`）。
FOUNDATION_EXPORT void SFRRemoveDisplayOverride(void);
/// 宿主机主屏幕真实的可用区域（不受显示器模拟影响），给窗口布局用。
FOUNDATION_EXPORT NSRect SFRHostVisibleFrame(void);

/// 通过原生引擎桥接设置字体允许集合，网页只能按名字使用集合内的字体。
/// 先确认引擎导出、对象类、访问能力和类型标识全部匹配，
/// 全部通过才调用。`names` 为空时什么都不做，返回 OK（detail 为 @"empty"）。只影响之后新建的 WebContent 进程。
FOUNDATION_EXPORT SFRCallStatus SFRSetFontAllowList(id _Nullable pool, NSArray<NSString *> *names, NSString * _Nullable * _Nullable detail);

/// `-(void)<selector>`（无参数）。
FOUNDATION_EXPORT SFRCallStatus SFRCallVoid(id target, NSString *selectorName, NSString * _Nullable * _Nullable detail);

/// `-(void)<selector>(void (^)(NSData *, NSError *))`。
/// 只检查参数是 block（类型编码 `@?`）；回调在 WebKit 给的线程上执行（WKWebView 的回调在主线程）。
FOUNDATION_EXPORT SFRCallStatus SFRCallWithDataCompletion(id target, NSString *selectorName, void (^completion)(NSData * _Nullable data, NSError * _Nullable error), NSString * _Nullable * _Nullable detail);

NS_ASSUME_NONNULL_END
