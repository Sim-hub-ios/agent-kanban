import SwiftUI
import AgentKanbanCore

struct BoardView: View {
    @Bindable var store: AppStore
    let importProject: () -> Void
    let newTask: () -> Void
    @State private var query = ""
    @State private var type: TaskType?
    @State private var executor: ExecutorID?
    @State private var onlyRunning = false

    private var project: Project? { store.snapshot.projects.first { $0.id == store.selectedProjectID && $0.isActive } }
    private var tasks: [TaskItem] { store.snapshot.tasks.filter { $0.projectID == project?.id } }
    private var activeRuns: [RunRecord] { store.snapshot.runs.filter { $0.projectID == project?.id && !$0.status.isTerminal } }
    private var approvals: [Approval] { store.snapshot.approvals.filter { $0.projectID == project?.id && $0.status == .pending } }

    var body: some View {
        GeometryReader { geometry in
            ScrollView([.vertical, .horizontal]) {
                if project == nil {
                    VStack(alignment: .leading, spacing: 22) {
                        Text("任务看板").font(.system(size: 26, weight: .medium)).frame(height: 39)
                        Text("导入本机项目，开始管理任务与会话。").font(.system(size: 14)).foregroundStyle(KanbanTheme.muted).frame(height: 21)
                        firstUse
                    }.padding(.top, 44).padding(.leading, 60).padding(.trailing, 36)
                        .frame(width: geometry.size.width, alignment: .topLeading)
                } else {
                VStack(alignment: .leading, spacing: 16) {
                    heading
                    if let project {
                        projectLine(project)
                        filters
                        if !approvals.isEmpty { approvalBanner }
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(TaskPhase.allCases) { phase in
                                column(phase).frame(width: max(220.8, (geometry.size.width - 104) / 5))
                            }
                        }
                    } else { firstUse }
                    Spacer(minLength: 0)
                }.padding(28).frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
                }
            }.scrollIndicators(.hidden)
        }.background(KanbanTheme.background)
    }

    private var heading: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("任务看板").font(.system(size: 24, weight: .semibold))
                Text(project == nil ? "导入本机项目，开始管理任务与会话。" : "把上下文留在任务里，让每个阶段都有清楚的结果。")
                    .font(.system(size: 13)).foregroundStyle(KanbanTheme.muted)
            }
            Spacer()
            if project != nil {
                Button(action: newTask) { Label("新建任务", systemImage: "plus").font(.system(size: 13, weight: .medium)).padding(.horizontal, 3) }
                    .buttonStyle(KanbanPrimaryButtonStyle()).controlSize(.large).keyboardShortcut("n", modifiers: [.command])
            }
        }.frame(minHeight: 68, alignment: .top)
    }

    private func projectLine(_ project: Project) -> some View {
        HStack(spacing: 10) {
            DesignIcon(name: "imgIconFolder", size: 17)
            Text(project.name).font(.system(size: 14, weight: .medium))
            Text("本机代码库").font(.system(size: 12)).foregroundStyle(KanbanTheme.muted)
            Spacer()
            Text("进行中 \(tasks.filter { $0.phase != .backlog && $0.phase != .completed }.count)").foregroundStyle(KanbanTheme.muted)
            Text("运行 \(activeRuns.count)").foregroundStyle(KanbanTheme.blue)
            Text("待审批 \(approvals.count)").foregroundStyle(KanbanTheme.orange)
        }.font(.system(size: 12)).frame(height: 30)
    }

    private var filters: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                DesignIcon(name: "imgIconSearch", size: 16)
                TextField("搜索任务、编号或标签", text: $query).textFieldStyle(.plain).font(.system(size: 12))
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(KanbanTheme.muted) }.buttonStyle(.plain) }
            }.padding(.horizontal, 12).frame(width: 320, height: 36)
                .background(KanbanTheme.panel.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
                .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(KanbanTheme.line.opacity(0.7)))
            Spacer(minLength: 20)
            Menu {
                Button("所有类型") { type = nil }
                ForEach(TaskType.allCases) { value in Button(value.title) { type = value } }
            } label: { filterLabel(type?.title ?? "所有类型") }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            Menu {
                Button("所有执行器") { executor = nil }
                ForEach(ExecutorID.allCases) { value in Button(value.title) { executor = value } }
            } label: { filterLabel(executor?.title ?? "所有执行器") }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            Button { onlyRunning.toggle() } label: { Text("只看运行").font(.system(size: 13, weight: .medium)).padding(.horizontal, 14).frame(height: 36) }
                .buttonStyle(.plain).foregroundStyle(onlyRunning ? KanbanTheme.blue : KanbanTheme.ink)
                .background(KanbanTheme.panel.opacity(0.8), in: Capsule())
                .glassEffect(.regular.tint(onlyRunning ? KanbanTheme.blue.opacity(0.15) : .clear).interactive(), in: Capsule())
                .overlay(Capsule().strokeBorder(KanbanTheme.line.opacity(0.7)))
                .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
        }.frame(height: 36)
    }

    private func filterLabel(_ title: String) -> some View {
        HStack(spacing: 8) { Text(title); DesignIcon(name: "imgTrailingChevron", size: 12) }
            .font(.system(size: 13, weight: .medium)).foregroundStyle(KanbanTheme.ink)
            .padding(.horizontal, 13).frame(height: 36)
            .background(KanbanTheme.panel.opacity(0.8), in: Capsule())
            .glassEffect(.regular.interactive(), in: Capsule())
            .overlay(Capsule().strokeBorder(KanbanTheme.line.opacity(0.7)))
            .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
    }

    private var approvalBanner: some View {
        Button {
            if let run = store.snapshot.runs.first(where: { $0.id == approvals.first?.runID }) {
                if let id = run.taskID { store.selectTask(id) } else { store.selectConversation(run.conversationID) }
            }
        } label: {
            HStack(spacing: 12) {
                DesignIcon(name: "imgIconShield", size: 19, color: KanbanTheme.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text("有 \(approvals.count) 项操作等待你的批准").font(.system(size: 12, weight: .medium)).foregroundStyle(KanbanTheme.ink)
                    Text(approvals.first?.title ?? "查看执行器的审批请求").font(.system(size: 11)).foregroundStyle(KanbanTheme.muted).lineLimit(1)
                }
                Spacer()
                Text("查看请求").font(.system(size: 12, weight: .medium)).foregroundStyle(KanbanTheme.muted)
            }.padding(.horizontal, 14).frame(height: 54).background(KanbanTheme.blueSoft, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
    }

    private func filtered(_ phase: TaskPhase) -> [TaskItem] {
        tasks.filter { task in
            task.phase == phase && (type == nil || type == task.type) && (executor == nil || executor == task.selection.executor)
                && (!onlyRunning || activeRuns.contains { $0.taskID == task.id })
                && (query.isEmpty || (task.displayID + task.title + task.description).localizedCaseInsensitiveContains(query))
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func column(_ phase: TaskPhase) -> some View {
        let items = filtered(phase)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle().fill(phase.color).frame(width: 7, height: 7)
                Text(phase.title).font(.system(size: 13, weight: .medium))
                StatusChip(text: "\(items.count)")
                Spacer()
                if phase == .backlog {
                    Button(action: newTask) { DesignIcon(name: "imgIconPlus", size: 15) }.buttonStyle(.plain).help("新建待处理任务")
                }
            }.frame(height: 28)
            ForEach(items) { task in
                TaskCard(task: task, snapshot: store.snapshot) { store.selectTask(task.id) }
                    .draggable(task.id)
                    .contextMenu {
                        Button("打开任务") { store.selectTask(task.id) }
                        Divider()
                        ForEach(TaskPhase.allCases.filter { $0 != task.phase && $0 != .completed }) { target in
                            Button("移至" + target.title) { store.transitionTask(task.id, to: target) }
                        }
                    }
            }
            if items.isEmpty {
                Text(query.isEmpty ? "暂无任务" : "没有匹配的任务").font(.system(size: 12)).foregroundStyle(KanbanTheme.muted)
                    .frame(maxWidth: .infinity, minHeight: 100)
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(KanbanTheme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
            }
            Spacer(minLength: 24)
        }.contentShape(Rectangle()).dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first, tasks.contains(where: { $0.id == id }) else { return false }
            store.transitionTask(id, to: phase)
            return true
        }
    }

    private var firstUse: some View {
        VStack(spacing: 18) {
            DesignIcon(name: "imgIconFolder", size: 30, color: KanbanTheme.blue)
                .frame(width: 64, height: 64).background(KanbanTheme.blueSoft, in: RoundedRectangle(cornerRadius: 18))
            Text("先添加一个本机项目").font(.system(size: 22, weight: .semibold))
            Text("选择已有代码库，项目中的任务、会话与运行记录会独立保存。")
                .font(.system(size: 14)).foregroundStyle(KanbanTheme.muted).multilineTextAlignment(.center)
            Button("导入项目", action: importProject).buttonStyle(KanbanPrimaryButtonStyle(minWidth: 140)).controlSize(.large).frame(width: 140, height: 36)
            Text("移除项目不会删除本机代码。").font(.system(size: 12)).foregroundStyle(KanbanTheme.muted)
        }.padding(40).frame(maxWidth: .infinity, minHeight: 594).contentPanel(radius: 16)
    }
}

private struct TaskCard: View {
    let task: TaskItem
    let snapshot: WorkspaceSnapshot
    let open: () -> Void
    private var run: RunRecord? { snapshot.runs.filter { $0.taskID == task.id }.max { $0.createdAt < $1.createdAt } }
    private var revision: RequirementRevision? { snapshot.revisions.first { $0.id == task.currentRevisionID } }
    private var status: String {
        if let run, !run.status.isTerminal { return run.status.title }
        switch task.phase {
        case .backlog: return "待开始"
        case .discussion: return revision?.confirmedAt == nil ? "方案待确认" : "方案已确认"
        case .development: return "等待执行"
        case .acceptance: return "待验收"
        case .completed: return "已由人确认完成"
        }
    }
    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text(task.displayID); Spacer(); DesignIcon(name: "imgIconMore", size: 14) }
                    .font(.system(size: 11)).foregroundStyle(KanbanTheme.muted)
                Text(task.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(KanbanTheme.ink).lineLimit(3).lineSpacing(3)
                if !task.description.isEmpty { Text(task.description).font(.system(size: 12)).foregroundStyle(KanbanTheme.muted).lineLimit(2).lineSpacing(3) }
                StatusChip(text: task.type.title, color: KanbanTheme.blue, background: KanbanTheme.blueSoft)
                Text(status).font(.system(size: 11, weight: .medium)).foregroundStyle(run.map { $0.status.isTerminal ? task.phase.color : $0.status.color } ?? task.phase.color)
                Divider().overlay(KanbanTheme.line)
                HStack(spacing: 6) {
                    ExecutorIcon(executor: task.selection.executor, size: 16)
                    Text(task.selection.executor.title + " · " + (task.selection.modelID ?? "默认模型")).font(.system(size: 11)).foregroundStyle(KanbanTheme.muted).lineLimit(1)
                }
                HStack(spacing: 4) {
                    DesignIcon(name: "imgIconChat", size: 12)
                    Text("\(snapshot.messages.filter { $0.conversationID == task.mainConversationID }.count)")
                    Spacer()
                    Text(task.updatedAt, style: .relative).lineLimit(1)
                }.font(.system(size: 11)).foregroundStyle(KanbanTheme.muted)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).contentPanel()
        }.buttonStyle(.plain)
    }
}
