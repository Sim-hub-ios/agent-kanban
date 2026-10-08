import AppKit
import SwiftUI
import AgentKanbanCore
import AgentKanbanExecutors

struct TaskEditorSheet: View {
    @Bindable var store: AppStore
    let task: TaskItem?
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var details: String
    @State private var attachments: [URL]
    @State private var attachmentError: String?
    @State private var type: TaskType
    @State private var priority: TaskPriority
    init(store: AppStore, task: TaskItem? = nil) {
        self.store = store; self.task = task
        _title = State(initialValue: task?.title ?? "")
        _details = State(initialValue: task?.description ?? "")
        _attachments = State(initialValue: (task?.attachments ?? []).map { URL(fileURLWithPath: $0.path) })
        _type = State(initialValue: task?.type ?? .feature)
        _priority = State(initialValue: task?.priority ?? .normal)
    }
    var body: some View {
        VStack(spacing: 0) {
            DialogHeader(title: task == nil ? "新建任务" : "编辑任务", subtitle: "任务从待处理开始，由你决定何时进入下一阶段。") { dismiss() }
            VStack(alignment: .leading, spacing: 16) {
                field("任务标题") {
                    TextField("输入任务标题", text: $title).textFieldStyle(.plain).padding(12).frame(height: 42).contentPanel(radius: 12).accessibilityLabel("任务标题")
                }
                field("说明与备注") {
                    VStack(alignment: .leading, spacing: 8) {
                        AttachmentTextEditor(text: $details, attachments: $attachments, accessibilityLabel: "说明与备注，多行编辑", textContainerInset: .zero,
                                             placeholder: "补充问题、交付边界或参考信息…\n\n支持多行输入，⌘V 粘贴图片或文件")
                            .padding(12).frame(height: 114).contentPanel(radius: 10)
                        if !attachments.isEmpty {
                            AttachmentPreviewList(urls: attachments) { url in attachments.removeAll { $0 == url } }.frame(height: 64)
                        }
                        HStack {
                            Button(action: attachFiles) {
                                Label("添加附件", systemImage: "paperclip").font(.system(size: 11))
                            }.buttonStyle(.plain).foregroundStyle(KanbanTheme.muted)
                            Spacer()
                        }
                        if let attachmentError { Text(attachmentError).font(.system(size: 11)).foregroundStyle(KanbanTheme.danger) }
                    }
                }
                HStack(spacing: 18) {
                    field("类型") { ChoiceField(title: "类型", selection: $type, values: TaskType.allCases) { $0.title } }
                    field("优先级") { ChoiceField(title: "优先级", selection: $priority, values: TaskPriority.allCases) { $0.title } }
                }
                HStack(spacing: 10) {
                    Image(systemName: "info.circle").foregroundStyle(KanbanTheme.blue)
                    Text(task == nil ? "使用项目默认执行器创建待处理任务，可在任务会话中调整。" : "修改需求会使已有确认和验收结果失效。")
                        .font(.system(size: 12)).foregroundStyle(KanbanTheme.muted)
                    Spacer(minLength: 0)
                }.padding(14).background(KanbanTheme.blueSoft, in: RoundedRectangle(cornerRadius: 10))
            }.padding(24)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
                Button(task == nil ? "创建待处理任务" : "保存修改") {
                    if let task { store.updateTask(task.id, title: title, description: details, type: type, priority: priority, attachments: attachments) }
                    else { store.createTask(title: title, description: details, type: type, priority: priority, attachments: attachments) }
                    dismiss()
                }.buttonStyle(KanbanPrimaryButtonStyle()).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).keyboardShortcut(.defaultAction)
            }.padding(24).padding(.top, 10)
        }.frame(width: 760).background(KanbanTheme.background)
    }
    private func attachFiles() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.prompt = "添加附件"
        if panel.runModal() == .OK {
            let result = ClipboardAttachmentReader.files(panel.urls, existingURLs: attachments)
            attachments += result.urls; attachmentError = result.errors.isEmpty ? nil : result.errors.joined(separator: "\n")
        }
    }
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(title).font(.system(size: 12, weight: .medium)); content() }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ImportProjectSheet: View {
    @Bindable var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var directory: URL?
    @State private var name = ""
    @State private var executor: ExecutorID = .codex

    var body: some View {
        VStack(spacing: 0) {
            DialogHeader(title: "导入本机项目", subtitle: "把已有代码库加入工作区，在项目下管理任务与会话。") { dismiss() }
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("本机项目目录").font(.system(size: 13, weight: .medium))
                    HStack(spacing: 10) {
                        DesignIcon(name: "imgIconFolder", size: 20, color: KanbanTheme.blue)
                        Text(directory.map { abbreviatedPath($0.path) } ?? "选择本机 Git 代码库").foregroundStyle(directory == nil ? KanbanTheme.muted : KanbanTheme.ink).lineLimit(2).textSelection(.enabled)
                        Spacer()
                        Button("选择文件夹") { selectDirectory() }.buttonStyle(.glass)
                    }.padding(12).contentPanel(radius: 10)
                    Text("选择本机代码库目录，并授权应用访问。").font(.system(size: 12)).foregroundStyle(KanbanTheme.muted)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("项目名称 · 可选").font(.system(size: 13, weight: .medium))
                    TextField("留空时使用目录名称", text: $name).textFieldStyle(.plain).padding(12).frame(height: 42).contentPanel(radius: 10)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("项目执行器").font(.system(size: 13, weight: .medium))
                    ChoiceField(title: "项目执行器", selection: $executor, values: ExecutorID.allCases) { $0.title }
                }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle").foregroundStyle(KanbanTheme.blue)
                    Text("任务在项目目录执行。导入时校验目录和 Git 状态，执行器连接与认证单独检测。").font(.system(size: 12)).foregroundStyle(KanbanTheme.muted).lineSpacing(4)
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(KanbanTheme.blueSoft, in: RoundedRectangle(cornerRadius: 10))
            }.padding(24)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
                Button("导入项目") {
                    guard let directory else { return }
                    store.importProject(directory: directory, name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? directory.lastPathComponent : name, executor: executor); dismiss()
                }.buttonStyle(KanbanPrimaryButtonStyle()).disabled(directory == nil).keyboardShortcut(.defaultAction)
            }.padding(24)
        }.frame(width: 640, height: 580).background(KanbanTheme.background)
    }
    private func selectDirectory() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false; panel.prompt = "选择项目目录"
        if panel.runModal() == .OK, let url = panel.url { directory = url }
    }
}

