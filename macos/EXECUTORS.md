# 本机执行器实现与验证

2026-10-07。实现位于 `Sources/AgentKanbanExecutors`，验证代码位于 `Tests/AgentKanbanExecutorsTests`。以下区分实际模型运行、协议 fixture 和尚未验证的能力；登录成功不代表模型调用成功。

## 接入与能力来源

| 执行器 | 本次安装版本 | 实际接入 | 认证检测 | 模型目录 |
| --- | --- | --- | --- | --- |
| Codex | 0.160.1 | 独立 `app-server --stdio`，JSON-RPC；Thread 与 Run 分开 | `account/read(refreshToken:false)` | `model/list` 分页，保留精确 ID、合法 effort、真实默认标志 |
| Claude | 2.1.292 | Claude Code CLI 的 `stream-json` 与 stdio 控制协议 | `auth status --json` | 当前 CLI 没有独立账户目录命令；返回带“研究快照、未验证”证据的目录 |
| Cursor | 2026.09.10-fd3934a | 绝对路径 `cursor-agent acp`，ACP v1 | `status --format json` | `models` 返回的原生 Auto、Composer、Grok ID 与真实强度变体 |

Claude 首版使用本机 Claude Code CLI 账户，不额外嵌入 JavaScript Agent SDK 桥接进程。控制封包依据官方 `@anthropic-ai/claude-agent-sdk` 0.3.292 发布包的协议实现及类型定义核对；初始化、`can_use_tool` 宿主答复、单次审批拒绝已通过 fixture。CLI 登录仅证明这条 CLI 接入，不证明另一套独立 SDK 凭证可用。

所有检测不创建业务 Run、不发送模型提示、不读取或打印凭证明文。stderr 独立排空，不进入 JSON 协议和业务日志。Cursor 不使用裸命令 `agent`，避免与机器上的其他 Agent CLI 同名。

`ExecutionSelection` 的 model、effort、permission 为 nil 时表示原生默认。Codex 请求前读取原生配置中的相关公开字段；Cursor 从新建/恢复 ACP 会话读取 currentModelId；Claude 从 init 消息记录实际模型。不会把离线目录第一项当成原生默认。请求快照与实际确认值分别保存，研究目录的 `verified=false` 不等于当前账户支持。

## 权限与只读阶段

| 预设 | Codex | Claude CLI | Cursor CLI |
| --- | --- | --- | --- |
| 请求批准 | workspace-write、on-request、user | manual、严格沙箱、stdio 宿主审批 | sandbox enabled |
| 帮我批准 | workspace-write、on-request、auto_review | auto、严格沙箱、stdio 宿主审批；Haiku 禁用 | sandbox enabled、auto-review |
| 完全访问 | danger-full-access、never | bypassPermissions、sandbox disabled | sandbox disabled、force |

具体权限仍受执行器版本及组织策略约束。未确认的权限不能展示为已生效；不支持的客户端回调被拒绝，审批 ID 只允许答复一次。Codex 请求任意额外文件/网络范围时，当前 UI 仅允许拒绝，`allowsApproval=false`。

讨论、验收阶段额外使用 `/usr/bin/sandbox-exec` 的宿主 Seatbelt 文件写入拒绝边界，运行时状态与临时目录例外只在项目之外；项目路径上的最终 deny 规则覆盖这些例外，子进程继承同一边界。fixture 已真实证明 shell 及其 child 不能改写项目文件，包括项目位于临时目录的情况。隔离不可用时不退回仅提示词只读。

macOS 无法在该外层 Seatbelt 内再初始化 Codex 的嵌套 sandbox-exec。真实联调曾出现工具 sandbox access denied，故只读 Thread 使用 danger-full-access **接入模式**，Turn 明确声明 externalSandbox，实际文件写入隔离由外层 Seatbelt 执行。模型连接仍允许网络，不能将该实现称为网络隔离或全面禁止外部副作用。实际策略记录为“宿主 Seatbelt 只读 · externalSandbox · 原生网络连接 · never”。

只读 Codex 开启 native multi_agent，开发写入阶段关闭 multi_agent/multi_agent_v2，避免内部第二写入者。Codex 原生 `subAgentActivity`/collab 项归属同一 Run，完成子 Thread 的摘要只通过 `thread/read` 读取，必须确认 parentThreadId；不提交新 prompt。

只读 Claude 仅开放 Read/Glob/Grep 与固定 `readonly_analyst` 角色的 Agent，子角色工具限定 Read/Glob/Grep。真实初始化发现 `--safe-mode` 会忽略命令行 `--agents`，现改为 `initialize.agents` 注册 SDK 所有的角色；必须确认返回角色和 `hooks_applied=true` 后才发送用户提示。宿主 PreToolUse hook 拒绝其他角色、remote/worktree isolation 和写入阶段委派，并将合法调用限定为本地前台执行。写入阶段同时禁用 Agent/Task。OS 文件写入拒绝独立于角色提示词。

Claude 的 `task_id` 为稳定子任务标识，`run_id` 区分恢复轮次，父 `tool_use_id` 关联实际 Agent 调用。转发子文本不进入主回复；前台最终摘要取 `user.tool_use_result.content`。早到的父结果暂存，等待已知子任务终态；空后台快照不能冒充完成，迟到旧轮次也不能复活已完成子任务。真实委派、子任务启动后取消及摘要归属已通过，证据见 [claude-delegation.json](validation/claude-delegation.json)。首版不提供子任务独立停止，停止主 Run 会停止受管子任务。

