#import "SafarierObjCSupport.h"
#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

#if !__has_feature(objc_arc)
#error "SFRRuntime.m 的引用计数写法依赖 ARC（-fobjc-arc）"
#endif

// 原生引擎桥接层的字节解码；逐字节 volatile 读取，避免优化器折叠为明文常量。
__attribute__((noinline))
static void SFRDecodeBytes(const volatile uint8_t *bytes, size_t count, char *output) {
    for (size_t i = 0; i < count; i++) output[i] = (char)(bytes[i] ^ 0x5A);
    output[count] = '\0';
}

NSString *SFRDecodeEngineSymbol(const uint8_t *bytes, size_t count) {
    if (!bytes || count == 0 || count == SIZE_MAX) return @"";
    char stackBuffer[128];
    char *decoded = count < sizeof(stackBuffer) ? stackBuffer : malloc(count + 1);
    if (!decoded) return @"";
    SFRDecodeBytes(bytes, count, decoded);
    NSString *result = [[NSString alloc] initWithBytes:decoded length:count encoding:NSUTF8StringEncoding] ?: @"";
    if (decoded != stackBuffer) free(decoded);
    return result;
}

static void *SFRLookupEngineSymbol(const uint8_t *bytes, size_t count) {
    char decoded[128];
    if (count >= sizeof(decoded)) return NULL;
    SFRDecodeBytes(bytes, count, decoded);
    return dlsym(RTLD_DEFAULT, decoded);
}

// 原生引擎桥接：动态查找、运行时签名核验、失败返回状态。
// Swift 侧拿到的只有结果码和说明文字，NSException 不会穿过 Swift 栈帧。

static void SFRSetDetail(NSString * _Nullable * _Nullable detail, NSString *text) {
    if (detail) {
        *detail = text;
    }
}

/// 去掉 r/n/N/o/O/R/V/A 这类类型限定符。
static const char *SFRStripQualifiers(const char *type) {
    while (*type && strchr("rnNoORVA", *type)) {
        type++;
    }
    return type;
}

static BOOL SFRTypeIs(const char *actual, const char *expected) {
    actual = SFRStripQualifiers(actual);
    if (expected[0] == '@' && expected[1] == '\0') {
        // 对象：允许 @"ClassName"，不允许 block（@?）。
        return actual[0] == '@' && actual[1] != '?';
    }
    return strcmp(actual, expected) == 0;
}

/// returnType/argumentType 为 NULL 表示不检查；argumentType 非 NULL 时要求恰好一个参数。
static SFRCallStatus SFRCheckSignature(NSMethodSignature * _Nullable signature, const char * _Nullable returnType, const char * _Nullable argumentType, NSString * _Nullable * _Nullable detail) {
    if (!signature) {
        SFRSetDetail(detail, @"engineMethod 没有方法签名");
        return SFRCallStatusSignatureMismatch;
    }
    NSUInteger expectedArguments = argumentType ? 3 : 2;
    if (signature.numberOfArguments != expectedArguments) {
        SFRSetDetail(detail, [NSString stringWithFormat:@"engineMethod 有 %lu 个参数，预期 %lu 个", (unsigned long)signature.numberOfArguments - 2, (unsigned long)expectedArguments - 2]);
        return SFRCallStatusSignatureMismatch;
    }
    if (returnType && !SFRTypeIs(signature.methodReturnType, returnType)) {
        SFRSetDetail(detail, [NSString stringWithFormat:@"engineMethod 返回类型是 %s，预期 %s", signature.methodReturnType, returnType]);
        return SFRCallStatusSignatureMismatch;
    }
    if (argumentType && !SFRTypeIs([signature getArgumentTypeAtIndex:2], argumentType)) {
        SFRSetDetail(detail, [NSString stringWithFormat:@"engineMethod 参数类型是 %s，预期 %s", [signature getArgumentTypeAtIndex:2], argumentType]);
        return SFRCallStatusSignatureMismatch;
    }
    return SFRCallStatusOK;
}

