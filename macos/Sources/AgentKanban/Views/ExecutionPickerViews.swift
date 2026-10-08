import SwiftUI
import AgentKanbanCore
import AgentKanbanExecutors

struct ModelReasoningPicker: View {
    @Bindable var store: AppStore
    @State private var selection: ExecutionSelection
    @State private var modelList = false
    init(store: AppStore, initial: ExecutionSelection) { self.store = store; _selection = State(initialValue: initial) }
    private var catalog: [ExecutorModel] { store.catalogs[selection.executor] ?? [] }
    private var model: ExecutorModel? { catalog.first { $0.id == selection.modelID } }

    var body: some View {
        Group {
            if modelList { models }
            else { reasoning }
        }
        .frame(width: 344).padding(18).foregroundStyle(KanbanTheme.ink)
        .onChange(of: selection) { _, value in store.updateSelection(value) }
        .onKeyPress(.escape) { if modelList { modelList = false; return .handled }; return .ignored }
    }

    private var reasoning: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top) {
                DesignIcon(name: "imgReasoningBolt", size: 22, color: KanbanTheme.effort(selection.effort)).padding(.top, 6)
                Spacer()
                Button { modelList = true } label: {
                    VStack(spacing: 5) {
                        Text(effortTitle(selection.effort)).font(.system(size: 18, weight: .medium)).foregroundStyle(KanbanTheme.effort(selection.effort))
                        HStack(spacing: 5) {
                            Text(model?.displayName ?? selection.modelID ?? "执行器默认模型").font(.system(size: 12)).lineLimit(1)
                            DesignIcon(name: "imgIconChevron", size: 10)
                        }.foregroundStyle(KanbanTheme.muted)
                    }.padding(.horizontal, 12).padding(.vertical, 4).contentShape(RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).help("选择执行器和模型")
                Spacer()
                Button { selection.effort = nil } label: { DesignIcon(name: "imgIconReset", size: 19) }
                    .buttonStyle(.plain).help("恢复执行器默认推理强度").padding(.top, 6)
            }
            EffortSlider(values: model?.efforts ?? [], selection: $selection.effort)
                .disabled(model == nil || model?.efforts.isEmpty != false)
            if model == nil {
                Text("使用执行器的默认模型。点击模型名称后可选择具体版本。")
                    .font(.system(size: 11)).foregroundStyle(KanbanTheme.muted).frame(maxWidth: .infinity, alignment: .leading)
            } else if model?.efforts.isEmpty == true {
                Text("此模型不提供独立的推理强度设置。")
                    .font(.system(size: 11)).foregroundStyle(KanbanTheme.muted).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var models: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button { modelList = false } label: { Text("返回").font(.system(size: 12)) }.buttonStyle(.glass).controlSize(.small)
                Text("选择模型").font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            HStack(spacing: 4) {
                ForEach(ExecutorID.allCases) { executor in
                    Button { switchExecutor(executor) } label: {
                        Text(executor.title).font(.system(size: 13, weight: .medium))
                            .foregroundStyle(selection.executor == executor ? KanbanTheme.blue : KanbanTheme.muted)
                            .frame(maxWidth: .infinity).frame(height: 30)
                            .background(selection.executor == executor ? KanbanTheme.panel : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).accessibilityLabel(executor.title)
                        .accessibilityAddTraits(selection.executor == executor ? .isSelected : [])
                }
            }.padding(4).background(KanbanTheme.hover, in: RoundedRectangle(cornerRadius: 12))
            Text("模型").font(.system(size: 11)).foregroundStyle(KanbanTheme.muted).padding(.top, 3)
            ScrollView {
                VStack(spacing: 3) {
                    modelRow("执行器默认模型", selected: selection.modelID == nil) { selection.modelID = nil; selection.effort = nil; modelList = false }
                    ForEach(catalog) { model in
                        modelRow(model.displayName, selected: selection.modelID == model.id) {
                            selection.modelID = model.id
                            if let effort = selection.effort, !model.efforts.contains(effort) { selection.effort = nil }
                            modelList = false
                        }.help(model.id + "\n" + model.evidence)
                    }
                }
            }.frame(height: min(320, CGFloat(catalog.count + 1) * 37)).scrollIndicators(.hidden)
            Text(catalog.allSatisfy(\.verified) && !catalog.isEmpty ? "来自当前执行器的模型目录。" : "版本来自研究快照；运行前由执行器核验账户可用性。")
                .font(.system(size: 11)).foregroundStyle(KanbanTheme.muted)
        }
    }

    private func modelRow(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 13))
                Spacer()
                if selected { DesignIcon(name: "imgIconCheck", size: 16, color: KanbanTheme.blue) }
            }.foregroundStyle(selected ? KanbanTheme.blue : KanbanTheme.ink).padding(.horizontal, 10).frame(height: 34)
                .background(selected ? KanbanTheme.blueSoft : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }

    private func switchExecutor(_ executor: ExecutorID) {
        let chat = store.snapshot.conversations.first { $0.id == store.selectedConversationID }
        selection = chat?.savedSelections[executor] ?? ExecutionSelection(executor: executor)
    }
}

