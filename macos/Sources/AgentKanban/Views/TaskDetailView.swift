import SwiftUI
import AgentKanbanCore

struct TaskDetailView: View {
    @Bindable var store: AppStore
    let task: TaskItem
    let edit: () -> Void
    @State private var tab: DetailTab = .chat
    @State private var planText = ""
    @State private var editingPlan = false
    @State private var planSourceMessageID: String?
    @State private var planSourceRunID: String?
    @State private var planSourceDate: Date?
    @State private var savingPlan = false
    @State private var planEditToken = UUID()
    private var project: Project? { store.snapshot.projects.first { $0.id == task.projectID } }
    private var run: RunRecord? { store.snapshot.runs.filter { $0.taskID == task.id && !$0.status.isTerminal }.max { $0.createdAt < $1.createdAt } }
    private var revision: RequirementRevision? { store.snapshot.revisions.first { $0.id == task.currentRevisionID } }
    private var report: AcceptanceReport? { store.snapshot.reports.filter { $0.taskID == task.id }.max { $0.createdAt < $1.createdAt } }
    private var discussionDraft: DiscussionPlanDraft? { DiscussionPlanDraft.pending(task: task, snapshot: store.snapshot) }
    private var completionBlocked: Bool {
        store.changingTasks.contains(task.id) || store.sendingConversations.contains(task.mainConversationID) ||
        store.snapshot.runs.contains { !$0.status.isTerminal && ($0.taskID == task.id || $0.cwd == executionDirectory) }
    }
    private var executionDirectory: String { task.worktreePath ?? project?.path ?? "" }
    private var executionDirectoryChangeBlocked: Bool {
        task.phase == .completed || run != nil || store.changingTasks.contains(task.id) ||
        store.sendingConversations.contains(task.mainConversationID)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 22) {
                ForEach(DetailTab.allCases) { item in
                    Button {
                        tab = item
                        if item == .changes { store.loadChanges(taskID: task.id) }
                        if item == .plan { prepareDiscussionDraft() }
                    } label: {
                        Text(item.title).font(.system(size: 13, weight: tab == item ? .medium : .regular))
                            .foregroundStyle(tab == item ? KanbanTheme.blue : KanbanTheme.muted)
                            .frame(width: 98, height: 47)
                            .overlay(alignment: .bottom) { if tab == item { KanbanTheme.blue.frame(height: 2) } }
                    }.buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 24).background(.regularMaterial)
            Divider().overlay(KanbanTheme.line)
            Group {
                switch tab {
                case .chat: conversation
                case .plan: plan
                case .changes: changes
                case .acceptance: acceptance
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(KanbanTheme.panel).clipShape(RoundedRectangle(cornerRadius: 24))
        .onChange(of: task.id) { _, _ in
            tab = .chat; editingPlan = false; planText = ""; savingPlan = false
            planSourceMessageID = nil; planSourceRunID = nil; planSourceDate = nil
            planEditToken = UUID()
        }
        .onChange(of: discussionDraft?.sourceMessageID) { _, _ in
            if tab == .plan { prepareDiscussionDraft() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(task.displayID).font(.system(size: 11, weight: .medium))
                Text("/ " + (project?.name ?? "项目")).font(.system(size: 11))
                Spacer()
                Menu {
                    Button("编辑任务信息", action: edit)
                    Button("查看运行中") { store.route = .runs }
                } label: { DesignIcon(name: "imgIconMore", size: 18) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                Button { store.selectedTaskID = nil; store.route = .board } label: { DesignIcon(name: "imgIconClose", size: 18) }.buttonStyle(.plain).help("关闭任务详情")
            }.foregroundStyle(KanbanTheme.muted)
            Text(task.title).font(.system(size: 20, weight: .semibold)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                StatusChip(text: task.type.title)
                if task.priority == .high || task.priority == .urgent { StatusChip(text: task.priority.title + "优先级", color: KanbanTheme.orange, background: KanbanTheme.orangeSoft) }
                Spacer()
                if store.changingTasks.contains(task.id) { ProgressView().controlSize(.small) }
                if task.phase == .development || task.phase == .acceptance {
                    Button("确认完成") { store.completeTask(task.id) }
                        .buttonStyle(.glass).controlSize(.small).disabled(completionBlocked)
                        .help("由你确认完成，验收报告可选。")
                }
                Menu {
                    ForEach(TaskPhase.allCases) { phase in
                        Button(task.phase == .backlog && phase == .development ? "直接开发" : phase.title) {
                            if phase == .completed { store.completeTask(task.id) }
                            else if task.phase == .backlog && phase == .development { store.implementTaskDirectly(task.id) }
                            else { store.transitionTask(task.id, to: phase) }
                        }.disabled(task.phase == phase || (phase == .completed && completionBlocked))
                    }
                } label: {
                    HStack(spacing: 6) { Text(task.phase.title); DesignIcon(name: "imgIconDown", size: 14, color: KanbanTheme.blue) }
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(KanbanTheme.blue)
                }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().disabled(store.changingTasks.contains(task.id))
            }.frame(height: 26)
            HStack(spacing: 8) {
                DesignIcon(name: "imgIconFolder", size: 13, color: KanbanTheme.muted)
                Menu {
                    Button { store.setTaskWorktree(task.id, enabled: false) } label: {
                        Label("项目目录", systemImage: task.worktreePath == nil ? "checkmark" : "folder")
                    }.disabled(task.worktreePath == nil)
                    Button { store.setTaskWorktree(task.id, enabled: true) } label: {
                        Label("Git Worktree", systemImage: task.worktreePath == nil ? "arrow.triangle.branch" : "checkmark")
                    }.disabled(task.worktreePath != nil)
                } label: {
                    HStack(spacing: 5) {
                        Text(task.worktreePath == nil ? "项目目录" : "Git Worktree")
                        DesignIcon(name: "imgIconDown", size: 11)
                    }.font(.system(size: 11, weight: .medium))
                }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .disabled(executionDirectoryChangeBlocked)
                    .accessibilityLabel("执行目录")
                    .accessibilityValue(task.worktreePath == nil ? "项目目录" : "Git Worktree")
                    .help("选择任务执行目录。Git Worktree 从当前提交创建独立分支；未提交改动留在项目目录。")
                Text(abbreviatedPath(executionDirectory)).font(.system(size: 11)).foregroundStyle(KanbanTheme.muted).lineLimit(1)
                    .truncationMode(.middle).help(executionDirectory)
                Spacer(minLength: 0)
            }.padding(.top, 5)
            if task.worktreePath != nil {
                Text("从当前提交创建独立分支；未提交改动留在项目目录")
                    .font(.system(size: 10)).foregroundStyle(KanbanTheme.muted)
            }
        }.padding(24).frame(minHeight: 132).background(.regularMaterial)
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            if let attachments = task.attachments, !attachments.isEmpty {
                AttachmentPreviewList(urls: attachments.map { URL(fileURLWithPath: $0.path) })
                    .frame(height: 64).padding(.horizontal, 24).padding(.top, 12)
            }
            if let run {
                if run.status == .queued {
                    QueuedRunBanner(store: store, run: run).padding(.horizontal, 24).padding(.top, 12)
                } else {
                    HStack(spacing: 8) {
                        DesignIcon(name: "imgIconClock", size: 15, color: run.status.color)
                        Text(run.status.title).foregroundStyle(run.status.color)
                        Text(String(run.id.prefix(8))).foregroundStyle(KanbanTheme.muted)
                        Text(run.createdAt, style: .relative).foregroundStyle(KanbanTheme.muted)
                        Spacer()
                        Button("停止") { store.stopRun(run.id) }.buttonStyle(.glass).controlSize(.small).disabled(run.status == .cancelling)
                    }.font(.system(size: 11)).padding(.horizontal, 24).frame(height: 54).background(KanbanTheme.hover)
                }
            }
            ConversationStream(store: store, conversationID: task.mainConversationID).padding(.horizontal, 24)
            if task.phase == .backlog {
                VStack(alignment: .leading, spacing: 12) {
                    if !task.description.isEmpty { Text(task.description).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled) }
                    Text("可先讨论明确方案，也可直接按任务说明、备注和附件开始开发。")
                        .font(.system(size: 12)).foregroundStyle(KanbanTheme.muted)
                    HStack(spacing: 10) {
                        Spacer()
                        Button { store.transitionTask(task.id, to: .discussion) } label: {
                            Text("进入讨论").font(.system(size: 13, weight: .medium))
                                .foregroundStyle(KanbanTheme.ink).padding(.horizontal, 14).frame(minHeight: 36)
                                .glassEffect(.regular.interactive(), in: Capsule())
                        }.buttonStyle(.plain)
                        Button("直接开发") { store.implementTaskDirectly(task.id) }
                            .buttonStyle(KanbanPrimaryButtonStyle())
                            .help("跳过讨论并进入开发；执行目录被占用时自动排队，目录可用后开始。")
                    }
                    .disabled(store.changingTasks.contains(task.id) || store.sendingConversations.contains(task.mainConversationID) || run != nil)
                }.padding(14).background(KanbanTheme.blueSoft, in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 24)
                ComposerView(store: store, conversationID: task.mainConversationID, placeholder: "记录任务备注，选择讨论或直接开发后调用执行器…").padding(24)
            } else if task.phase == .completed {
                HStack(spacing: 8) { DesignIcon(name: "imgIconCheckCircle", size: 18, color: KanbanTheme.green); Text("任务已由你确认完成").font(.system(size: 13)).foregroundStyle(KanbanTheme.green); Spacer() }
                    .padding(18).background(KanbanTheme.greenSoft, in: RoundedRectangle(cornerRadius: 12)).padding(24)
            } else {
                ComposerView(store: store, conversationID: task.mainConversationID).padding(24)
            }
        }
    }

    private var plan: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Text("实施方案").font(.system(size: 16, weight: .semibold))
                if let revision { StatusChip(text: "v\(revision.version)", color: KanbanTheme.blue, background: KanbanTheme.blueSoft) }
                Spacer()
                StatusChip(text: editingPlan ? "草稿 · 未保存" : revision?.confirmedAt == nil ? "待你确认" : "已确认", color: editingPlan || revision?.confirmedAt == nil ? KanbanTheme.orange : KanbanTheme.green, background: editingPlan || revision?.confirmedAt == nil ? KanbanTheme.orangeSoft : KanbanTheme.greenSoft)
            }
            if task.phase == .development, task.directImplementationPhaseVersion == task.phaseVersion, revision == nil {
                Text("此任务已直接进入开发；开始验收前，请在此补充并确认方案与验收条件。")
                    .font(.system(size: 12)).foregroundStyle(KanbanTheme.muted)
            }
            if (editingPlan ? planSourceMessageID : revision?.sourceMessageID) != nil {
                HStack(spacing: 6) {
                    DesignIcon(name: "imgIconChat", size: 14, color: KanbanTheme.blue)
                    Text("来自主会话讨论")
                    if editingPlan, let planSourceDate { Text(planSourceDate, style: .time) }
                    Spacer()
                    Button("查看讨论") { tab = .chat }.buttonStyle(.plain).foregroundStyle(KanbanTheme.blue)
                }.font(.system(size: 11)).foregroundStyle(KanbanTheme.muted)
            }
            if editingPlan {
                Text("写明实施方案，并以“验收条件”标题列出每条可验证的条件。").font(.system(size: 12)).foregroundStyle(KanbanTheme.muted)
                TextEditor(text: $planText).font(.system(size: 13)).scrollContentBackground(.hidden).padding(10).frame(minHeight: 280)
                    .background(KanbanTheme.hover, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(KanbanTheme.line))
                    .accessibilityLabel("实施方案与验收条件").disabled(savingPlan)
                if DiscussionPlanDocument.parse(content: planText).acceptanceCriteria.isEmpty {
                    Text("尚未提取到验收条件，请以“## 验收条件”标题列出验收项，补充后再确认方案。")
                        .font(.system(size: 11)).foregroundStyle(KanbanTheme.orange)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let revision {
                            documentSection("需求与触发条件", content: revision.requirement)
                            documentSection("实施方案", content: revision.plan)
                            VStack(alignment: .leading, spacing: 8) {
                                Text("验收条件").font(.system(size: 14, weight: .semibold))
                                ForEach(Array(revision.acceptanceCriteria.enumerated()), id: \.offset) { index, criterion in
                                    HStack(alignment: .top, spacing: 8) {
                                        Text("\(index + 1).").foregroundStyle(KanbanTheme.blue)
                                        Text(criterion).textSelection(.enabled)
                                    }.font(.system(size: 13)).foregroundStyle(KanbanTheme.muted)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(14).background(KanbanTheme.hover, in: RoundedRectangle(cornerRadius: 10))
                        } else {
                            documentSection("任务说明", content: task.description.isEmpty ? "尚未补充任务说明。" : task.description)
                            Text("在主会话中讨论方案，或手动撰写实施方案与验收条件。").font(.system(size: 13)).foregroundStyle(KanbanTheme.muted)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
            Divider().overlay(KanbanTheme.line)
            Text("需求或方案变更会生成新版本，并使已有确认和验收报告失效。").font(.system(size: 11)).foregroundStyle(KanbanTheme.muted)
            HStack {
                if editingPlan {
                    Button("取消") { editingPlan = false }.buttonStyle(.glass).disabled(savingPlan)
                    Spacer()
                    Button(savingPlan ? "保存中…" : "保存新版本", action: savePlan)
                        .buttonStyle(KanbanPrimaryButtonStyle()).disabled(savingPlan || run != nil || planText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    Button(revision == nil ? "撰写方案" : "编辑方案") {
                        prepareDiscussionDraft()
                        if !editingPlan { editSavedPlan() }
                    }.buttonStyle(.glass)
                        .disabled(store.changingTasks.contains(task.id) || store.sendingConversations.contains(task.mainConversationID))
                    Spacer()
                    Button("确认方案") { store.confirmRevision(taskID: task.id) }
                        .buttonStyle(KanbanPrimaryButtonStyle())
                        .help("确认当前方案，进入开发并立即开始执行。")
                        .disabled(revision == nil || revision?.confirmedAt != nil || revision?.acceptanceCriteria.isEmpty == true || run != nil || task.phase == .completed || store.changingTasks.contains(task.id) || store.sendingConversations.contains(task.mainConversationID) || store.importingConversations.contains(task.mainConversationID))
                }
            }
        }.padding(24)
    }

    private func prepareDiscussionDraft() {
        guard !editingPlan, !savingPlan, let draft = discussionDraft else { return }
        planText = draft.content
        planSourceMessageID = draft.sourceMessageID; planSourceRunID = draft.sourceRunID
        planSourceDate = draft.createdAt
        planEditToken = UUID(); editingPlan = true
    }

    private func editSavedPlan() {
        planText = revision.map { DiscussionPlanDocument.editingContent(plan: $0.plan, acceptanceCriteria: $0.acceptanceCriteria) } ?? "\n\n## 验收条件\n- "
        planSourceMessageID = revision?.sourceMessageID; planSourceRunID = revision?.sourceRunID
        planSourceDate = nil
        planEditToken = UUID(); editingPlan = true
    }

    private func savePlan() {
        let token = planEditToken
        let content = planText
        let sourceMessageID = planSourceMessageID, sourceRunID = planSourceRunID
        savingPlan = true
        Task {
            do {
                try await store.saveRevision(taskID: task.id, content: content, sourceMessageID: sourceMessageID, sourceRunID: sourceRunID)
                if planEditToken == token { editingPlan = false }
            } catch { store.error = error.localizedDescription }
            if planEditToken == token { savingPlan = false }
        }
    }

    private func documentSection(_ title: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(title).font(.system(size: 14, weight: .semibold)); MarkdownContent(text: content).foregroundStyle(KanbanTheme.muted) }
    }

    private var changes: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("本次变更").font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("刷新") { store.loadChanges(taskID: task.id) }.buttonStyle(.glass).controlSize(.small)
            }
            Text("当前执行目录的 Git 变更；包含已暂存、未暂存和未跟踪文件。").font(.system(size: 12)).foregroundStyle(KanbanTheme.muted)
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(store.selectedTaskDiff.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            .foregroundStyle(line.hasPrefix("+") ? KanbanTheme.green : line.hasPrefix("-") ? KanbanTheme.danger : KanbanTheme.ink)
                            .padding(.horizontal, 10).frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 21)
                            .background(line.hasPrefix("+") ? KanbanTheme.greenSoft : line.hasPrefix("-") ? KanbanTheme.orangeSoft : .clear)
                    }
                }.padding(.vertical, 8)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).contentPanel(radius: 10)
            Text("外部修改会重新核对代码指纹，并使旧验收结果失效。").font(.system(size: 11)).foregroundStyle(KanbanTheme.muted)
        }.padding(24)
    }

    private var acceptance: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("验收报告（可选）").font(.system(size: 16, weight: .semibold))
                Spacer()
                if let report { StatusChip(text: report.stale ? "已过期" : report.passed ? "报告有效" : "有待处理项", color: report.stale || !report.passed ? KanbanTheme.orange : KanbanTheme.green, background: report.stale || !report.passed ? KanbanTheme.orangeSoft : KanbanTheme.greenSoft) }
            }
            if let report {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        MarkdownContent(text: report.summary)
                        HStack(spacing: 10) { Text("版本 \(store.snapshot.revisions.first { $0.id == report.revisionID }?.version ?? 0)"); Text("代码指纹 " + String(report.codeFingerprint.prefix(12))); Text(report.createdAt, style: .time) }.font(.system(size: 11)).foregroundStyle(KanbanTheme.muted)
                        ForEach(report.checks) { check in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: check.passed ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundStyle(check.passed ? KanbanTheme.green : KanbanTheme.orange)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(check.title).font(.system(size: 13, weight: .medium))
                                    Text(check.evidence).font(.system(size: 12)).foregroundStyle(KanbanTheme.muted).textSelection(.enabled)
                                }
                                Spacer(minLength: 0)
                            }.padding(14).contentPanel(radius: 10)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("尚未生成验收报告").font(.system(size: 15, weight: .medium))
                    Text("可直接确认完成，无需生成验收报告。如需报告，可在确认方案并进入验收阶段后运行只读审查，作为参考记录。").font(.system(size: 13)).foregroundStyle(KanbanTheme.muted).lineSpacing(5)
                }.padding(18).background(KanbanTheme.hover, in: RoundedRectangle(cornerRadius: 12))
            }
            Spacer(minLength: 0)
            Divider().overlay(KanbanTheme.line)
            Text("验收报告仅供参考，完成由你手动确认。AI 的建议不会自动移动任务。").font(.system(size: 11)).foregroundStyle(KanbanTheme.muted)
            HStack {
                Button(report == nil ? "生成验收报告" : "重新验收") { store.runAcceptance(taskID: task.id) }.buttonStyle(.glass)
                    .disabled(task.phase != .acceptance || revision?.confirmedAt == nil || revision?.acceptanceCriteria.isEmpty != false || run != nil || store.changingTasks.contains(task.id))
                Spacer()
                Button("确认完成") { store.completeTask(task.id) }.buttonStyle(KanbanPrimaryButtonStyle())
                    .disabled(task.phase == .completed || completionBlocked)
            }
        }.padding(24)
    }
}