struct RemoveProjectSheet: View {
    @Bindable var store: AppStore
    let project: Project
    @Environment(\.dismiss) private var dismiss
    private var active: Bool { store.snapshot.runs.contains { $0.projectID == project.id && !$0.status.isTerminal } || store.importingConversations.contains { id in store.snapshot.conversations.contains { $0.id == id && $0.projectID == project.id } } }
    var body: some View {
        VStack(spacing: 0) {
            DialogHeader(title: "移除项目？", subtitle: project.name) { dismiss() }
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) { DesignIcon(name: "imgIconFolder", size: 26, color: KanbanTheme.blue); VStack(alignment: .leading, spacing: 5) { Text(project.name).font(.system(size: 15, weight: .semibold)); Text(abbreviatedPath(project.path)).font(.system(size: 12)).foregroundStyle(KanbanTheme.muted).textSelection(.enabled) }; Spacer() }.padding(16).contentPanel(radius: 12)
                Text("移除后项目不再显示。重新导入相同目录会创建新的项目空间，任务与会话从空白开始。").font(.system(size: 13)).foregroundStyle(KanbanTheme.muted).lineSpacing(5)
                Text("不会删除本机代码或目录。").font(.system(size: 13, weight: .medium)).foregroundStyle(KanbanTheme.ink)
                if active { Text("项目仍有运行或导入任务；请先结束这些操作。").font(.system(size: 12)).foregroundStyle(KanbanTheme.orange) }
            }.padding(24)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
                Button("移除项目", role: .destructive) { store.removeProject(project.id); dismiss() }.buttonStyle(KanbanPrimaryButtonStyle(tint: Color(red: 191 / 255, green: 68 / 255, blue: 68 / 255))).disabled(active)
            }.padding(24)
        }.frame(width: 580).background(KanbanTheme.background)
    }
}

