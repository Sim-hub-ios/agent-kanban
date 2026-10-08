# 原生客户端验证记录

2026-10-08 AK-003 方案确认后的开发启动流程：原子确认、进入开发并立即预留运行；完整默认测试、应用构建和签名校验通过。复现、实际变更、首次全量测试中的等待用例调整和未验证边界见 [专项记录](validation/plan-confirmation-20261008/RESULT.md)。本次仅开发验证，未补写验收条件或移动生产任务阶段。

验证日期：2026-10-07。环境：macOS 26.6.2 / arm64、Xcode 26.3、Swift 6.2.4、macOS SDK 26.2。最低部署版本 26.0。

## 构建与自动测试

```sh
swift test --package-path macos
xcodebuild -quiet -project macos/AgentKanban.xcodeproj -scheme AgentKanban \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath macos/build/Xcode CODE_SIGNING_ALLOWED=NO build
./macos/scripts/build-app.sh debug
```

SwiftPM 与 Xcode 原生应用构建均已通过。最终默认测试 **88 项通过、0 失败**（16 项 XCTest + 72 项 Swift Testing），另有 8 项联网/模型联调用例默认跳过。结果见 [swift-test.log](validation/swift-test.log)；显式真实联调结果另列，不把跳过算作通过。重点覆盖：

- 事务创建任务和主会话、原生默认配置、零 Run 待处理备注、持久化重开、项目规范路径去重与移除后重新导入。
- 单目录写入竞争，包括两个 SQLite 连接、只读审查与写入互斥、目录身份改变、阶段停止屏障、重启后未知运行保锁。
- 审批单次归属、停止后旧审批失效、多审批等待、冻结的 Run 配置不随 UI 修改。
- Git 指纹包含 HEAD、已暂存、未暂存、未跟踪内容与递归子模块；代码变化失效、报告定点作废、取消后的迟到报告拒绝、来源 Run 未成功不能人工完成。
- 真实 ZIP/XLSX 共享字符串及内联字符串解析、多行 CSV、坏行反馈、来源读取失败整批不提交、同标题不同任务不误合并、稳定 ID 按原始来源区分、严格 Issue URL 范围。
- 聊天导入采用项目默认值、“添加到任务看板”自然指令、来源与指令分消息提供、登录后继续原请求、重复继续的稳定操作 ID、替换旧来源、成功/取消/无关请求结束上下文、助手与跨会话来源排除、缺少来源不提交空批次、旧附件字段兼容、重试去重、导入已提交但回执未发时重启补投且只投一次。
- GitHub 仓库根链接只在明确 Issue 导入下解析；URL / q / 自然语言受理人筛选、@me 身份解析、分页保留范围、单 Issue 筛选核对、冲突或未知筛选拒绝、身份失败不得退回全仓库。
- JSON-RPC 分帧和大小上限、真实 Cursor 目录变体、不可伪造默认/认证、Claude 拒绝回原请求、宿主只读子进程写入拒绝、进程组停止、出生身份不匹配禁止恢复杀进程、进程身份记录失败时不得发送业务提示。
- Claude SDK 只读角色和宿主 hook 必须先确认、拒绝远端/工作树/其他角色、子文本与主回复分离、结构化摘要持久化、旧轮次过滤、空背景列表及早到父结果不能提前完成、并发完成与取消共用停止屏障、已取消运行忽略迟到回复。

## 真实执行器与完整流程

所有模型联调只访问自动创建的一次性临时 Git 仓库，没有在用户项目运行开发任务。

2026-10-07 聊天导入缺陷验证：首先用 AppStore 原句回归复现任务数/批次数为 0 且误调用模型；修复后该测试通过。按用户原有导入授权，在原项目会话中通过 AppStore → ImportReader → Repository 事务补回 1 个已指派的开放 Issue，状态为待处理，并生成原会话回执；再次执行同一请求新增 0 项、批次和回执各保持 1 条。真实来源使用现有 gh 登录只读访问，未修改远端 Issue 或项目代码。更新应用后，已在原生看板实际核对任务 AK-001 显示于待处理列。一次性修复 harness 已删除，默认测试继续使用临时数据库与离线 API fixture。

