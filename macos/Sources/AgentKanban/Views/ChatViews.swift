import AppKit
import SwiftUI
import UniformTypeIdentifiers
import AgentKanbanCore
import AgentKanbanExecutors

struct ProjectChatView: View {
    @Bindable var store: AppStore
    private var project: Project? { store.snapshot.projects.first { $0.id == store.selectedProjectID } }
    private var conversation: Conversation? { store.snapshot.conversations.first { $0.id == store.selectedConversationID } }
    private var queuedRun: RunRecord? {
        store.snapshot.runs.first { $0.conversationID == conversation?.id && $0.status == .queued }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                DesignIcon(name: "imgIconFolder", size: 18, color: KanbanTheme.blue)
                Text(project?.name ?? "项目").font(.system(size: 13)).foregroundStyle(KanbanTheme.muted)
                Text("/").foregroundStyle(KanbanTheme.muted)
                Text(conversation?.title ?? "项目会话").font(.system(size: 16, weight: .semibold)).lineLimit(1)
                Spacer()
                StatusChip(text: "项目会话")
            }.padding(.horizontal, 16).frame(height: 54).background(KanbanTheme.panel.opacity(0.64))
                .padding(.horizontal, 28).padding(.top, 28)
            Divider().overlay(KanbanTheme.line).padding(.horizontal, 28).padding(.top, 16)
            if let conversation {
                if let queuedRun {
                    QueuedRunBanner(store: store, run: queuedRun)
                        .frame(maxWidth: 844).frame(maxWidth: .infinity).padding(.horizontal, 28).padding(.top, 16)
                }
                ConversationStream(store: store, conversationID: conversation.id)
                    .frame(maxWidth: 844).frame(maxWidth: .infinity)
                ComposerView(store: store, conversationID: conversation.id, placeholder: "继续讨论，或提供下一份任务清单…")
                    .frame(maxWidth: 844).frame(maxWidth: .infinity).padding(.horizontal, 28)
                Text("任务只在你明确要求创建或导入时进入看板。")
                    .font(.system(size: 11)).foregroundStyle(KanbanTheme.muted)
                    .frame(maxWidth: 844, alignment: .leading).frame(maxWidth: .infinity).padding(.horizontal, 28).padding(.top, 10).padding(.bottom, 20)
            } else {
                ContentUnavailableView { Label("开始项目会话", systemImage: "bubble.left.and.bubble.right") } description: {
                    Text("在左侧项目下新建会话，讨论代码或提供任务清单。")
                } actions: { Button("新建会话") { store.createConversation() }.buttonStyle(KanbanPrimaryButtonStyle()) }
            }
        }.background(KanbanTheme.background)
    }
}

struct QueuedRunBanner: View {
    @Bindable var store: AppStore
    let run: RunRecord