struct AuthenticationSheet: View {
    @Bindable var store: AppStore
    @Environment(\.dismiss) private var dismiss
    private var project: Project? { store.activeProject }
    var body: some View {
        VStack(spacing: 0) {
            DialogHeader(title: "执行器与认证", subtitle: "Codex、Claude、Cursor · 本机共享状态") { dismiss() }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let project {
                        Text(project.name + " · 默认执行器").font(.system(size: 13, weight: .medium))
                        ChoiceField(title: "默认执行器", selection: Binding(get: { store.activeProject?.defaultExecutor ?? .codex }, set: { value in store.setDefaultExecutor(value) }), values: ExecutorID.allCases) { $0.title }
                    }
                    HStack {
                        Text("任务和会话分别选择模型").font(.system(size: 12)).foregroundStyle(KanbanTheme.muted)
                        Spacer()
                        if store.refreshingExecutors { ProgressView().controlSize(.small) }
                        Button("检查全部") { store.refreshExecutors() }.buttonStyle(.glass).controlSize(.small).disabled(store.refreshingExecutors)
                    }
                    ForEach(ExecutorID.allCases) { executor in authenticationCard(executor) }
                    HStack(alignment: .top, spacing: 10) {
                        DesignIcon(name: "imgIconLock", size: 13)
                        Text("认证状态由本机共享，项目只保存执行器选择。已认证不等于所有模型可用。").font(.system(size: 11)).foregroundStyle(KanbanTheme.muted).lineSpacing(4)
                    }.padding(.top, 2)
                }.padding(24)
            }
            HStack { Spacer(); Button("完成") { dismiss() }.buttonStyle(KanbanPrimaryButtonStyle()).keyboardShortcut(.cancelAction) }.padding(24)
        }.frame(width: 760, height: 812).background(KanbanTheme.background)
    }
    private func authenticationCard(_ executor: ExecutorID) -> some View {
        let probe = store.probes[executor] ?? ExecutorInstallation(id: executor)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ExecutorIcon(executor: executor, size: 24)
                Text(executor.title).font(.system(size: 15, weight: .medium))
                if project?.defaultExecutor == executor { StatusChip(text: "当前项目", color: KanbanTheme.blue, background: KanbanTheme.blueSoft) }
                Spacer()
                StatusChip(text: authenticationTitle(probe.authentication), color: probe.authentication == .authenticated || probe.authentication == .configured ? KanbanTheme.green : KanbanTheme.orange, background: probe.authentication == .authenticated || probe.authentication == .configured ? KanbanTheme.greenSoft : KanbanTheme.orangeSoft)
            }
            Text(probe.detail).font(.system(size: 12)).foregroundStyle(KanbanTheme.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            HStack {
                Button("重新检测") { store.refreshExecutors(executor) }.buttonStyle(.glass).controlSize(.small).disabled(store.refreshingExecutors)
                if probe.authentication != .authenticated {
                    Button("去登录") { store.openAuthentication(executor) }.buttonStyle(KanbanPrimaryButtonStyle()).controlSize(.small)
                }
                Spacer(minLength: 12)
                Text((probe.version ?? "版本未检测") + " · 检查 " + probe.checkedAt.formatted(date: .omitted, time: .shortened)).font(.system(size: 11)).foregroundStyle(KanbanTheme.muted).lineLimit(1)
            }
        }.padding(14).contentPanel(radius: 12)
    }
    private func authenticationTitle(_ state: AuthenticationState) -> String {
        switch state {
        case .notInstalled: "未安装"
        case .unknown: "未确认"
        case .unauthenticated: "未认证"
        case .configured: "已配置"
        case .authenticated: "已认证"
        case .failed: "检测失败"
        }
    }
}

private struct DialogHeader: View {
    let title: String
    let subtitle: String
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.system(size: 20, weight: .semibold))
                Spacer()
                Button(action: close) { DesignIcon(name: "imgIconClose", size: 18) }.buttonStyle(.plain).help("关闭")
            }
            Text(subtitle).font(.system(size: 13)).foregroundStyle(KanbanTheme.muted).lineSpacing(4)
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading).background(.regularMaterial)
            .overlay(alignment: .bottom) { KanbanTheme.line.frame(height: 1) }
    }
}

private struct ChoiceField<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let values: [Value]
    let label: (Value) -> String
    var body: some View {
        Menu {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                Button(label(value)) { selection = value }
            }
        } label: {
            HStack {
                Text(label(selection)).font(.system(size: 13))
                Spacer()
                DesignIcon(name: "imgIconDown", size: 14)
            }.foregroundStyle(KanbanTheme.ink).padding(.horizontal, 12).frame(height: 42).frame(maxWidth: .infinity).contentPanel(radius: 10)
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).accessibilityLabel(title)
    }
}
