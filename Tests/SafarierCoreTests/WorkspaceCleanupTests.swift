import XCTest
@testable import SafarierCore

/// 删除环境之后清掉它留下的 Runner 日志、锁文件和 sing-box 配置（含节点凭据），别的环境的文件不碰。
final class WorkspaceCleanupTests: XCTestCase {
    func testRemoveRunnerArtifactsOnlyTouchesThatProfile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ws-clean-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = SafarierWorkspace(root: root)
        let target = UUID(), other = UUID()
        func files(_ id: UUID) -> [URL] {
            [
                workspace.runnerLogURL(for: id),
                workspace.locksDirectory.appendingPathComponent("\(id.uuidString).lock"),
                workspace.singboxDirectory.appendingPathComponent("\(id.uuidString).json"),
                workspace.singboxDirectory.appendingPathComponent("\(id.uuidString).pid"),
            ]
        }
        for url in files(target) + files(other) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        workspace.removeRunnerArtifacts(for: target)
        for url in files(target) { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), url.lastPathComponent) }
        for url in files(other) { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "别的环境的 \(url.lastPathComponent) 不能删") }
        workspace.removeRunnerArtifacts(for: UUID())  // 文件不存在时不报错
    }
}
