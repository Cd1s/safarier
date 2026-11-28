import Foundation

/// 图形管理器单实例锁：同一个工作目录同时只允许一个图形管理器进程运行，避免双开互相覆盖配置文件。
/// 与 `ProfileLock` 一样用 `flock` 实现，进程退出（含崩溃）时由内核自动释放。
public final class ManagerLock {
    public static let fileName = "manager.lock"

    public let fileURL: URL
    private var descriptor: Int32

    private init(fileURL: URL, descriptor: Int32) {
        self.fileURL = fileURL
        self.descriptor = descriptor
    }

    deinit {
        release()
    }

    public static func lockURL(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName)
    }

    /// 已被其它图形管理器进程持有时抛 `ManagerLockError.alreadyRunning`。
    public static func acquire(in directory: URL) throws -> ManagerLock {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = lockURL(in: directory)
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ManagerLockError.cannotOpen(url.path, errno) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK {
                throw ManagerLockError.alreadyRunning(pid: readPID(at: url))
            }
            throw ManagerLockError.cannotLock(url.path, code)
        }
        let pid = "\(getpid())\n"
        _ = ftruncate(fd, 0)
        _ = pid.withCString { write(fd, $0, strlen($0)) }
        return ManagerLock(fileURL: url, descriptor: fd)
    }

    /// 只检查不加锁，供浏览器进程或测试判断图形管理器是否在运行。
    public static func isHeld(in directory: URL) -> Bool {
        let url = lockURL(in: directory)
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }

    /// 持有者写进锁文件的 pid；没被持有（或持有者还没写完）时返回 nil。
    public static func holderPID(in directory: URL) -> Int32? {
        guard isHeld(in: directory) else { return nil }
        return readPID(at: lockURL(in: directory))
    }

    public func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    private static func readPID(at url: URL) -> Int32? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

public enum ManagerLockError: Error, Equatable {
    case alreadyRunning(pid: Int32?)
    case cannotOpen(String, Int32)
    case cannotLock(String, Int32)
}

/// 跨进程唤醒管理窗口的本机通知标识。
/// 通知 `object` 绑定规范化的工作目录路径，使 `SAFARIER_HOME` 隔离环境与单元测试不会误唤醒正式管理器。
public enum ManagerWakeup: Sendable {
    public static let notificationName = Notification.Name("sh.safarier.manager.reopen")

    public static func workspaceScope(for root: URL) -> String {
        root.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