private enum DetailTab: String, CaseIterable, Identifiable {
    case chat, plan, changes, acceptance
    var id: String { rawValue }
    var title: String { switch self { case .chat: "主会话"; case .plan: "方案"; case .changes: "变更"; case .acceptance: "验收" } }
}

struct ApprovalCard: View {
    @Bindable var store: AppStore
    let approval: Approval
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) { DesignIcon(name: "imgIconShield", size: 18, color: KanbanTheme.orange); Text(approval.title).font(.system(size: 14, weight: .semibold)); Spacer(); StatusChip(text: "请求批准", color: KanbanTheme.orange, background: KanbanTheme.orangeSoft) }
            Text(approval.detail).font(.system(size: 12)).foregroundStyle(KanbanTheme.muted).lineSpacing(4).textSelection(.enabled)
            HStack {
                if approval.options.contains(where: \.allows) {
                    Button("允许本次") { store.resolveApproval(approval.id, approved: true) }.buttonStyle(KanbanPrimaryButtonStyle())
                }
                if approval.options.contains(where: { !$0.allows }) {
                    Button("拒绝") { store.resolveApproval(approval.id, approved: false) }.buttonStyle(.glass)
                }
                Spacer()
                Text("批准后继续当前运行").font(.system(size: 11)).foregroundStyle(KanbanTheme.muted)
            }
        }.padding(14).background(KanbanTheme.orangeSoft, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(KanbanTheme.line))
    }
}

struct RecoveryCard: View {
    @Bindable var store: AppStore
    let run: RunRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("需要核对运行状态").font(.system(size: 14, weight: .semibold)).foregroundStyle(KanbanTheme.orange)
            Text(run.error ?? "连接中断后无法确认执行器和子任务是否结束；目录写入锁仍保留。").font(.system(size: 12)).foregroundStyle(KanbanTheme.muted).textSelection(.enabled)
            Text("仅停止身份可确认的旧运行；身份不明时保留目录锁，不重放操作。").font(.system(size: 11)).foregroundStyle(KanbanTheme.muted)
            Button("核实并停止旧运行") { store.recoverRun(run.id) }.buttonStyle(.glass)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(KanbanTheme.orangeSoft, in: RoundedRectangle(cornerRadius: 10))
    }
}
