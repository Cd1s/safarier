import SafarierObjCSupport

/// 原生引擎桥接层的运行时符号解码。实际字节读取位于独立的 C 函数中，避免发布优化折叠常量。
public enum SFRSymbolDecoder {
    @inline(never)
    public static func decode(_ bytes: [UInt8]) -> String {
        bytes.withUnsafeBufferPointer { buffer in
            SFRDecodeEngineSymbol(buffer.baseAddress, buffer.count)
        }
    }
}