    var body: some View {
        HStack(spacing: 10) {
            DesignIcon(name: "imgIconClock", size: 16, color: KanbanTheme.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("排队中，目录可用后自动开始").font(.system(size: 12, weight: .medium))
                Text(abbreviatedPath(run.cwd)).font(.system(size: 11)).foregroundStyle(KanbanTheme.muted)
                    .lineLimit(1).truncationMode(.middle).help(run.cwd)
            }
            Spacer(minLength: 8)
            Button("取消排队") { store.stopRun(run.id) }
                .buttonStyle(.glass).controlSize(.small)
                .help("取消此排队任务，执行器尚未启动。")
        }.padding(12).background(KanbanTheme.orangeSoft, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ConversationStream: View {
    @Bindable var store: AppStore
    let conversationID: String
    private var messages: [Message] { store.snapshot.messages.filter { $0.conversationID == conversationID }.sorted { $0.createdAt < $1.createdAt } }
    private var run: RunRecord? { store.snapshot.runs.filter { $0.conversationID == conversationID && !$0.status.isTerminal }.max { $0.createdAt < $1.createdAt } }

    var body: some View {
        ScrollViewReader { reader in
            instrumentedScrollView {
                ScrollView {
                    if ScrollDiagnostics.variant == .eagerStack {
                        VStack(alignment: .leading, spacing: 24) { streamContent }
                            .padding(.horizontal, 2).padding(.vertical, 24)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 24) { streamContent }
                            .padding(.horizontal, 2).padding(.vertical, 24)
                    }
                }.scrollIndicators(.hidden)
            }
            .onChange(of: messages.count) { _, _ in scrollToBottom(reader, reason: "message-count") }
            .onChange(of: run?.output.count) { _, _ in scrollToBottom(reader, reason: "run-output") }
            .onChange(of: conversationID) { _, _ in scrollToBottom(reader, reason: "conversation") }
        }
    }

    @ViewBuilder private var streamContent: some View {
        if messages.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("从这里开始").font(.system(size: 20, weight: .semibold))
                Text("讨论项目、让执行器处理代码，或在会话中提供 Excel 和 Issue 链接导入任务。")
                    .font(.system(size: 13)).foregroundStyle(KanbanTheme.muted).lineSpacing(5)
            }.padding(.vertical, 36)
        }
        ForEach(messages) { message in
            MessageBubble(message: message, executor: executor(for: message), allowsTextSelection: ScrollDiagnostics.allowsTextSelection)
        }
        ForEach(store.snapshot.importBatches.filter { $0.conversationID == conversationID }.suffix(3)) { batch in
            ImportResultCard(store: store, batch: batch)
        }
        ForEach(store.snapshot.runs.filter { $0.conversationID == conversationID }.sorted { $0.createdAt < $1.createdAt }) { item in
            let agents = AgentActivity.latest(events: store.snapshot.events, runID: item.id)
            if !agents.isEmpty { AgentActivityCard(run: item, agents: agents, allowsTextSelection: ScrollDiagnostics.allowsTextSelection) }
        }
        if let run {
            if !run.output.isEmpty && !messages.contains(where: { $0.runID == run.id && $0.role == .assistant }) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) { ExecutorIcon(executor: run.selection.executor); Text(run.selection.executor.title).font(.system(size: 13, weight: .medium)); ProgressView().controlSize(.mini) }
                    MarkdownContent(text: run.output, allowsTextSelection: ScrollDiagnostics.allowsTextSelection)
                }
            }
            ForEach(store.snapshot.approvals.filter { $0.runID == run.id && $0.status == .pending }) { approval in
                ApprovalCard(store: store, approval: approval)
            }
            if run.status == .recoveryRequired { RecoveryCard(store: store, run: run) }
        }
        Color.clear.frame(height: 1).id("stream-bottom")
    }

    private var diagnosticContext: ScrollDiagnostics.Context {
        .init(conversationID: conversationID, messageCount: messages.count,
              runCount: store.snapshot.runs.filter { $0.conversationID == conversationID }.count)
    }

    @ViewBuilder private func instrumentedScrollView<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if HangDiagnostics.shared.isEnabled {
            let context = diagnosticContext
            content()
                .onScrollGeometryChange(for: ScrollDiagnostics.Geometry.self, of: { ScrollDiagnostics.Geometry($0) }) { _, geometry in
                    ScrollDiagnostics.record(event: "chat-scroll", context: context, geometry: geometry, throttled: true)
                }
                .onAppear { ScrollDiagnostics.record(event: "chat-stream-appear", context: context) }
                .onDisappear { ScrollDiagnostics.record(event: "chat-stream-disappear", context: context) }
        } else {
            content()
        }
    }

    private func scrollToBottom(_ reader: ScrollViewProxy, reason: String) {
        guard ScrollDiagnostics.allowsAutoscroll else { return }
        if HangDiagnostics.shared.isEnabled {
            ScrollDiagnostics.record(event: "chat-autoscroll", context: diagnosticContext, reason: reason, throttled: true)
        }
        reader.scrollTo("stream-bottom", anchor: .bottom)
    }

    private func executor(for message: Message) -> ExecutorID {
        store.snapshot.runs.first { $0.id == message.runID }?.selection.executor
            ?? store.snapshot.conversations.first { $0.id == conversationID }?.selection.executor ?? .codex
    }
}