static SFRCallStatus SFRPrepare(id target, NSString *selectorName, const char * _Nullable returnType, const char * _Nullable argumentType, SEL *selector, NSString * _Nullable * _Nullable detail) {
    SEL sel = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:sel]) {
        SFRSetDetail(detail, @"engineMethod 不可用");
        return SFRCallStatusMissingSelector;
    }
    SFRCallStatus status = SFRCheckSignature([target methodSignatureForSelector:sel], returnType, argumentType, detail);
    if (status == SFRCallStatusOK) {
        *selector = sel;
    }
    return status;
}

static SFRCallStatus SFRException(NSException *exception, NSString * _Nullable * _Nullable detail) {
    SFRSetDetail(detail, [NSString stringWithFormat:@"engineMethod 抛出 %@", exception.name]);
    return SFRCallStatusException;
}

SFRCallStatus SFRSetUnsignedInteger(id target, NSString *selectorName, NSUInteger value, NSString **detail) {
    SEL sel = NULL;
    SFRCallStatus status = SFRPrepare(target, selectorName, @encode(void), @encode(NSUInteger), &sel, detail);
    if (status != SFRCallStatusOK) return status;
    @try {
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(target, sel, value);
    } @catch (NSException *exception) {
        return SFRException(exception, detail);
    }
    return SFRCallStatusOK;
}

SFRCallStatus SFRGetUnsignedInteger(id target, NSString *selectorName, NSUInteger *value, NSString **detail) {
    SEL sel = NULL;
    SFRCallStatus status = SFRPrepare(target, selectorName, @encode(NSUInteger), NULL, &sel, detail);
    if (status != SFRCallStatusOK) return status;
    @try {
        *value = ((NSUInteger (*)(id, SEL))objc_msgSend)(target, sel);
    } @catch (NSException *exception) {
        return SFRException(exception, detail);
    }
    return SFRCallStatusOK;
}

SFRCallStatus SFRSetBool(id target, NSString *selectorName, BOOL value, NSString **detail) {
    SEL sel = NULL;
    SFRCallStatus status = SFRPrepare(target, selectorName, @encode(void), @encode(BOOL), &sel, detail);
    if (status != SFRCallStatusOK) return status;
    @try {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(target, sel, value);
    } @catch (NSException *exception) {
        return SFRException(exception, detail);
    }
    return SFRCallStatusOK;
}

SFRCallStatus SFRSetDouble(id target, NSString *selectorName, double value, NSString **detail) {
    SEL sel = NULL;
    SFRCallStatus status = SFRPrepare(target, selectorName, @encode(void), @encode(double), &sel, detail);
    if (status != SFRCallStatusOK) return status;
    @try {
        ((void (*)(id, SEL, double))objc_msgSend)(target, sel, value);
    } @catch (NSException *exception) {
        return SFRException(exception, detail);
    }
    return SFRCallStatusOK;
}

SFRCallStatus SFRGetDouble(id target, NSString *selectorName, double *value, NSString **detail) {
    SEL sel = NULL;
    SFRCallStatus status = SFRPrepare(target, selectorName, @encode(double), NULL, &sel, detail);
    if (status != SFRCallStatusOK) return status;
    @try {
        *value = ((double (*)(id, SEL))objc_msgSend)(target, sel);
    } @catch (NSException *exception) {
        return SFRException(exception, detail);
    }
    return SFRCallStatusOK;
}

SFRCallStatus SFRGetBool(id target, NSString *selectorName, BOOL *value, NSString **detail) {
    SEL sel = NULL;
    SFRCallStatus status = SFRPrepare(target, selectorName, @encode(BOOL), NULL, &sel, detail);
    if (status != SFRCallStatusOK) return status;
    @try {
        *value = ((BOOL (*)(id, SEL))objc_msgSend)(target, sel);
    } @catch (NSException *exception) {
        return SFRException(exception, detail);
    }
    return SFRCallStatusOK;
}