| 检查 | 实际结果 |
| --- | --- |
| Codex 0.160.1 认证与目录 | 只读检查通过，目录来自当前账户，未建立业务 Run |
| Claude Code 2.1.292 认证 | 只读检查通过，使用现有本机登录 |
| Cursor Agent 2026.09.10-fd3934a 认证/ACP | 只读检查、ACP 握手和原生默认模型解析通过 |
| Codex 真实只读工具 | `gpt-6.1-sol` 读取临时 README，返回预置校验值；宿主只读限制保持生效 |
| Claude 真实只读工具 | 原生默认 `claude-opus-5-5` 读取同类临时 README，返回预置校验值 |
| Cursor 真实模型请求 | 当前原生默认 Grok 4.6 Fast 返回套餐升级错误，已映射失败；不能计为模型任务通过 |
| Codex 工具执行中取消 | 原生中断加受管进程组收尾，确认进程组清空 |
| Codex 只读独立子 Agent | 23.303 秒修正复验通过，真实子 Thread 生命周期、摘要及 parentThreadId 归属正确，关闭后进程组清空 |
| Claude 只读独立子 Agent | 24.459 秒通过，原生默认 `claude-opus-5-5`，子 Agent 独立读取随机校验值；最终摘要、稳定子 ID 与父工具归属正确，仓库指纹未变 |
| Claude 子 Agent 启动后取消 | 最终直连复验 29.195 秒通过；confirmed + cancelled、没有 completed，Git 指纹未变，原生 CLI 及受管组清空（首次带协议采集 34.431 秒） |
| 原生 AppStore 完整任务链 | 54.097 秒通过：开发写 `ready.txt` → 实际读取校验 → 人工进入验收 → 只读逐项报告 → 指纹/需求/来源 Run 绑定 → 人工确认完成 |
| GitHub Issue 来源 | 实际只读读取 `microsoft/vscode#1` 通过；未修改远端 Issue |

完整流程证据：[real-app-flow.json](validation/real-app-flow.json)。Claude 子 Agent 真实联调证据：[claude-delegation.json](validation/claude-delegation.json)，模型请求使用独立临时仓库；AppStore 的摘要持久化和阶段切换另由可控事件测试覆盖，没有将其写成真实 UI 人工验收。执行器协议、只读委派、取消、恢复的详细证据与边界见 [EXECUTORS.md](EXECUTORS.md)。

显式联调命令：

```sh
AGENT_KANBAN_REAL_APP_FLOW=1 swift test --package-path macos --filter NativeEndToEndTests
AGENT_KANBAN_PUBLIC_ISSUE_PROBE=1 swift test --package-path macos --filter optionalPublicGitHubIssueSource
AGENT_KANBAN_READ_ONLY_PROBES=1 swift test --package-path macos --filter optionalInstalledExecutorAuthenticationAndCatalogProbe
AGENT_KANBAN_REAL_READONLY_RUNS=1 swift test --package-path macos --filter optionalActualReadonlyExecutorRunsInTemporaryRepository
AGENT_KANBAN_REAL_CODEX_CANCEL=1 swift test --package-path macos --filter optionalActualCodexCancellation
AGENT_KANBAN_REAL_READONLY_DELEGATE=1 swift test --package-path macos --filter optionalActualCodexReadonlyDelegation
AGENT_KANBAN_REAL_CLAUDE_DELEGATE=1 swift test --package-path macos --filter optionalActualClaudeReadonlyDelegation
AGENT_KANBAN_REAL_CLAUDE_CANCEL=1 swift test --package-path macos --filter optionalActualClaudeChildCancellation
```

模型联调会使用当前官方 CLI 的账户配额；默认单元测试不会自动运行这些请求。Cursor 套餐限制未解除前，三执行器联合只读用例会如实失败。

