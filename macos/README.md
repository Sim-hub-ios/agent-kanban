# Agent Kanban · macOS 客户端

最低 macOS 26.0，Swift 6.2 / SwiftUI。本目录是根据 [PRD](../docs/product/prd.html)、[系统设计](../docs/product/design.html) 和 [Figma 设计稿](https://www.figma.com/design/hlTAkqk4CEqolJkLZFgicu/Agent-Kanban) 实现的原生客户端；不会依赖旧 Web/API/Worker 工程。

## 运行

```sh
./macos/scripts/build-app.sh debug
open 'macos/build/Agent Kanban.app'
```

也可在 Xcode 26 打开 `macos/AgentKanban.xcodeproj`，运行 `AgentKanban` scheme。需要重新生成项目时运行 `xcodegen generate --spec macos/project.yml`。Swift Package 是源代码依赖的事实来源，Xcode 工程仅使用系统框架，无第三方 Swift 包。

构建脚本生成本机 ad hoc 签名应用；正式发布的开发者签名、公证和分发尚未配置。

## 已实现的工作流

- 导入已有本地 Git 仓库，规范路径去重；项目下新建普通会话。项目菜单设置新任务默认执行器或移除项目。移除需要确认，不删除代码，不提供已移除列表或恢复入口。
- 看板包含待处理、讨论、开发、验收、完成。新任务只填写标题、多行说明、类型、优先级；默认项目目录，任务详情可选择 Git Worktree 独立开发。执行器继承项目默认值，模型/强度/权限继承执行器原生默认值。
- 创建/编辑任务说明和会话输入支持 `⌘V` 粘贴截图、图片或 Finder 文件；显示图片缩略图、文件名和大小，支持打开与移除，普通文本、多行粘贴和输入法继续正常工作。任务附件保存为应用本地副本，重启后仍保留。粘贴端拒绝目录、不可读取文件和超过 25 MB 的文件并提示；发送图片总量最大 5 MiB，图片总量或能力在适配器启动校验失败时保留已保存消息与附件，将已预留 Run 标为失败并说明原因。图片通过执行器原生 image 协议传递。
- 项目普通会话“…”和右键菜单提供“删除会话”，确认后持久移出列表。删除当前会话返回项目看板；运行、停止中、待恢复或导入期间禁止删除。任务主会话不能单独删除，已导入任务、来源与批次审计继续保留。
- 待处理输入只保存备注，不请求模型。讨论与验收强制只读；开发和普通会话按原生权限执行。普通阶段切换不会启动模型；用户点击“确认方案”会确认当前版本、进入开发并立即启动一次开发运行。
- 项目会话与任务主会话使用相同的两级模型控件、离散强度滑杆、三项权限菜单。强度颜色联动，选择按会话及执行器保存。每次 Run 冻结配置，修改只影响后续请求。
- 方案和验收条件版本化，确认方案后进入开发并执行已确认版本，保留任务备注与附件；待处理也可点击“直接开发”，跳过讨论和方案确认，按标题、说明、备注与附件执行。同目录忙时直接持久排队，不弹占用错误、不回滚已接受的阶段操作；执行器启动失败保留开发阶段与失败记录，可在主会话重试。验收报告为可选参考，生成时绑定需求版本和 Git 指纹、保留逐项证据；用户可从开发直接完成，不要求报告存在、通过、有效或已确认方案，完成仍保留停止和并发保护，Agent 不自动完结。
- “运行中”入口和角标汇总全局所有项目未结束的运行，包括排队、启动、执行、等待审批、停止中与待恢复；完成、失败或已停止后自动移出。每项显示原项目，切换侧栏项目不改变集合。列表、详情、最近事件与审批沿用同一全局范围，历史证据继续保存在任务/会话和本地数据库。
- 同规范 cwd 写入按持久 FIFO 排队，可取消未启动请求；queued 不持目录锁、不启动进程，真正启动前以原子 claim 取得写入租约。空闲目录可在请求事务中直接预留启动；不同 cwd（含同项目独立 Worktree）可并行。等待审批、停止未确认或待恢复未核实的运行继续占位，不提前交接写入权。
- 重启保留尚未启动的 queued 请求、顺序与冻结上下文，并在目录可用后继续调度；已启动或启动状态不确定的 Run 才进入待恢复。恢复核对真实 PID、进程出生时间与独立进程组，只有身份吻合才停止旧进程；无法核实时保持阻塞。已启动请求不重放。
- 全局执行器与认证弹窗只读检测本机 Codex、Claude Code、Cursor Agent 的安装、认证和模型目录。登录由对应官方 CLI 在终端完成，应用不收集或存储账号密码/API Key。

界面使用设计稿的布局、颜色与原始图标资源：1440 × 900 基准、232 侧栏、48 顶栏、28 状态栏；材质使用 macOS 26 系统 Liquid Glass，正文与代码区保持内容底色。实际核对截图见 [validation/screenshots](validation/screenshots)。

## 会话内导入 Skill

在项目普通会话附加任务表并输入“把表格中的任务导入看板”，或提供 GitHub 仓库 / Issues 列表 / 单项 Issue 链接并明确要求“导入”或“添加到任务看板”。来源和指令可分消息提供，缺少来源时会话会提示补充；读取失败后可说“继续导入”或“已登录”沿用原请求和筛选条件。直接创建待处理任务，会话返回实际来源范围、已持久化任务编号、重复跳过及坏行。成功、取消或无关新请求会结束上下文延续。没有专用导入按钮、选择向导或统一确认步骤；仅提供附件或链接不会创建任务。

- 支持 `.xlsx`、UTF-8/UTF-16 `.csv`、`.tsv`，保留多行内容。旧 `.xls` 需要另存为 `.xlsx`/`.csv`。
- 常用列：标题/title、说明/description、类型/type、优先级/priority、编号/id、来源链接/url。需要标题列；无效行反馈到会话，完整来源读取失败则整批不提交。
- 有稳定行 ID 时使用“原始文件规范路径 + 工作表 + ID”去重。无 ID 时绑定文件内容快照及完整标准化行，避免仅凭同名标题合并。重试同一文件幂等；无 ID 工作簿发生修改或来源路径变化时，应提供稳定 ID，不能承诺跨版本语义合并。
- GitHub 仅使用只读 API，支持分页、open/closed/all 状态、标签和受理人筛选；PR 排除。“指派给我的 Issue，我是 username”与 URL / q 中的 assignee 均保持范围，`@me` 从 GitHub 当前认证身份解析。仓库根链接仅在明确的 Issue 导入请求下转为 Issues。未知或冲突条件拒绝导入，避免扩大来源范围。优先复用 `gh auth login`，没有 `gh` 时读取公开仓库；私有仓库不在聊天中输入 token。
- 每个附件最大 25 MB，每批最多 10,000 项任务。工作簿解压内容有上限，不展开归档到磁盘，不执行宏。

内置 Skill 定义：[task-import-SKILL.md](Sources/AgentKanban/Resources/task-import-SKILL.md)。宿主在明确导入意图时执行受约束的读取、标准化和持久化命令，不把来源文档中的文字当成阶段切换、命令执行或扩大授权的指令。

## 架构与实现决定

```text
AgentKanban (SwiftUI / AppStore)
  ├─ AgentKanbanCore (Repository actor / SQLite / TaskEngine / Git / ImportReader)
  └─ AgentKanbanExecutors (Codex app-server / Claude stream-json / Cursor ACP)
```

- SQLite 事务、外键、活动路径/主会话/活跃运行唯一约束以及持久目录占位维护业务一致性。Run 和审批携带所属项目、会话与阶段版本，后台事件按 ID 分发。
- 默认数据目录：`~/Library/Application Support/AgentKanban`，含 `workspace.sqlite`、附件副本、登录命令文件和 `Worktrees/<project-id>/<task-id>`。凭证仍由官方执行器管理。数据库创建失败会显示错误，不回退到无持久化演示数据。
- `AGENT_KANBAN_DATA_DIR` 可指定独立验收数据目录；`AGENT_KANBAN_APPEARANCE=light|dark` 仅用于外观验证。正常启动跟随系统外观。
- 原生执行器沙箱用于普通会话和开发。讨论/验收额外使用继承到子进程的宿主 Seatbelt 文件只读约束。Codex 采用 `externalSandbox` 避免嵌套 macOS 沙箱失败；实际权限记录如实区分宿主只读、原生权限与网络连接，不声称已验证网络隔离。
- Claude 接入采用官方已安装 CLI 的 `stream-json` 控制协议，复用本机登录；这是对系统设计“独立 SDK bridge”建议的实施调整。理由、协议版本及执行器联调证据见 [EXECUTORS.md](EXECUTORS.md)。
- 内部分析/审查仅在具备宿主只读保护时开放；写入阶段禁止不可控的内部委派。任务可选择 Git Worktree：从项目当前已提交 HEAD 新建 `codex/kanban-<task-id>` 分支，不复制主目录未提交改动，不切换、重置或提交主仓库；已有初始提交才可创建。只复用本项目登记且分支匹配的工作树，已有目录/分支冲突安全报错，不覆盖或删除。未终结运行或阶段停止屏障期间不可切换任务目录，历史 cwd 保持不变。不会自动提交、合并、删除工作树或发布代码。

## 验证

```sh
swift test --package-path macos
xcodebuild -quiet -project macos/AgentKanban.xcodeproj -scheme AgentKanban \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath macos/build/Xcode CODE_SIGNING_ALLOWED=NO build
```

默认测试不请求模型、不访问私人仓库、不修改用户项目。真实联调使用临时 Git 仓库，需显式启用对应环境变量，具体命令、通过结果和验证边界见 [VALIDATION.md](VALIDATION.md)。Cursor 当前账号的模型请求受到套餐限制，认证成功不能视为模型执行成功。