/// 两个参数（BOOL, id）的签名检查：NSMethodSignature 参数下标 2、3。
static SFRCallStatus SFRPrepareTwo(id target, NSString *selectorName, const char *returnType, const char *firstType, const char *secondType, SEL *selector, NSString **detail) {
    SEL sel = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:sel]) {
        SFRSetDetail(detail, @"engineMethod 不可用");
        return SFRCallStatusMissingSelector;
    }
    NSMethodSignature *signature = [target methodSignatureForSelector:sel];
    if (!signature || signature.numberOfArguments != 4 || !SFRTypeIs(signature.methodReturnType, returnType)
        || !SFRTypeIs([signature getArgumentTypeAtIndex:2], firstType) || !SFRTypeIs([signature getArgumentTypeAtIndex:3], secondType)) {
        SFRSetDetail(detail, [NSString stringWithFormat:@"engineMethod 的签名不是预期的 %s(%s, %s)", returnType, firstType, secondType]);
        return SFRCallStatusSignatureMismatch;
    }
    *selector = sel;
    return SFRCallStatusOK;
}

SFRCallStatus SFRSetBoolWithObject(id target, NSString *selectorName, BOOL value, id argument, NSString **detail) {
    SEL sel = NULL;
    SFRCallStatus status = SFRPrepareTwo(target, selectorName, @encode(void), @encode(BOOL), "@", &sel, detail);
    if (status != SFRCallStatusOK) return status;
    @try {
        ((void (*)(id, SEL, BOOL, id))objc_msgSend)(target, sel, value, argument);
    } @catch (NSException *exception) {
        return SFRException(exception, detail);
    }
    return SFRCallStatusOK;
}

SFRCallStatus SFRGetBoolWithObject(id target, NSString *selectorName, id argument, BOOL *value, NSString **detail) {
    SEL sel = NULL;
    SFRCallStatus status = SFRPrepare(target, selectorName, @encode(BOOL), "@", &sel, detail);
    if (status != SFRCallStatusOK) return status;
    @try {
        *value = ((BOOL (*)(id, SEL, id))objc_msgSend)(target, sel, argument);
    } @catch (NSException *exception) {
        return SFRException(exception, detail);
    }
    return SFRCallStatusOK;
}

SFRCallStatus SFRSetObject(id target, NSString *selectorName, id value, NSString **detail) {
    SEL sel = NULL;
    SFRCallStatus status = SFRPrepare(target, selectorName, @encode(void), "@", &sel, detail);
    if (status != SFRCallStatusOK) return status;
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(target, sel, value);
    } @catch (NSException *exception) {
        return SFRException(exception, detail);
    }
    return SFRCallStatusOK;
}

SFRCallStatus SFRGetObject(id target, NSString *selectorName, id __autoreleasing *value, NSString **detail) {
    SEL sel = NULL;
    SFRCallStatus status = SFRPrepare(target, selectorName, "@", NULL, &sel, detail);
    if (status != SFRCallStatusOK) return status;
    @try {
        // 普通 getter 返回 +0 对象；按 +0 接收，ARC 会自行 retain。
        *value = ((id (*)(id, SEL))objc_msgSend)(target, sel);
    } @catch (NSException *exception) {
        return SFRException(exception, detail);
    }
    return SFRCallStatusOK;
}

SFRCallStatus SFRCallVoid(id target, NSString *selectorName, NSString **detail) {
    SEL sel = NULL;
    SFRCallStatus status = SFRPrepare(target, selectorName, @encode(void), NULL, &sel, detail);
    if (status != SFRCallStatusOK) return status;
    @try {
        ((void (*)(id, SEL))objc_msgSend)(target, sel);
    } @catch (NSException *exception) {
        return SFRException(exception, detail);
    }
    return SFRCallStatusOK;
}

SFRCallStatus SFRCallWithDataCompletion(id target, NSString *selectorName, void (^completion)(NSData *, NSError *), NSString **detail) {
    SEL sel = NULL;
    SFRCallStatus status = SFRPrepare(target, selectorName, @encode(void), "@?", &sel, detail);
    if (status != SFRCallStatusOK) return status;
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(target, sel, [completion copy]);
    } @catch (NSException *exception) {
        return SFRException(exception, detail);
    }
    return SFRCallStatusOK;
}