## 原生界面核对

对照 Figma 的实际节点、组件资源和 1440 × 900 基准核对。使用独立数据目录 `/tmp/agent-kanban-native-visual-20261007` 与一次性 UI 仓库。没有把设计示例任务预置为正式工作空间数据。

- 首次空态、本地项目导入、项目树与项目普通会话。
- 四字段新建任务、多行输入及保存换行、待处理备注保存后仍为零运行。
- 模型入口 → 紧凑面板 → 二级列表 → 返回；Home/End、重置及低/Ultra 强度颜色。
- “运行中”侧栏角标、列表、详情和事件共用未终结运行范围；移除已完成筛选与时间范围，结束的运行保留持久化证据。已在当前项目实际核对：4 条历史记录、0 条活动运行时，侧栏为“运行中 0”，列表和最近事件均无历史内容。
- 权限菜单只有三项预设，认证弹窗真实状态，移除确认。
- 修正原生 Menu 标签被系统样式吞掉、Popover 列表高度、顶部 safe area、多余 composer 高度等实际渲染差异。

截图位于 [validation/screenshots](validation/screenshots)。截图可能包含系统屏幕控制提示；该提示不是应用 UI。系统 Liquid Glass 的反射、窗口活跃/失活状态会随 macOS 环境变化，静态 Figma 图片不能代表这些动态系统行为。

## FR 实现追踪

| PRD | 实现与证据 |
| --- | --- |
| FR-01/02/03 | 看板、四字段任务、多行备注、独立主会话及版本/运行持久化；Core/AppStore 测试、原生截图 |
| FR-04 | 模型两级面板、按执行器保存、能力驱动强度/颜色、冻结配置；UI 核对、快照测试、真实目录 |
| FR-05/06/07 | 停止屏障、项目目录固定、跨项目并行、唯一写入者、宿主/原生执行隔离；竞争测试、真实取消、只读写入拒绝 |
| FR-08/09 | 方案确认/版本、代码指纹、逐项报告、人控完成；Core 测试、真实端到端 |
| FR-10 | 项目下普通会话，可直接读改代码；共用目录锁与执行器配置 |
| FR-11 | 仅只读保护下开放可观测的内部分析/审查；写入阶段禁止内部委派。真实验证范围见执行器记录 |
| FR-12 | Codex app-server、Claude 官方 CLI 控制协议、Cursor ACP 三个 Adapter；Cursor 模型账户存在外部阻断 |
| FR-13/14 | 审批归属、拒绝、异常恢复、出生身份校验与进程组停止；协议 fixture、恢复/真实取消证据 |
| FR-15 | Git 项目导入/去重/忙碌移除保护/空状态；Core 测试、原生确认弹窗 |
| FR-16 | 会话内 Skill 直接读取表格/Issue 并幂等创建任务；真实 XLSX、公有 Issue、聊天事务测试 |
| FR-17/18 | 全局认证检查、原生权限三预设、未知值不勾选、每次运行前验证；只读探针、UI 和映射测试 |

## 仍需区分的验证边界

- Cursor 账户套餐阻断没有通过更换模型掩盖。认证/协议成功与模型任务成功分开记录。
- 宿主 Seatbelt 已验证文件写入拒绝；没有宣称它隔离网络。开发/普通会话的网络和文件能力沿所选原生权限。
- Claude 自动批准预设因模型/组织能力未验证而禁用。Cursor 内部子任务不承诺独立停止或独立写入安全能力。
- 重启恢复禁止自动重放。只有实际进程出生身份吻合才允许停止旧进程；身份未知、复用或进程组未清空继续保锁。
- GitHub 当前账户指定仓库的受理人范围已实测；其他组织权限场景、万条级导入、大型仓库性能、VoiceOver/减少透明度完整人工验收，以及开发者签名、公证分发尚未逐项验证。
- 完成任务不会自动提交、合并或发布代码，保留用户决定。