## 进程、取消与恢复

- `posix_spawn + POSIX_SPAWN_SETPGROUP` 原子创建独立进程组，并重置继承的信号屏蔽。保存内核查询的 PID、PGID、真实出生时间，不使用 Date.now 猜出生时间；无法读取身份时直接停止新进程。
- `ExecutorRequest.identityRecorder` 在 spawn 后、协议初始化/任何业务 prompt 前等待生产数据库持久化；失败先停止进程组，禁止发送请求。fixture 已验证数据库失败不会发送 initialize 或 prompt。
- 协议取消分别使用 Codex turn/interrupt、Cursor session/cancel；随后核实受管理组已空。协议失联时使用已核实的组 TERM/KILL 作为停止屏障。Claude 使用同一进程组屏障。仅收到取消请求、管道 EOF 或父进程退出都不能释放目录租约。
- 完成收尾与并发取消等待同一停止屏障；终态发出前再次检查取消标记，避免取消被记成成功。应用忽略已终态 Run 的迟到回复与子事件，不向新阶段追加旧回复；停止前的子任务日志保留。
- 新 Registry 找不到旧 handle 时 `cancel` 返回 unknown。`verifyRecovery` 只读核对：原 PID 仍存在、身份不符、缺少出生时间、旧组仍有成员均保持阻塞。原 PID 和整个旧组均不存在才确认停止。
- 用户显式恢复停止调用 `stopRecovered`，要求旧 PID 的出生时间在 1 微秒浮点往返容差内匹配且 PGID 等于该 PID，才向旧组 TERM，必要时 KILL；全部组成员消失才返回 confirmed。PID 复用、身份缺失不会发信号。
- 进程组管理覆盖正常继承组的原生工具与子进程，不把主动脱离进程组的 daemon 或外部服务称为已回收。跨应用 IPC 与第三方后台服务需要单独的能力策略；无法核实的残留必须保持 recoveryRequired。首版不自动重连模型生成、不重放写请求。

## 实际验证结果

证据摘要见 `validation/executors.json`。真实模型仅在独立临时 Git 仓库使用 README fixture，退出后移除临时目录，没有写用户项目或发起外部写操作。

| 场景 | 结果 | 实际模型 / 耗时 |
| --- | --- | --- |
| Codex 只读 README | 通过，原生 commandExecution 读取正确 phrase；核实组为空 | gpt-6.1-sol / 22.284 秒 |
| Claude 只读 README | 通过，Read 读取正确 phrase；核实组为空 | claude-opus-5-5 / 9.47 秒 |
| Cursor 只读 README | **受账户套餐阻断，未通过模型任务** | grok-4.6[effort=high,fast=true] / 6.49 秒；必要复验 8.09 秒 |
| Codex 工具开始后取消 | 通过，cancel confirmed、cancelled 事件、原 PID 消失 | 8.036 秒 |
| Codex 只读独立子 Agent | 通过，原生 started→completed 摘要归属正确；关闭后核实组为空。首次发现生命周期遗漏后修正复验 | gpt-6.1-sol / 23.303 秒 |
| Claude 只读独立子 Agent | 通过，子角色独立 Read；稳定 ID、父工具归属与结构化摘要正确，主回复只含校验值，Git 指纹未变，进程组清空 | claude-opus-5-5 / 24.459 秒 |
| Claude 子 Agent 启动后取消 | 通过，原生 local_agent running 后取消，confirmed + cancelled；没有 completed，Git 指纹未变，进程组清空 | claude-opus-5-5 / 最终直连复验 29.195 秒（首次带协议采集 34.431 秒） |

本机 Cursor 该版本 `7214.index.js/processPrompt` 将后端 action error 的 login/upgrade/payment/config 映射为四个固定 agent_message_chunk 文本帧，随后仍返回 `end_turn`，没有 JSON-RPC error。为避免将套餐错误记为成功，仅对此精确 CLI 版本及精确常量帧做失败映射；不会根据任意自然语言推断成功/失败，其他版本的协议变化仍需重新验证。源文件为本机安装包代码，仅核对控制路径，不读取账户配置。

默认测试均不产生模型请求。执行器测试共 36 项通过、6 个 opt-in 默认跳过；另外 2 项 AppStore 测试验证子日志持久化、主回复分离及阶段停止屏障。完整默认套件见 [VALIDATION.md](VALIDATION.md)。执行 `swift test --package-path macos --filter 'ExecutorTests|Claude'`；真实探针与模型联调必须显式设置以下环境开关并使用对应 filter：

```text
AGENT_KANBAN_READ_ONLY_PROBES=1       optionalInstalledExecutorAuthenticationAndCatalogProbe
AGENT_KANBAN_REAL_READONLY_RUNS=1    optionalActualReadonlyExecutorRunsInTemporaryRepository
AGENT_KANBAN_REAL_CODEX_CANCEL=1     optionalActualCodexCancellation
AGENT_KANBAN_REAL_READONLY_DELEGATE=1 optionalActualCodexReadonlyDelegation
AGENT_KANBAN_REAL_CLAUDE_DELEGATE=1  optionalActualClaudeReadonlyDelegation
AGENT_KANBAN_REAL_CLAUDE_CANCEL=1    optionalActualClaudeChildCancellation
```

模型请求会使用本机账户额度。真实请求默认关闭，日常构建或测试不会隐式触发。