SFRCallStatus SFRNewInstance(NSString *className, id __autoreleasing *instance, NSString **detail) {
    Class cls = NSClassFromString(className);
    if (!cls) {
        SFRSetDetail(detail, @"engineClass 不可用");
        return SFRCallStatusMissingClass;
    }
    @try {
        id object = [[cls alloc] init];
        if (!object) {
            SFRSetDetail(detail, @"engineClass 初始化返回 nil");
            return SFRCallStatusException;
        }
        *instance = object;
    } @catch (NSException *exception) {
        return SFRException(exception, detail);
    }
    return SFRCallStatusOK;
}

// init 家族：消耗 self、返回 +1。用带 ARC 属性的函数指针调用，引用计数才对得上。
typedef id __attribute__((ns_returns_retained)) (*SFRInitWithObjectFunction)(id __attribute__((ns_consumed)), SEL, id);

SFRCallStatus SFRAllocInitWithObject(NSString *className, NSString *initializerName, id argument, id __autoreleasing *instance, NSString **detail) {
    Class cls = NSClassFromString(className);
    if (!cls) {
        SFRSetDetail(detail, @"engineClass 不可用");
        return SFRCallStatusMissingClass;
    }
    SEL sel = NSSelectorFromString(initializerName);
    if (![cls instancesRespondToSelector:sel]) {
        SFRSetDetail(detail, @"engineClass 初始化方法不可用");
        return SFRCallStatusMissingSelector;
    }
    SFRCallStatus status = SFRCheckSignature([cls instanceMethodSignatureForSelector:sel], "@", "@", detail);
    if (status != SFRCallStatusOK) return status;
    @try {
        id allocated = [cls alloc];
        id object = ((SFRInitWithObjectFunction)objc_msgSend)(allocated, sel, argument);
        if (!object) {
            SFRSetDetail(detail, @"engineClass 初始化返回 nil");
            return SFRCallStatusException;
        }
        *instance = object;
    } @catch (NSException *exception) {
        return SFRException(exception, detail);
    }
    return SFRCallStatusOK;
}

// MARK: - 显示器能力模拟

typedef struct {
    Method method;
    IMP original;
} SFRSwizzle;

static SFRSwizzle sCanRepresentGamut, sMaxPotentialEDR, sMaxEDR, sPreferredVideoRange;
static BOOL sOverrideP3, sOverrideHDR;
static double sMaxHeadroom, sCurrentHeadroom;

/// 方法存在且返回 / 参数类型对得上才替换（类型编码里的偏移量不比较）。
static SFRCallStatus SFRSwizzleMethod(Class cls, SEL sel, const char *returnType, const char *argumentType, id block, SFRSwizzle *slot, NSString **detail) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) {
        SFRSetDetail(detail, @"displayQuery 不可用");
        return SFRCallStatusMissingSelector;
    }
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    NSUInteger expected = argumentType ? 3 : 2;
    if (signature.numberOfArguments != expected || !SFRTypeIs(signature.methodReturnType, returnType)
        || (argumentType && !SFRTypeIs([signature getArgumentTypeAtIndex:2], argumentType))) {
        SFRSetDetail(detail, [NSString stringWithFormat:@"displayQuery 的类型编码是 %s，和预期不符", method_getTypeEncoding(method)]);
        return SFRCallStatusSignatureMismatch;
    }
    slot->method = method;
    slot->original = method_setImplementation(method, imp_implementationWithBlock(block));
    return SFRCallStatusOK;
}

static void SFRRestore(SFRSwizzle *slot) {
    if (slot->method && slot->original) {
        IMP replaced = method_setImplementation(slot->method, slot->original);
        imp_removeBlock(replaced);
    }
    slot->method = NULL;
    slot->original = NULL;
}

void SFRRemoveDisplayOverride(void) {
    SFRRestore(&sCanRepresentGamut);
    SFRRestore(&sMaxPotentialEDR);
    SFRRestore(&sMaxEDR);
    SFRRestore(&sPreferredVideoRange);
    sOverrideP3 = NO;
    sOverrideHDR = NO;
}