private struct EffortSlider: View {
    let values: [String]
    @Binding var selection: String?
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var index: Int { values.firstIndex(of: selection ?? "") ?? 0 }
    private var color: Color { isEnabled ? KanbanTheme.effort(selection) : KanbanTheme.muted }

    var body: some View {
        GeometryReader { geometry in
            let travel = max(1, geometry.size.width - 36)
            let progress = CGFloat(index) / CGFloat(max(1, values.count - 1))
            ZStack(alignment: .leading) {
                Capsule().fill(isEnabled ? AnyShapeStyle(LinearGradient(colors: [color.opacity(0.9), color.opacity(0.7), color], startPoint: .leading, endPoint: .trailing)) : AnyShapeStyle(KanbanTheme.line))
                if isEnabled {
                    Canvas { context, size in
                        for index in 0..<23 {
                            let x = CGFloat((index * 47 + 17) % 359) / 359 * size.width
                            let y = CGFloat((index * 13 + 7) % 28) + 4
                            let side: CGFloat = index % 5 == 0 ? 2.5 : 1.7
                            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: side, height: side)), with: .color(.white.opacity(index % 3 == 0 ? 0.58 : 0.3)))
                        }
                    }.clipShape(Capsule()).allowsHitTesting(false)
                }
                Circle().fill(.white).frame(width: 34, height: 34)
                    .shadow(color: .black.opacity(0.08), radius: 2, y: 1).offset(x: 1 + travel * progress)
            }
            .contentShape(Capsule())
            .overlay(Capsule().strokeBorder(focused ? KanbanTheme.blue : .clear, lineWidth: 2).padding(-3))
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard isEnabled, !values.isEmpty else { return }
                focused = true
                let fraction = min(1, max(0, (value.location.x - 18) / travel))
                selection = values[Int((fraction * CGFloat(values.count - 1)).rounded())]
            })
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: index)
        }.frame(height: 36).focusable(isEnabled).focused($focused).focusEffectDisabled()
            .onKeyPress(.leftArrow) { step(-1); return .handled }
            .onKeyPress(.downArrow) { step(-1); return .handled }
            .onKeyPress(.rightArrow) { step(1); return .handled }
            .onKeyPress(.upArrow) { step(1); return .handled }
            .onKeyPress(.home) { if let first = values.first { selection = first }; return .handled }
            .onKeyPress(.end) { if let last = values.last { selection = last }; return .handled }
            .accessibilityElement().accessibilityLabel("推理强度").accessibilityValue(isEnabled ? effortTitle(selection) : "不可设置")
            .accessibilityAdjustableAction { direction in switch direction { case .increment: step(1); case .decrement: step(-1); @unknown default: break } }
    }
    private func step(_ amount: Int) { guard isEnabled, !values.isEmpty else { return }; selection = values[min(values.count - 1, max(0, index + amount))] }
}

struct PermissionPicker: View {
    @Bindable var store: AppStore
    var selection: ExecutionSelection
    let change: (ExecutionSelection) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("应如何批准操作？").font(.system(size: 15, weight: .semibold)).padding(.bottom, 6)
            ForEach(PermissionPreset.allCases) { preset in
                Button {
                    var next = selection; next.permission = preset; change(next)
                } label: {
                    HStack(spacing: 12) {
                        DesignIcon(name: preset == .fullAccess ? "imgIconUnlock" : preset == .autoReview ? "imgIconAgent" : "imgIconShield", size: 22, color: preset == .fullAccess ? KanbanTheme.orange : KanbanTheme.muted)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(preset.title).font(.system(size: 15, weight: .semibold))
                            Text(store.permissionUnavailableReason(preset, executor: selection.executor) ?? description(preset)).font(.system(size: 12)).foregroundStyle(KanbanTheme.muted).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if selection.permission == preset { DesignIcon(name: "imgIconCheck", size: 16, color: preset == .fullAccess ? KanbanTheme.orange : KanbanTheme.blue) }
                    }.foregroundStyle(preset == .fullAccess ? KanbanTheme.orange : KanbanTheme.ink)
                        .padding(12).frame(minHeight: 76)
                        .background(selection.permission == preset ? (preset == .fullAccess ? KanbanTheme.orangeSoft : KanbanTheme.blueSoft) : .clear, in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).disabled(store.permissionUnavailableReason(preset, executor: selection.executor) != nil)
            }
            Divider().overlay(KanbanTheme.line)
            if selection.permission == nil { Text("当前使用执行器默认权限").font(.system(size: 12)).foregroundStyle(KanbanTheme.muted) }
            Text("权限与当前执行器保持一致。具体可用性在启动时核验，已有运行保留权限快照。")
                .font(.system(size: 11)).foregroundStyle(KanbanTheme.muted).fixedSize(horizontal: false, vertical: true)
        }.padding(18).frame(width: 434)
    }
    private func description(_ preset: PermissionPreset) -> String {
        switch preset {
        case .requestApproval: "保持执行器沙箱，越界操作请求你批准。"
        case .autoReview: "在沙箱内执行，由执行器评估审批请求。"
        case .fullAccess: "关闭执行沙箱，审批不再询问。"
        }
    }
}
