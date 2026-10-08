import SwiftUI
import AgentKanbanCore

struct RunHistoryView: View {
    @Bindable var store: AppStore
    @State private var selectedRun: String?
    @State private var filter: RunFilter = .all
    private var runs: [RunRecord] {
        store.activeRuns.filter { filter.matches($0.status) }.sorted { $0.createdAt > $1.createdAt }
    }
    private var run: RunRecord? { runs.first { $0.id == selectedRun } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("运行中").font(.system(size: 24, weight: .semibold))
                    Text("查看所有项目的排队、运行、审批与恢复状态。").font(.system(size: 13)).foregroundStyle(KanbanTheme.muted)
                }
                HStack(spacing: 10) {
                    ForEach(RunFilter.allCases) { item in
                        Button { filter = item } label: {
                            Text(item.title).font(.system(size: 13, weight: .medium)).frame(width: 88, height: 36)
                                .foregroundStyle(filter == item ? .white : KanbanTheme.muted)
                        }.buttonStyle(.plain)
                            .background(filter == item ? KanbanTheme.blue : .clear, in: Capsule())
                            .glassEffect(.regular.interactive(), in: Capsule())
                    }
                    Spacer()
                }
                Table(runs, selection: $selectedRun) {
                    TableColumn("运行") { row in Text(String(row.id.prefix(8))).font(.system(size: 12)) }.width(90)
                    TableColumn("项目") { row in
                        Text(projectName(row.projectID)).font(.system(size: 12)).lineLimit(1)
                            .help(projectPath(row.projectID))
                    }.width(min: 90, ideal: 110)
                    TableColumn("任务 / 会话") { row in Text(runTitle(row)).font(.system(size: 12)).lineLimit(1) }.width(min: 140, ideal: 200)
                    TableColumn("阶段") { row in Text(row.phase?.title ?? "项目会话").font(.system(size: 12)) }.width(75)
                    TableColumn("执行器 / 模型") { row in
                        HStack(spacing: 6) { ExecutorIcon(executor: row.selection.executor, size: 15); Text(row.selection.executor.title + " · " + (row.effectiveModelID ?? row.selection.modelID ?? "默认模型")).font(.system(size: 12)).lineLimit(1) }
                    }.width(min: 170, ideal: 210)
                    TableColumn("状态") { row in Text(row.status.title).font(.system(size: 12)).foregroundStyle(row.status.color) }.width(95)
                    TableColumn("子运行") { row in
                        Text(childSummary(row)).font(.system(size: 12))
                    }.width(90)
                    TableColumn("用时") { row in Text(duration(row)).font(.system(size: 12, design: .monospaced)) }.width(65)
                }.tableStyle(.inset).frame(height: max(146, min(360, CGFloat(runs.count) * 72 + 44)))
                    .contentPanel(radius: 16)
                    .overlay { if runs.isEmpty { Text(filter == .all ? "暂无正在运行的任务或项目会话" : "暂无符合筛选条件的运行").font(.system(size: 13)).foregroundStyle(KanbanTheme.muted).padding(.top, 36) } }
                if let run { runDetails(run) }
                VStack(alignment: .leading, spacing: 20) {
                    Text("最近事件").font(.system(size: 16, weight: .semibold))
                    let events = store.activeRunEvents.sorted { $0.createdAt > $1.createdAt }.prefix(8)
                    if events.isEmpty { Text("运行过程中的事件与子 Agent 摘要会显示在这里。").font(.system(size: 12)).foregroundStyle(KanbanTheme.muted) }
                    ForEach(Array(events)) { event in
                        HStack(alignment: .top, spacing: 16) {
                            Text(event.createdAt, style: .time).font(.system(size: 12)).foregroundStyle(KanbanTheme.muted).frame(width: 50, alignment: .leading)
                            Circle().fill(KanbanTheme.blue).frame(width: 9, height: 9).padding(.top, 5)
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Text(event.kind).font(.system(size: 13, weight: .medium))
                                    Text(projectName(event.projectID)).font(.system(size: 11)).foregroundStyle(KanbanTheme.muted)
                                        .lineLimit(1).help(projectPath(event.projectID))
                                }
                                Text(String(event.runID.prefix(8)) + " · " + event.content).font(.system(size: 12)).foregroundStyle(KanbanTheme.muted).lineLimit(3).textSelection(.enabled)
                            }
                            Spacer()
                        }
                    }
                }.padding(20).frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading).background(KanbanTheme.panel, in: RoundedRectangle(cornerRadius: 16))
                Spacer(minLength: 0)
            }.padding(28)
        }.background(KanbanTheme.background)
            .onChange(of: runs.map(\.id)) { _, ids in
                if let selectedRun, !ids.contains(selectedRun) { self.selectedRun = nil }
            }
    }
    private func runDetails(_ run: RunRecord) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(runTitle(run)).font(.system(size: 15, weight: .semibold)); Spacer(); Button("收起") { selectedRun = nil }.buttonStyle(.glass).controlSize(.small) }
            HStack(spacing: 6) {
                DesignIcon(name: "imgIconFolder", size: 14, color: KanbanTheme.blue)
                Text(projectName(run.projectID)).font(.system(size: 12, weight: .medium))
            }.help(projectPath(run.projectID))
            Text(run.prompt).font(.system(size: 12)).foregroundStyle(KanbanTheme.muted).lineLimit(5).textSelection(.enabled)
            HStack(spacing: 12) { Text("目录 " + abbreviatedPath(run.cwd)); Text("强度 " + effortTitle(run.selection.effort)) }.font(.system(size: 11)).foregroundStyle(KanbanTheme.muted)
            Text("实际权限：" + (run.effectivePolicy ?? "尚未确认")).font(.system(size: 11)).foregroundStyle(KanbanTheme.muted).textSelection(.enabled)
            if run.status == .queued {
                Text("排队中，目录可用后自动开始").font(.system(size: 12, weight: .medium)).foregroundStyle(KanbanTheme.orange)
            }
            if let error = run.error { Text(error).font(.system(size: 12)).foregroundStyle(KanbanTheme.orange).textSelection(.enabled) }
            ForEach(store.snapshot.approvals.filter { $0.runID == run.id && $0.status == .pending }) { approval in ApprovalCard(store: store, approval: approval) }
            if run.status == .recoveryRequired { RecoveryCard(store: store, run: run) }
            if !run.output.isEmpty { MarkdownContent(text: run.output) }
            HStack {
                Button("打开会话") { store.selectConversation(run.conversationID) }.buttonStyle(.glass)
                Spacer()
                if !run.status.isTerminal {
                    Button(run.status == .queued ? "取消排队" : "停止运行") { store.stopRun(run.id) }
                        .buttonStyle(.glass).disabled(run.status == .cancelling)
                }
            }
        }.padding(18).contentPanel(radius: 14)
    }
    private func childSummary(_ run: RunRecord) -> String {
        let children = store.snapshot.runs.filter { $0.parentRunID == run.id }
        var ended: [String: Bool] = [:]
        for child in children { ended[child.executorSessionID ?? child.id] = child.status.isTerminal }
        for agent in AgentActivity.latest(events: store.snapshot.events, runID: run.id) { ended[agent.id] = agent.isTerminal }
        return ended.isEmpty ? "—" : "\(ended.values.filter { $0 }.count) / \(ended.count) 已结束"
    }
    private func duration(_ run: RunRecord) -> String {
        if run.status == .queued { return "等待中" }
        let interval = Int((run.endedAt ?? .now).timeIntervalSince(run.createdAt))
        return String(format: "%02d:%02d", max(0, interval) / 60, max(0, interval) % 60)
    }
    private func runTitle(_ run: RunRecord) -> String {
        if let task = store.snapshot.tasks.first(where: { $0.id == run.taskID }) { return task.displayID + " · " + task.title }
        return store.snapshot.conversations.first { $0.id == run.conversationID }?.title ?? "项目会话"
    }
    private func projectName(_ id: String) -> String {
        store.snapshot.projects.first { $0.id == id }?.name ?? "未知项目"
    }
    private func projectPath(_ id: String) -> String {
        store.snapshot.projects.first { $0.id == id }.map { abbreviatedPath($0.path) } ?? id
    }
 }

private enum RunFilter: String, CaseIterable, Identifiable {
    case all, queued, running, waiting, recovery
    var id: String { rawValue }
    var title: String { switch self { case .all: "全部"; case .queued: "排队中"; case .running: "执行中"; case .waiting: "待审批"; case .recovery: "待恢复" } }
    func matches(_ status: RunStatus) -> Bool {
        switch self {
        case .all: !status.isTerminal
        case .queued: status == .queued
        case .running: !status.isTerminal && status != .queued && status != .waitingApproval && status != .recoveryRequired
        case .waiting: status == .waitingApproval
        case .recovery: status == .recoveryRequired
        }
    }
}
