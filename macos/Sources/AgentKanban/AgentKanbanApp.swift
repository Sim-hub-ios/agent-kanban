import AppKit
import SwiftUI

@main struct AgentKanbanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = AppStore()
    var body: some Scene {
        WindowGroup("Agent Kanban") {
            RootContentView(store: store)
                .frame(minWidth: 760, minHeight: 580)
                .task {
                    delegate.store = store
                    HangDiagnostics.shared.start(directory: store.dataDirectory.appendingPathComponent("Diagnostics", isDirectory: true))
                    await store.boot()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建项目会话") { store.createConversation() }.keyboardShortcut("n")
                Button("导入本地项目…") { Self.pickProject(store) }.keyboardShortcut("o")
            }
            CommandGroup(after: .appInfo) {
                Button("打开本地数据目录") { NSWorkspace.shared.open(store.dataDirectory) }
                if HangDiagnostics.shared.isEnabled {
                    Button("打开诊断日志") { NSWorkspace.shared.open(store.dataDirectory.appendingPathComponent("Diagnostics", isDirectory: true)) }
                }
            }
        }
    }
    @MainActor private static func pickProject(_ store: AppStore) {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.prompt = "导入项目"; panel.message = "选择已有本地 Git 项目。不会复制或修改代码。"
        if panel.runModal() == .OK, let url = panel.url { store.importProject(directory: url, name: url.lastPathComponent, executor: .codex) }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: AppStore?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        // Only the QA launch script supplies this override. Normal launches follow the system.
        if let appearance = ProcessInfo.processInfo.environment["AGENT_KANBAN_APPEARANCE"] {
            NSApplication.shared.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        if store.snapshot.runs.contains(where: { !$0.status.isTerminal && $0.status != .queued }) {
            let alert = NSAlert(); alert.messageText = "停止运行并退出？"; alert.informativeText = "执行器与工具全部停止后退出，排队请求保留到下次启动。无法确认停止的运行会保持阻塞，避免项目目录同时写入。"
            alert.addButton(withTitle: "停止并退出"); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        Task { sender.reply(toApplicationShouldTerminate: await store.stopAllForTermination()) }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { HangDiagnostics.shared.stop() }
}