SFRCallStatus SFRInstallDisplayOverride(BOOL p3, BOOL hdr, double maxHeadroom, double currentHeadroom, NSString **detail) {
    SFRRemoveDisplayOverride();
    sOverrideP3 = p3;
    sOverrideHDR = hdr;
    sMaxHeadroom = maxHeadroom;
    sCurrentHeadroom = currentHeadroom;
    SFRCallStatus status = SFRCallStatusOK;

    // 四个查询始终替换：机型是 P3 / HDR 就报 P3 / HDR，不是就报 sRGB / SDR。
    // 这样在 XDR 宿主机上选 MacBook Air 之类的非 HDR 机型，网页也不会读到 dynamic-range: high。
    SEL sel = @selector(canRepresentDisplayGamut:);
    status = SFRSwizzleMethod([NSScreen class], sel, @encode(BOOL), @encode(NSInteger), ^BOOL(id screen, NSInteger gamut) {
        if (gamut == NSDisplayGamutP3) return sOverrideP3;
        return ((BOOL (*)(id, SEL, NSInteger))sCanRepresentGamut.original)(screen, sel, gamut);
    }, &sCanRepresentGamut, detail);
    if (status != SFRCallStatusOK) { SFRRemoveDisplayOverride(); return status; }

    SEL potential = @selector(maximumPotentialExtendedDynamicRangeColorComponentValue);
    status = SFRSwizzleMethod([NSScreen class], potential, @encode(CGFloat), NULL, ^CGFloat(id screen) {
        // 直接报机型的余量，不混入宿主机屏幕的值（宿主机是 XDR 屏时会报得比模拟的机型还高）。
        return sOverrideHDR ? (CGFloat)sMaxHeadroom : 1.0;
    }, &sMaxPotentialEDR, detail);
    if (status != SFRCallStatusOK) { SFRRemoveDisplayOverride(); return status; }

    SEL current = @selector(maximumExtendedDynamicRangeColorComponentValue);
    status = SFRSwizzleMethod([NSScreen class], current, @encode(CGFloat), NULL, ^CGFloat(id screen) {
        return sOverrideHDR ? (CGFloat)sCurrentHeadroom : 1.0;
    }, &sMaxEDR, detail);
    if (status != SFRCallStatusOK) { SFRRemoveDisplayOverride(); return status; }

    // WebKit 通过 soft-link 延迟加载 AVFoundation；先加载同一个镜像，替换才对它生效。
    dlopen("/System/Library/Frameworks/AVFoundation.framework/AVFoundation", RTLD_LAZY);
    Class player = NSClassFromString(@"AVPlayer");
    if (!player) {
        SFRSetDetail(detail, @"找不到 AVPlayer（AVFoundation 没有加载）");
        SFRRemoveDisplayOverride();
        return SFRCallStatusMissingClass;
    }
    static const uint8_t hdrRange[] = { 0x1B, 0x0C, 0x0C, 0x33, 0x3E, 0x3F, 0x35, 0x08, 0x3B, 0x34, 0x3D, 0x3F, 0x12, 0x1E, 0x08, 0x6B, 0x6A };
    static const uint8_t sdrRange[] = { 0x1B, 0x0C, 0x0C, 0x33, 0x3E, 0x3F, 0x35, 0x08, 0x3B, 0x34, 0x3D, 0x3F, 0x09, 0x1E, 0x08 };
    static const uint8_t rangeQuery[] = { 0x2A, 0x28, 0x3F, 0x3C, 0x3F, 0x28, 0x28, 0x3F, 0x3E, 0x0C, 0x33, 0x3E, 0x3F, 0x35, 0x08, 0x3B, 0x34, 0x3D, 0x3F, 0x1C, 0x35, 0x28, 0x1E, 0x33, 0x29, 0x2A, 0x36, 0x3B, 0x23, 0x29, 0x60 };
    NSString * const *hdr10Symbol = (NSString * const *)SFRLookupEngineSymbol(hdrRange, sizeof(hdrRange));
    NSString *hdr10 = hdr10Symbol ? *hdr10Symbol : SFRDecodeEngineSymbol(hdrRange, sizeof(hdrRange));
    NSString * const *sdrSymbol = (NSString * const *)SFRLookupEngineSymbol(sdrRange, sizeof(sdrRange));
    NSString *sdr = sdrSymbol ? *sdrSymbol : SFRDecodeEngineSymbol(sdrRange, sizeof(sdrRange));
    SEL range = NSSelectorFromString(SFRDecodeEngineSymbol(rangeQuery, sizeof(rangeQuery)));
    status = SFRSwizzleMethod(object_getClass(player), range, "@", "@", ^NSString *(id cls, NSArray *displays) {
        return sOverrideHDR ? hdr10 : sdr;
    }, &sPreferredVideoRange, detail);
    if (status != SFRCallStatusOK) { SFRRemoveDisplayOverride(); return status; }
    return SFRCallStatusOK;
}

