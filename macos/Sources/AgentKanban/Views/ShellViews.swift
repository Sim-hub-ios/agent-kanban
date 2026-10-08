import AppKit
import SwiftUI
import AgentKanbanCore

struct RootContentView: View {
    @Bindable var store: AppStore
    @State private var dialog: WorkspaceDialog?
    @State private var removingProject: Project?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var project: Project? { store.snapshot.projects.first { $0.id == store.selectedProjectID && $0.isActive } }
    private var task: TaskItem? { store.snapshot.tasks.first { $0.id == store.selectedTaskID } }

    var body: some View {
        VStack(spacing: 0) {
            titlebar
            HStack(spacing: 0) {
                SidebarView(store: store, importProject: { dialog = .importProject }, authenticate: { dialog = .authentication }, remove: { removingProject = $0 })
                    .frame(width: KanbanTheme.sidebarWidth)
                GeometryReader { geometry in
                ZStack(alignment: .trailing) {
                    Group {
                        switch store.route {
                        case .board, .task:
                            BoardView(store: store, importProject: { dialog = .importProject }, newTask: { dialog = .newTask })
                        case .chat:
                            ProjectChatView(store: store)
                        case .runs:
                            RunHistoryView(store: store)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    if store.route == .task, let task {
                        Color.black.opacity(0.13).onTapGesture { store.route = .board; store.selectedTaskID = nil }
                        TaskDetailView(store: store, task: task, edit: { dialog = .editTask(task.id) })
                            .frame(width: min(658, geometry.size.width)).transition(.move(edge: .trailing).combined(with: .opacity))
                            .shadow(color: .black.opacity(0.13), radius: 24, x: -6, y: 10)
                    }
                }
                .clipped()
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            statusbar
        }
        .font(.system(size: 13)).foregroundStyle(KanbanTheme.ink).tint(KanbanTheme.blue)
        .environment(\.locale, Locale(identifier: "zh_CN"))
        .background(KanbanTheme.background)
        .ignoresSafeArea(.container, edges: .top)
        .sheet(item: $dialog) { value in
            switch value {
            case .importProject: ImportProjectSheet(store: store)
            case .newTask: TaskEditorSheet(store: store)
            case .editTask(let id): TaskEditorSheet(store: store, task: store.snapshot.tasks.first { $0.id == id })
            case .authentication: AuthenticationSheet(store: store)
            }
        }
        .sheet(item: $removingProject) { project in RemoveProjectSheet(store: store, project: project) }
        .alert("无法完成操作", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("关闭", role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
    }

    private var titlebar: some View {
        HStack(spacing: 16) {
            Color.clear.frame(width: 64, height: 16).accessibilityHidden(true)
            Text("Agent Kanban").font(.system(size: 13, weight: .medium))
            Divider().frame(height: 18)
            DesignIcon(name: "imgIconFolder", size: 15)
            Text(store.route == .runs ? "所有项目" : project?.name ?? "未选择项目").font(.system(size: 12)).foregroundStyle(KanbanTheme.muted)
            DesignIcon(name: "imgIconChevron", size: 12)
            Text("本机工作区").font(.system(size: 12)).foregroundStyle(KanbanTheme.muted)
            Spacer()
            StatusChip(text: "本地运行", color: KanbanTheme.green, background: KanbanTheme.greenSoft)
        }
        .padding(.horizontal, 16).frame(height: KanbanTheme.titlebarHeight)
        .background(reduceTransparency ? KanbanTheme.panel : KanbanTheme.panel.opacity(0.64))
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { KanbanTheme.line.opacity(0.4).frame(height: 1) }
        .gesture(WindowDragGesture())
    }

    private var statusbar: some View {
        HStack(spacing: 12) {
            DesignIcon(name: "imgIconFolder", size: 13)
            Text(store.route == .runs ? "所有项目 · 活动运行" : (task?.worktreePath ?? project?.path).map(abbreviatedPath) ?? "尚未导入项目").lineLimit(1)
            DesignIcon(name: "imgIconLock", size: 12)
            Text(store.route == .runs ? "权限按各运行配置" : task?.worktreePath == nil ? "项目目录 · 原生权限" : "Git Worktree · 原生权限").lineLimit(1)
            Spacer()
            Text(store.activeRuns.isEmpty ? "本机工作区" : "有活动运行")
                .foregroundStyle(KanbanTheme.green).padding(.horizontal, 6).padding(.vertical, 3)
                .background(KanbanTheme.greenSoft, in: RoundedRectangle(cornerRadius: 5))
        }.font(.system(size: 11)).foregroundStyle(KanbanTheme.muted)
            .padding(.horizontal, 12).frame(height: KanbanTheme.statusbarHeight)
            .background(.regularMaterial)
            .overlay(alignment: .top) { KanbanTheme.line.opacity(0.4).frame(height: 1) }
    }
}

private enum WorkspaceDialog: Identifiable {
    case importProject, newTask, editTask(String), authentication
    var id: String { switch self { case .importProject: "import"; case .newTask: "new"; case .editTask(let id): "edit-" + id; case .authentication: "auth" } }
}

struct SidebarView: View {
    @Bindable var store: AppStore
    let importProject: () -> Void
    let authenticate: () -> Void
    let remove: (Project) -> Void
    @State private var collapsed: Set<String> = []
    @State private var deletingConversation: Conversation?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var tasks: [TaskItem] { store.snapshot.tasks.filter { $0.projectID == store.selectedProjectID } }
    private var runs: [RunRecord] { store.activeRuns }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                DesignIcon(name: "imgIconBoard", size: 21, color: KanbanTheme.blue)
                    .frame(width: 32, height: 32).background(KanbanTheme.blueSoft, in: RoundedRectangle(cornerRadius: 8))
                Text("Agent Kanban").font(.system(size: 16, weight: .semibold))
            }.frame(height: 46)
            Text("工作台").font(.system(size: 11, weight: .medium)).foregroundStyle(KanbanTheme.muted)
            navigationRow("任务看板", icon: "imgIconBoard", count: tasks.count, selected: store.route == .board || store.route == .task) {
                store.route = .board; store.selectedTaskID = nil
            }
            navigationRow("运行中", icon: "imgIconClock", count: runs.count, selected: store.route == .runs) { store.route = .runs }
            Spacer().frame(height: 12)
            Divider().overlay(KanbanTheme.line)
            HStack {
                Text("本机项目").font(.system(size: 11, weight: .medium)).foregroundStyle(KanbanTheme.muted)
                Spacer()
                Button(action: importProject) { DesignIcon(name: "imgIconPlus", size: 17) }.buttonStyle(.plain).help("导入项目")
            }.frame(height: 36)
            Button(action: importProject) {
                HStack(spacing: 8) {
                    DesignIcon(name: "imgIconFolder", size: 17)
                    Text("导入项目").font(.system(size: 13, weight: .medium))
                    Spacer()
                }.foregroundStyle(KanbanTheme.muted).padding(.horizontal, 10).frame(height: 36)
            }.buttonStyle(.plain).glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 12))
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(store.snapshot.projects.filter(\.isActive)) { project in projectTile(project) }
                }.padding(.bottom, 8)
            }.scrollIndicators(.hidden)
            Spacer(minLength: 8)
            Button(action: authenticate) {
                HStack(spacing: 10) {
                    DesignIcon(name: "imgIconShield", size: 18)
                    Text("执行器与认证").font(.system(size: 13, weight: .medium))
                    Spacer()
                }.foregroundStyle(KanbanTheme.muted).padding(.horizontal, 10).frame(height: 40)
            }.buttonStyle(.plain)
            Divider().overlay(KanbanTheme.line)
            HStack(spacing: 10) {
                Text("S").font(.system(size: 14, weight: .medium)).foregroundStyle(KanbanTheme.blue)
                    .frame(width: 32, height: 32).background(KanbanTheme.blueSoft, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text("本机工作区").font(.system(size: 12, weight: .medium))
                    Text("任务与会话保存在本机").font(.system(size: 11)).foregroundStyle(KanbanTheme.muted)
                }
                Spacer(minLength: 0)
            }.frame(height: 54)
        }
        .padding(16).frame(maxHeight: .infinity)
        .background(reduceTransparency ? KanbanTheme.sidebar : KanbanTheme.sidebar.opacity(0.67))
        .background(.regularMaterial)
        .overlay(alignment: .trailing) { KanbanTheme.line.opacity(0.6).frame(width: 1) }
        .alert("删除会话？", isPresented: Binding(get: { deletingConversation != nil }, set: { if !$0 { deletingConversation = nil } })) {
            Button("取消", role: .cancel) { deletingConversation = nil }
            Button("删除会话", role: .destructive) {
                if let chat = deletingConversation { store.deleteConversation(chat.id) }
                deletingConversation = nil
            }.disabled(deletingConversation.map { conversationIsBusy($0.id) } ?? false)
        } message: {
            if let chat = deletingConversation {
                Text(conversationIsBusy(chat.id) ? "此会话仍有发送、运行或任务导入，请先停止并等待结束。" : "将删除“\(chat.title)”及其会话记录。已导入看板的任务和本机项目文件会保留。")
            }
        }
    }

    private func navigationRow(_ title: String, icon: String, count: Int, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                DesignIcon(name: icon, size: 18, color: selected ? KanbanTheme.blue : KanbanTheme.muted)
                Text(title).font(.system(size: 14, weight: .medium))
                Spacer()
                Text("\(count)").font(.system(size: 12))
            }.foregroundStyle(selected ? KanbanTheme.blue : KanbanTheme.muted)
                .padding(.horizontal, 10).frame(height: 40)
                .background(selected ? KanbanTheme.blue.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? KanbanTheme.line : .clear))
        }.buttonStyle(.plain)
    }

    private func projectTile(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Button { if !collapsed.insert(project.id).inserted { collapsed.remove(project.id) } } label: {
                    DesignIcon(name: "imgIconDown", size: 13).rotationEffect(.degrees(collapsed.contains(project.id) ? -90 : 0))
                }.buttonStyle(.plain).help(collapsed.contains(project.id) ? "展开项目" : "折叠项目")
                Button { store.selectProject(project.id) } label: {
                    HStack(spacing: 7) {
                        Text(project.name.prefix(1).uppercased()).font(.system(size: 14, weight: .medium)).foregroundStyle(KanbanTheme.blue)
                            .frame(width: 22, height: 22).background(KanbanTheme.blueSoft, in: RoundedRectangle(cornerRadius: 8))
                        Text(project.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    }.foregroundStyle(KanbanTheme.ink)
                }.buttonStyle(.plain)
                Spacer(minLength: 0)
                Menu {
                    Button("新建会话") { store.selectProject(project.id); store.createConversation() }
                    Button("在 Finder 中显示") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path) }
                    Divider()
                    Button("移除项目", role: .destructive) { remove(project) }
                } label: { DesignIcon(name: "imgIconMore", size: 16) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }.frame(height: 30)
            if !collapsed.contains(project.id) {
                Text(abbreviatedPath(project.path)).font(.system(size: 11)).foregroundStyle(KanbanTheme.muted).lineLimit(2).textSelection(.enabled)
                Button { store.selectProject(project.id); store.createConversation() } label: {
                    HStack(spacing: 6) {
                        DesignIcon(name: "imgIconPlus", size: 16)
                        Text("新建会话").font(.system(size: 12))
                        Spacer()
                    }.foregroundStyle(KanbanTheme.muted).frame(height: 32)
                }.buttonStyle(.plain)
                ForEach(store.snapshot.conversations.filter { $0.projectID == project.id && $0.kind == .projectChat }) { chat in
                    conversationRow(chat)
                }
            }
        }.padding(10)
            .background(reduceTransparency ? KanbanTheme.panel : KanbanTheme.panel.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(KanbanTheme.line))
    }

    private func conversationIsBusy(_ id: String) -> Bool {
        store.sendingConversations.contains(id) || store.importingConversations.contains(id) || store.snapshot.runs.contains { $0.conversationID == id && !$0.status.isTerminal }
    }

    private func conversationRow(_ chat: Conversation) -> some View {
        let selected = store.selectedConversationID == chat.id && store.route == .chat
        return HStack(spacing: 3) {
            Button { store.selectConversation(chat.id) } label: {
                HStack(spacing: 7) {
                    DesignIcon(name: "imgIconChat", size: 16, color: selected ? KanbanTheme.blue : KanbanTheme.muted)
                    Text(chat.title).font(.system(size: 12)).lineLimit(1)
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            Menu {
                Button("删除会话", role: .destructive) { deletingConversation = chat }
            } label: { DesignIcon(name: "imgIconMore", size: 14) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("会话更多操作：\(chat.title)")
        }.padding(.horizontal, 7).frame(height: 34)
            .foregroundStyle(selected ? KanbanTheme.blue : KanbanTheme.muted)
            .background(selected ? KanbanTheme.blueSoft : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contextMenu { Button("删除会话", role: .destructive) { deletingConversation = chat } }
    }
}