struct AgentActivity: Identifiable {
    let id: String
    var status: String
    var summary: String
    var updatedAt: Date
    var isTerminal: Bool {
        ["completed", "succeeded", "failed", "errored", "interrupted", "shutdown", "notfound", "stopped", "cancelled"].contains(status.lowercased())
    }
    var title: String {
        switch status.lowercased() {
        case "completed", "succeeded": "已完成"
        case "failed", "errored": "失败"
        case "interrupted": "已中断"
        case "shutdown", "stopped", "cancelled": "已停止"
        case "notfound": "未找到"
        case "started", "running", "pendinginit", "resumed": "运行中"
        default: status
        }
    }
    var color: Color { isTerminal ? (["completed", "succeeded"].contains(status.lowercased()) ? KanbanTheme.green : KanbanTheme.orange) : KanbanTheme.blue }
    static func latest(events: [RunEvent], runID: String) -> [AgentActivity] {
        var latest: [String: AgentActivity] = [:]
        for event in events.filter({ $0.runID == runID && $0.kind.hasPrefix("agent.") }).sorted(by: { $0.createdAt < $1.createdAt }) {
            let parts = event.content.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            guard let first = parts.first, !first.isEmpty else { continue }
            let id = String(first)
            let summary = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
            latest[id] = AgentActivity(id: id, status: String(event.kind.dropFirst(6)), summary: summary.isEmpty ? latest[id]?.summary ?? "" : summary, updatedAt: event.createdAt)
        }
        return latest.values.sorted { $0.updatedAt < $1.updatedAt }
    }
}

private struct AgentActivityCard: View {
    let run: RunRecord
    let agents: [AgentActivity]
    var allowsTextSelection = true
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ExecutorIcon(executor: run.selection.executor, size: 16)
                Text("子 Agent").font(.system(size: 12, weight: .medium))
                Text("\(agents.filter(\.isTerminal).count) / \(agents.count) 已结束").font(.system(size: 11)).foregroundStyle(KanbanTheme.muted)
                Spacer()
                Text(String(run.id.prefix(8))).font(.system(size: 10, design: .monospaced)).foregroundStyle(KanbanTheme.muted)
            }
            ForEach(agents) { agent in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        Circle().fill(agent.color).frame(width: 6, height: 6)
                        Text(String(agent.id.prefix(12))).font(.system(size: 11, design: .monospaced)).foregroundStyle(KanbanTheme.muted)
                        Text(agent.title).font(.system(size: 11, weight: .medium)).foregroundStyle(agent.color)
                    }
                    if !agent.summary.isEmpty { Text(agent.summary).font(.system(size: 12)).lineSpacing(4).lineLimit(4).modifier(MessageTextSelection(enabled: allowsTextSelection)) }
                }
            }
        }.padding(14).contentPanel(radius: 12)
    }
}

