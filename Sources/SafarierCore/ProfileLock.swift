import Foundation

/// 同一个 profile 同时只允许一个 Runner 进程：两个进程打开同一个持久 DataStore 会互相踩数据。
/// 用 `flock` 实现，进程退出（包括崩溃）时内核自动释放。
public final class ProfileLock {
    public let fileURL: URL
    private var descriptor: Int32

    private init(fileURL: URL, descriptor: Int32) {
        self.fileURL = fileURL
        self.descriptor = descriptor
    }

    deinit {
        release()
    }

    /// 已被其它进程持有时抛 `ProfileLockError.alreadyRunning`。
    public static func acquire(profileID: UUID, in directory: URL) throws -> ProfileLock {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(profileID.uuidString).lock")
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ProfileLockError.cannotOpen(url.path, errno) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK { throw ProfileLockError.alreadyRunning(profileID) }
            throw ProfileLockError.cannotLock(url.path, code)
        }
        let pid = "\(getpid())\n"
        _ = ftruncate(fd, 0)
        _ = pid.withCString { write(fd, $0, strlen($0)) }
        return ProfileLock(fileURL: url, descriptor: fd)
    }

    /// 只检查不加锁，供 Manager 显示运行状态、拒绝删除正在运行的 profile。
    public static func isHeld(profileID: UUID, in directory: URL) -> Bool {
        let url = directory.appendingPathComponent("\(profileID.uuidString).lock")
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
    public static func holderPID(profileID: UUID, in directory: URL) -> Int32? {
        guard isHeld(profileID: profileID, in: directory) else { return nil }
        let url = directory.appendingPathComponent("\(profileID.uuidString).lock")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }
}

public enum ProfileLockError: Error, Equatable {
    case alreadyRunning(UUID)
    case cannotOpen(String, Int32)
    case cannotLock(String, Int32)
}