// MARK: - 字体白名单（fontAllowlist）

// 原生引擎桥接：动态查找、运行时签名核验、失败返回状态。
typedef void (*SFRFontListFunction)(const void *, const void *);
typedef uint32_t (*SFRPoolTypeIDFunction)(void);
typedef uint32_t (*SFRObjectTypeIDFunction)(const void *);
typedef const void *(*SFRArrayCreateFunction)(const void * _Nullable * _Nullable, size_t);
typedef const void *(*SFRStringCreateFunction)(const char *);
typedef void (*SFRReleaseFunction)(const void *);

SFRCallStatus SFRSetFontAllowList(id pool, NSArray<NSString *> *names, NSString **detail) {
    if (names.count == 0) {
        SFRSetDetail(detail, @"empty");
        return SFRCallStatusOK;
    }

    // 1. C 导出：任何一个缺失都不调用。
    static const uint8_t fontListExport[] = { 0x0D, 0x11, 0x19, 0x35, 0x34, 0x2E, 0x3F, 0x22, 0x2E, 0x09, 0x3F, 0x2E, 0x1C, 0x35, 0x34, 0x2E, 0x1B, 0x36, 0x36, 0x35, 0x2D, 0x16, 0x33, 0x29, 0x2E };
    static const uint8_t poolTypeExport[] = { 0x0D, 0x11, 0x19, 0x35, 0x34, 0x2E, 0x3F, 0x22, 0x2E, 0x1D, 0x3F, 0x2E, 0x0E, 0x23, 0x2A, 0x3F, 0x13, 0x1E };
    static const uint8_t objectTypeExport[] = { 0x0D, 0x11, 0x1D, 0x3F, 0x2E, 0x0E, 0x23, 0x2A, 0x3F, 0x13, 0x1E };
    static const uint8_t arrayExport[] = { 0x0D, 0x11, 0x1B, 0x28, 0x28, 0x3B, 0x23, 0x19, 0x28, 0x3F, 0x3B, 0x2E, 0x3F };
    static const uint8_t stringExport[] = { 0x0D, 0x11, 0x09, 0x2E, 0x28, 0x33, 0x34, 0x3D, 0x19, 0x28, 0x3F, 0x3B, 0x2E, 0x3F, 0x0D, 0x33, 0x2E, 0x32, 0x0F, 0x0E, 0x1C, 0x62, 0x19, 0x09, 0x2E, 0x28, 0x33, 0x34, 0x3D };
    static const uint8_t releaseExport[] = { 0x0D, 0x11, 0x08, 0x3F, 0x36, 0x3F, 0x3B, 0x29, 0x3F };
    const struct { const uint8_t *bytes; size_t count; } exports[] = {
        { fontListExport, sizeof(fontListExport) },
        { poolTypeExport, sizeof(poolTypeExport) },
        { objectTypeExport, sizeof(objectTypeExport) },
        { arrayExport, sizeof(arrayExport) },
        { stringExport, sizeof(stringExport) },
        { releaseExport, sizeof(releaseExport) },
    };
    void *symbols[6] = { NULL };
    for (size_t i = 0; i < 6; i++) {
        symbols[i] = SFRLookupEngineSymbol(exports[i].bytes, exports[i].count);
        if (!symbols[i]) {
            SFRSetDetail(detail, [NSString stringWithFormat:@"fontAllowlist 缺少引擎导出 #%zu", i]);
            return SFRCallStatusMissingSymbol;
        }
    }
    SFRFontListFunction setFontAllowList = (SFRFontListFunction)symbols[0];
    SFRPoolTypeIDFunction contextGetTypeID = (SFRPoolTypeIDFunction)symbols[1];
    SFRObjectTypeIDFunction getTypeID = (SFRObjectTypeIDFunction)symbols[2];
    SFRArrayCreateFunction arrayCreate = (SFRArrayCreateFunction)symbols[3];
    SFRStringCreateFunction stringCreate = (SFRStringCreateFunction)symbols[4];
    SFRReleaseFunction release = (SFRReleaseFunction)symbols[5];

    @try {
        // 2. 核对进程池对象的类，失败时不向对象发送消息。
        static const uint8_t poolType[] = { 0x0D, 0x11, 0x0A, 0x28, 0x35, 0x39, 0x3F, 0x29, 0x29, 0x0A, 0x35, 0x35, 0x36 };
        Class poolClass = NSClassFromString(SFRDecodeEngineSymbol(poolType, sizeof(poolType)));
        if (!pool || !poolClass || ![pool isKindOfClass:poolClass]) {
            SFRSetDetail(detail, !poolClass ? @"processPool 类不可用" : @"processPool 对象类型不符");
            return SFRCallStatusMissingClass;
        }
        // 3. 核对包装对象是否提供引擎访问能力。
        static const uint8_t objectQuery[] = { 0x05, 0x3B, 0x2A, 0x33, 0x15, 0x38, 0x30, 0x3F, 0x39, 0x2E };
        if (![pool respondsToSelector:NSSelectorFromString(SFRDecodeEngineSymbol(objectQuery, sizeof(objectQuery)))]) {
            SFRSetDetail(detail, @"processPool 对象访问能力不可用");
            return SFRCallStatusMissingSelector;
        }
        const void *context = (__bridge const void *)pool;
        // 4. 引擎类型标识必须匹配。
        if (getTypeID(context) != contextGetTypeID()) {
            SFRSetDetail(detail, @"processPool 引擎类型不符");
            return SFRCallStatusSignatureMismatch;
        }

        // 5. 转换每个字体名称；任意一步失败都释放已有引用。
        NSUInteger count = names.count;
        const void **values = calloc(count, sizeof(const void *));
        if (!values) {
            SFRSetDetail(detail, @"fontAllowlist 名称数组分配失败");
            return SFRCallStatusException;
        }
        for (NSUInteger i = 0; i < count; i++) {
            const char *utf8 = names[i].UTF8String;
            values[i] = utf8 ? stringCreate(utf8) : NULL;
            if (!values[i]) {
                for (NSUInteger j = 0; j < i; j++) release(values[j]);
                free(values);
                SFRSetDetail(detail, [NSString stringWithFormat:@"fontAllowlist 名称转换失败：%@", names[i]]);
                return SFRCallStatusException;
            }
        }

        // 6. 引擎复制允许集合，之后释放临时数组和字符串。
        const void *array = arrayCreate(values, count);
        if (!array) {
            for (NSUInteger i = 0; i < count; i++) release(values[i]);
            free(values);
            SFRSetDetail(detail, @"fontAllowlist 引擎数组创建失败");
            return SFRCallStatusException;
        }
        setFontAllowList(context, array);
        release(array);
        for (NSUInteger i = 0; i < count; i++) release(values[i]);
        free(values);
        SFRSetDetail(detail, [NSString stringWithFormat:@"已设置 %lu 个名字", (unsigned long)count]);
    } @catch (NSException *exception) {
        return SFRException(exception, detail);
    }
    return SFRCallStatusOK;
}