private struct MessageBubble: View {
    let message: Message
    let executor: ExecutorID
    var allowsTextSelection = true
    private var isImportReceipt: Bool {
        message.role == .assistant && message.runID == nil
            && (message.id.hasPrefix("import-result-") || message.id.hasPrefix("import-error-"))
    }
    private var author: String {
        if isImportReceipt { return "任务导入 Skill" }
        return message.role == .user ? "你" : message.role == .system ? "工作区" : executor.title
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if message.role == .user {
                    Text("S").font(.system(size: 12, weight: .medium)).foregroundStyle(KanbanTheme.purple)
                        .frame(width: 26, height: 26).background(KanbanTheme.purpleSoft, in: RoundedRectangle(cornerRadius: 6))
                } else if isImportReceipt {
                    DesignIcon(name: "imgIconFile", size: 22, color: KanbanTheme.purple)
                } else { ExecutorIcon(executor: executor, size: 22) }
                Text(author).font(.system(size: 13, weight: .medium))
                Text(message.createdAt, style: .time).font(.system(size: 11)).foregroundStyle(KanbanTheme.muted)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 10) {
                MarkdownContent(text: message.content, allowsTextSelection: allowsTextSelection)
                if !message.attachments.isEmpty {
                    AttachmentPreviewList(urls: message.attachments.map { URL(fileURLWithPath: $0.path) }).frame(height: 64)
                }
            }.padding(message.role == .user ? 16 : 0).frame(maxWidth: .infinity, alignment: .leading)
                .background(message.role == .user ? KanbanTheme.panel : .clear, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

struct MarkdownContent: View {
    let text: String
    var allowsTextSelection = true
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(text.components(separatedBy: "```").enumerated()), id: \.offset) { index, part in
                if index % 2 == 1 {
                    ScrollView(.horizontal) {
                        Text(part.trimmingCharacters(in: .newlines)).font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(KanbanTheme.ink).modifier(MessageTextSelection(enabled: allowsTextSelection)).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    }.background(KanbanTheme.hover, in: RoundedRectangle(cornerRadius: 10))
                } else if !part.isEmpty {
                    Text(.init(part)).font(.system(size: 13)).lineSpacing(5).modifier(MessageTextSelection(enabled: allowsTextSelection)).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private struct MessageTextSelection: ViewModifier {
    let enabled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.textSelection(.enabled) }
        else { content.textSelection(.disabled) }
    }
}

private struct ImportResultCard: View {
    @Bindable var store: AppStore
    let batch: ImportBatch
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                DesignIcon(name: "imgIconCheckCircle", size: 18, color: KanbanTheme.green)
                Text("任务已导入当前项目看板").font(.system(size: 14, weight: .medium))
                Spacer()
                StatusChip(text: "Skill · task-import", color: KanbanTheme.purple, background: KanbanTheme.purpleSoft)
            }
            HStack(spacing: 24) {
                Text("新增 \(batch.createdTaskIDs.count) 项").foregroundStyle(KanbanTheme.green)
                Text("跳过重复 \(batch.duplicateCount) 项").foregroundStyle(KanbanTheme.muted)
                if !batch.errors.isEmpty { Text("待补充 \(batch.errors.count) 项").foregroundStyle(KanbanTheme.orange) }
            }.font(.system(size: 12))
            Divider().overlay(KanbanTheme.line)
            ForEach(store.snapshot.tasks.filter { batch.createdTaskIDs.contains($0.id) }) { task in
                HStack(spacing: 10) {
                    Text(task.displayID).font(.system(size: 11)).foregroundStyle(KanbanTheme.muted)
                    Button(task.title) { store.selectTask(task.id) }.buttonStyle(.plain).foregroundStyle(KanbanTheme.blue).font(.system(size: 13)).lineLimit(2)
                    Spacer(minLength: 0)
                    if let provenance = store.snapshot.provenance.first(where: { $0.batchID == batch.id && $0.taskID == task.id }) {
                        if let value = provenance.sourceURL, let url = URL(string: value) {
                            Link(provenance.sourceDescription, destination: url).font(.system(size: 11))
                        } else { Text(provenance.sourceDescription).font(.system(size: 11)).foregroundStyle(KanbanTheme.muted) }
                    }
                }
            }
            ForEach(batch.errors, id: \.self) { error in Text(error).font(.system(size: 12)).foregroundStyle(KanbanTheme.orange) }
        }.padding(18).contentPanel(radius: 12)
    }
}

