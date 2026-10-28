import Foundation
import WebKit
import SafarierCore

/// Runtime status for one imported extension. Parsing and copying are handled by SafarierWorkspace;
/// this type only owns the WebKit controller and contexts for a browser session.
public enum WebExtensionLoadState: Equatable, Sendable {
    case pending
    case loaded
    case failed(String)
}

@MainActor
public protocol WebExtensionRuntimeProtocol: AnyObject {
    var states: [UUID: WebExtensionLoadState] { get }
    func waitUntilSettled() async
    func load(_ record: SafarierExtensionRecord) async
}

@MainActor
@available(macOS 15.4, *)
public final class WebExtensionRuntime: WebExtensionRuntimeProtocol {
    public let controller: WKWebExtensionController
    public private(set) var states: [UUID: WebExtensionLoadState] = [:]

    private let workspace: SafarierWorkspace
    private let profileID: UUID
    private var contexts: [UUID: WKWebExtensionContext] = [:]
    private var loadTask: Task<Void, Never>?

    init(controller: WKWebExtensionController, workspace: SafarierWorkspace, profileID: UUID, records: [SafarierExtensionRecord]) {
        self.controller = controller
        self.workspace = workspace
        self.profileID = profileID
        for record in records { states[record.id] = .pending }
    }

    public func start() {
        guard loadTask == nil else { return }
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let records = (try? self.workspace.enabledExtensions(for: self.profileID)) ?? []
            for record in records { await self.load(record) }
        }
    }

    public func waitUntilSettled() async {
        await loadTask?.value
    }

    /// Loads a newly imported record into an already-created session.
    public func load(_ record: SafarierExtensionRecord) async {
        states[record.id] = .pending
        do {
            let baseURL = workspace.extensionsDirectory.appendingPathComponent(record.id.uuidString, isDirectory: true)
            let extensionObject = try await WKWebExtension(resourceBaseURL: baseURL)
            let context = WKWebExtensionContext(for: extensionObject)
            context.isInspectable = false
            try controller.load(context)
            contexts[record.id] = context
            states[record.id] = .loaded
        } catch {
            states[record.id] = .failed(Self.describe(error))
        }
    }

    public func unload(_ record: SafarierExtensionRecord) {
        guard let context = contexts.removeValue(forKey: record.id) else { return }
        do {
            try controller.unload(context)
            states[record.id] = .pending
        } catch {
            states[record.id] = .failed(Self.describe(error))
        }
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "error \(nsError.domain) code \(nsError.code)"
    }
}

public enum WebExtensionSupport {
    /// Attaches one controller before the first WKWebView is created and starts loading enabled contexts.
    /// The asynchronous parse/load is retained by the returned runtime, which the browser session owns.
    @MainActor
    public static func attach(
        profile: Profile,
        workspace: SafarierWorkspace,
        to configuration: WKWebViewConfiguration
    ) -> (runtime: (any WebExtensionRuntimeProtocol)?, state: CapabilityState) {
        guard #available(macOS 15.4, *) else {
            return (nil, .unavailable("WebExtension engine requires macOS 15.4 or newer"))
        }
        let records: [SafarierExtensionRecord]
        do {
            records = try workspace.enabledExtensions(for: profile.id)
        } catch {
            return (nil, .degraded("Extension metadata could not be read"))
        }
        let controller = WKWebExtensionController()
        configuration.webExtensionController = controller
        let runtime = WebExtensionRuntime(controller: controller, workspace: workspace, profileID: profile.id, records: records)
        runtime.start()
        let state: CapabilityState = records.isEmpty
            ? .notRequested
            : .active("(records.count) extension context(s) scheduled for native loading")
        return (runtime, state)
    }

    public static var isRuntimeAvailable: Bool {
        if #available(macOS 15.4, *) { return true }
        return false
    }
}