struct ComposerView: View {
    @Bindable var store: AppStore
    let conversationID: String
    var placeholder: String = "补充上下文，或告诉 Agent 接下来要做什么…"
    @State private var text = ""
    @State private var attachments: [URL] = []
    @State private var attachmentError: String?
    @State private var showModel = false
    @State private var showPermissions = false
    @FocusState private var focused: Bool
    private var sending: Bool { store.sendingConversations.contains(conversationID) || store.importingConversations.contains(conversationID) }
    private var conversation: Conversation? { store.snapshot.conversations.first { $0.id == conversationID } }
    private var selection: ExecutionSelection { conversation?.selection ?? .init() }
    private var run: RunRecord? { store.snapshot.runs.filter { $0.conversationID == conversationID && !$0.status.isTerminal }.max { $0.createdAt < $1.createdAt } }
    private var model: ExecutorModel? { store.catalogs[selection.executor]?.first { $0.id == selection.modelID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AttachmentTextEditor(text: $text, attachments: $attachments, accessibilityLabel: "会话消息", isFocused: $focused, placeholder: placeholder)
                .id(conversationID)
                .frame(height: 50)
            if !attachments.isEmpty {
                AttachmentPreviewList(urls: attachments) { url in attachments.removeAll { $0 == url } }.frame(height: 64)
            }
            if let attachmentError { Text(attachmentError).font(.system(size: 11)).foregroundStyle(KanbanTheme.danger) }
            HStack(spacing: 12) {
                Button(action: attachFiles) { DesignIcon(name: "imgIconPlus", size: 20) }.buttonStyle(.plain).help("添加附件")
                Button { showPermissions.toggle() } label: {
                    DesignIcon(name: selection.permission == .fullAccess ? "imgIconUnlock" : "imgIconShield", size: 18, color: selection.permission == .fullAccess ? KanbanTheme.orange : KanbanTheme.muted)
                        .padding(7).background(KanbanTheme.sidebar, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).help(selection.permission?.title ?? "执行器默认权限")
                    .popover(isPresented: $showPermissions, arrowEdge: .bottom) {
                        PermissionPicker(store: store, selection: selection) { store.updateSelection($0); showPermissions = false }
                    }
                Spacer(minLength: 8)
                Button { showModel.toggle() } label: {
                    HStack(spacing: 6) {
                        ExecutorIcon(executor: selection.executor, size: 17)
                        Text(selection.executor.title).font(.system(size: 11)).foregroundStyle(KanbanTheme.muted)
                        Text(model?.displayName ?? selection.modelID ?? "默认模型").font(.system(size: 13, weight: .medium)).foregroundStyle(KanbanTheme.ink).lineLimit(1)
                        Text(effortTitle(selection.effort)).font(.system(size: 13, weight: .medium)).foregroundStyle(KanbanTheme.effort(selection.effort))
                        DesignIcon(name: "imgIconDown", size: 12)
                    }
                }.buttonStyle(.plain).popover(isPresented: $showModel, arrowEdge: .bottom) {
                    ModelReasoningPicker(store: store, initial: selection)
                }
                Button {
                    if let run { store.stopRun(run.id) } else { send() }
                } label: {
                    if run != nil { Image(systemName: "stop.fill").font(.system(size: 13)) }
                    else if sending { ProgressView().controlSize(.small).tint(.white) }
                    else { DesignIcon(name: "imgIconSend", size: 18, color: .white) }
                }.buttonStyle(KanbanPrimaryButtonStyle(circle: true)).buttonBorderShape(.circle).controlSize(.large)
                    .disabled(run == nil && (sending || (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)))
                    .accessibilityLabel(run?.status == .queued ? "取消排队" : run != nil ? "停止运行" : "发送消息")
                    .keyboardShortcut(.return, modifiers: [.command]).help(run?.status == .queued ? "取消排队" : run != nil ? "停止运行" : "发送 · ⌘Return")
            }.frame(height: 38)
        }.padding(18)
            .background(KanbanTheme.panel.opacity(0.9), in: RoundedRectangle(cornerRadius: 24))
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(KanbanTheme.line.opacity(0.45), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.06), radius: 12, y: 6)
            .onChange(of: conversationID) { _, _ in text = ""; attachments = []; attachmentError = nil }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                for provider in providers { _ = provider.loadObject(ofClass: URL.self) { url, _ in if let url { Task { @MainActor in addAttachments([url]) } } } }
                return !providers.isEmpty
            }
    }

    private func attachFiles() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.prompt = "添加附件"
        if panel.runModal() == .OK { addAttachments(panel.urls) }
    }
    private func addAttachments(_ urls: [URL]) {
        let result = ClipboardAttachmentReader.files(urls, existingURLs: attachments)
        attachments += result.urls; attachmentError = result.errors.isEmpty ? nil : result.errors.joined(separator: "\n")
    }
    private func send() {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty || !attachments.isEmpty else { return }
        guard store.sendMessage(prompt, attachments: attachments) else { return }
        text = ""; attachments = []; attachmentError = nil; focused = true
    }
}
