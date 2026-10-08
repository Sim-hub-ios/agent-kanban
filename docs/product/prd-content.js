/* 静态 PRD 内容。HTML 原型用于评审；目标产品为 macOS 26.0+ SwiftUI 应用。 */
window.PRD_SECTIONS = [
  {
    id: "overview",
    title: "产品概述与范围",
    kicker: "产品定位",
    body: `
      <p>Agent Kanban 是面向本地代码库的 macOS 编程协作工具。用户通过任务看板管理需求，让 AI 在讨论、开发和验收阶段参与工作；每项任务拥有持续的主会话，并可指定不同模型。产品把任务进度、对话和代码结果放在同一工作空间。</p>
      <div class="callout"><strong>产品定位：</strong>用户决定任务何时推进，Agent 提供方案、执行代码工作并报告证据。最低支持 macOS 26.0，正式界面使用 SwiftUI 系统 Liquid Glass 与原生控件；本文、HTML 和 Figma 用于评审。</div>
      <h3>讨论结论的来源级别</h3>
      <table><thead><tr><th>级别</th><th>内容</th></tr></thead><tbody>
        <tr><td><span class="status confirmed">已确认</span></td><td>本机运行、面向本地代码库；任务看板与项目内普通会话并存，普通会话入口和列表位于所属项目下，可按当前执行配置直接读改代码和运行命令，无需先建看板任务；用户明确要求导入任务表或 Issue 后，内置 Skill 由 Agent 直接批量创建待处理任务并在会话报告结果；一任务一主会话；创建任务自动采用当前项目默认执行器与执行器原生默认配置，不在创建表单配置执行器、模型、强度或权限；任务默认使用所属项目目录，可在任务详情选择 Git Worktree 独立开发；普通会话和任务可在会话输入区联动选择执行器、模型与其支持的推理强度，并按执行器选择原生权限与执行隔离；人切换阶段，AI 可以建议；待处理任务保留“进入讨论”，并可由用户明确点击“直接开发”，跳过讨论和方案确认后进入开发并启动一次执行；最低 macOS 26.0，界面采用 SwiftUI 系统 Liquid Glass 与原生控件。执行器候选范围暂定为 Codex、Claude、Cursor 三种。</td></tr>
        <tr><td><span class="status proposed">建议</span></td><td>Swift 调度层、SQLite 持久化、独立执行器进程；主会话关联内部 Agent 子会话；执行器原生隔离、运行取消、验收指纹与失败恢复。执行器与模型在会话输入区分别选择，任务创建沿用已确认的默认配置规则。</td></tr>
        <tr><td><span class="status pending">待定</span></td><td>三种候选的实测能力、首个实现及接入顺序、凭证存储方式、首版是否支持跨执行器协作。Cursor 已完成官方文档调研、本机 ACP 初始化探针，以及 CLI 模型/强度目录与 ACP 源码核对，详见<a href="#cursor-integration">Cursor 接入调研</a>；尚未完成真实任务联调。</td></tr>
      </tbody></table>
      <h3>范围边界</h3>
      <p>首版聚焦单机、单用户、Git 本地仓库的完整闭环，支持按用户指令读取 Issue 并导入本地任务。远程团队协作、Issue 持续双向同步、云端调度和自动发布不属于当前需求。本地运行指应用与任务调度在本机；模型调用是否联网取决于所选执行器和模型。</p>
      <p class="source">依据：<a href="https://chatgpt.com/s/cx_6ac5003636788191bb9c7a03ce113173" target="_blank" rel="noopener">《确认项目如何调用 Codex 或 Claude》分享讨论</a>，以及本轮用户补充“执行器暂定 Codex、Claude、Cursor 三种”。暂定范围不表示三种均已接通；Cursor 是执行器候选，不是模型名称。优先级、细化规则和默认值是本 PRD 的建议基线，仍可在评审中调整。</p>
    `
  },
  {
    id: "workflow",
    title: "阶段流程与权限",
    kicker: "人主导流程",
    body: `
      <p><span class="status confirmed">已确认</span>看板任务的四个核心阶段为“待处理 → 讨论 → 开发 → 验收”。推进和回退由用户操作，AI 的阶段建议只生成待确认建议。待处理另有用户明确选择的“直接开发”路径：无需先讨论时，直接进入开发并启动一次执行；“进入讨论”保持原行为。普通项目会话没有任务阶段，按当前执行器权限与项目授权范围直接处理代码请求。</p>
      <table><thead><tr><th>阶段</th><th>允许的 AI 行为</th><th>退出依据</th></tr></thead><tbody>
        <tr><td>待处理</td><td>创建和输入只保存任务与备注，不请求模型、不预热 Agent。保留“进入讨论”；用户可明确点击“直接开发”，校验通过后进入开发并启动一次执行。</td><td>进入讨论沿用原规则；直接开发由显式点击授权，不由备注、附件或后台监听触发。</td></tr>
        <tr><td>讨论</td><td>读取授权代码与资料，澄清需求、提出方案和验收条件；禁止修改代码。</td><td>用户确认需求版本后进入开发。</td></tr>
        <tr><td>开发</td><td>在任务选定的项目目录或 Git Worktree 修改代码、执行获准命令和测试；主会话展示结果与阻塞原因。</td><td>用户选择进入验收。</td></tr>
        <tr><td>验收</td><td>读取 diff，运行预设检查，逐项评估验收条件；修复建议返回开发阶段执行。</td><td>用户可参考报告手动完成，或退回讨论/开发；报告不是完成前提。</td></tr>
      </tbody></table>
      <p>普通讨论 → 开发路径仍须由用户确认当前需求、方案及验收条件；仅待处理任务的“直接开发”明确授权跳过本次开发阶段的讨论与方案确认。两条路径均检查执行器与模型、仓库及项目目录访问、唯一主运行和目录调度，不扩大原生权限。非目录忙的条件未满足时展示具体阻塞项，保留原阶段；同目录已有写入者时直接进入持久等待队列，不弹窗；直接开发不伪造方案、确认或验收条件。</p>
      <h3 id="direct-implementation">待处理直接开发 · FR-01/02/06/08</h3>
      <p>待处理任务同时提供“进入讨论”和“直接开发”。用户明确表示无需讨论时，点击“直接开发”即授权按任务标题、说明、已有主会话备注及任务/备注附件直接工作；使用任务当前执行器、模型、强度与权限配置，执行目录为任务选定的项目目录或 Git Worktree。校验通过后，一次操作将任务切到开发并启动一个真实主 Run，不要求先填写或确认方案，不追加虚构的方案、确认记录或验收条件。</p>
      <p>启动准备时复核任务仍在待处理、阶段版本与归属、执行器能力、目录访问及唯一主运行；版本冲突、能力/访问检查或事务失败时保持待处理，显示原因，不留下半切换、操作消息或新 Run。同目录忙属于正常调度：在同一事务保存开发阶段、新 phaseVersion、匹配的可选 <code>directImplementationPhaseVersion</code>、唯一 queued 主 Run、冻结的请求上下文与明确用户操作消息，不弹占用错误。排队不启动执行器、不持目录锁；调度器按同规范 cwd 的 FIFO 顺序，在真正启动前原子 claim 并取得写入租约。附件沿用不可变本地引用，重复点击不能重复入队或启动。</p>
      <p>跳过方案确认的授权只属于此次开发阶段；离开开发或保存新方案时清除，之后不能借旧标记绕过普通方案确认。该授权不放宽沙箱、审批或停止屏障。需要独立验收时，可在“方案”页补充并确认真实标准，再生成报告；用户也可从开发直接手动完成，无需先产生报告。只有明确用户操作创建一次执行意图；目录释放后可自动启动已接受的 queued Run。输入备注、进入讨论、后台阶段刷新和登录完成不会创建新意图。重启保留尚未启动的 queued 请求并继续调度；已启动或无法确认是否已启动的 Run 先恢复核对，不重放 prompt。</p>
      <h3>切阶段时的建议规则</h3>
      <ol><li>冻结该任务新的运行请求，取消主 Run、所有子 AgentRun，并清空排队请求。</li><li>界面显示“正在停止”；执行器确认终止后，才更新阶段并开放新阶段操作。</li><li>终止失败时保留原阶段和错误信息，提供重试；旧运行的迟到结果不得写入新阶段。</li></ol>
      <p>阶段表示业务进度；运行状态独立表示空闲、排队、运行、等待审批、正在取消、成功、失败或已取消。“已完成”由用户主动操作；开发可直接完成，无需先进入验收或产生报告。报告缺失、未通过、过期，或需求/方案版本未确认，均不阻止手动完成；已有报告按原状态保留作参考。完成仍须通过运行停止与并发保护，不自动运行 AI，Agent 回复、运行成功或验收通过也不自动完结任务。</p>
    `
  },
  {
    id: "requirements",
    title: "核心功能需求",
    kicker: "功能需求",
    body: `
      <p>共 18 项功能需求。P0 为建议首版必需，P1 为首版后半程增强，P2 为后续扩展。需求编号同时用于原型交互和验收追踪。</p>
      <table><thead><tr><th>编号 / 优先级</th><th>需求与可观察结果</th><th>来源 / 原型位置</th></tr></thead><tbody>
        <tr><td>FR-01 · P0</td><td>创建、编辑任务并手动切换四阶段；新建表单只填写任务内容与类型/优先级，执行目录默认所属项目目录，任务详情可选择 Git Worktree，执行配置自动采用当前项目默认执行器及其原生默认值，后续在任务会话调整；说明与备注使用可纵向调整大小的多行文本框，支持换行、多行文字及图片/文件粘贴，附件随任务持久化；待处理保留“进入讨论”并提供“直接开发”，由用户显式操作进入开发且启动一次真实 Run；AI 建议不会直接移动卡片。</td><td>已确认 · 任务看板</td></tr>
        <tr><td>FR-02 · P0</td><td>按阶段启用能力；待处理创建、输入及恢复仅写入本地记录，模型请求次数为零；仅用户点击“直接开发”后，原子进入开发并启动一次真实执行。</td><td>目标已确认，细化建议 · 任务详情</td></tr>
        <tr><td>FR-03 · P0</td><td>每任务保留独立主会话、需求版本、运行记录和代码上下文。</td><td>一任务一会话已确认，其余细化建议 · 任务详情</td></tr>
        <tr><td>FR-04 · P0</td><td>普通项目会话与任务主会话在输入框底部以单一紧凑入口展示执行器、模型与推理强度摘要，点击先打开紧凑推理面板，再点击面板中部模型名进入执行器/模型选择列表；推理面板采用随强度变色的离散滑杆、居中的当前值与重置操作，各自独立保存；每次回复/Run 冻结配置，运行中修改下次生效；切换执行器保留逻辑会话和历史，按能力关联新执行器会话。</td><td>联动选择与独立保存已确认，能力细化建议 · 会话输入区与任务详情</td></tr>
        <tr><td>FR-05 · P0</td><td>切阶段执行完整取消屏障；停止完成前不启动新阶段运行。</td><td>建议 · 阶段切换</td></tr>
        <tr><td>FR-06 · P0</td><td>一个任务最多一个未终结主 Run；不同规范 cwd（含同项目的独立 Git Worktree）可并行。同目录写入按持久 FIFO 自动排队，不弹占用错误；排队可取消且不持目录锁，真正启动时原子 claim 后取锁。</td><td>建议 · 运行面板</td></tr>
        <tr><td>FR-07 · P0</td><td>任务执行目录默认所属项目目录，任务详情可选择 Git Worktree，隔离跟随执行器原生沙箱与权限；同一规范 cwd 同时只有一个写入 Agent；Worktree 从已提交 HEAD 创建独立任务分支，不复制未提交改动，不自动合并或删除。</td><td>目录规则已确认，隔离细化建议 · 任务主会话与运行记录</td></tr>
        <tr><td>FR-08 · P0</td><td>版本化保存需求、方案、验收条件，修改后展示待重新确认状态。进入“方案”页时，当前讨论阶段主会话最新成功完成的最终回复自动带入可编辑、未保存草稿，已有历史回复同样适用；保留完整 Markdown 和来源消息/运行。仅用户保存时生成未确认的新版本，不自动覆盖已保存方案或推进阶段；普通讨论 → 开发仍须人工确认；“直接开发”仅按 FR-01/02 的显式授权例外进入本次开发阶段，不生成虚构修订或验收条件。</td><td>建议 · 需求与验收</td></tr>
        <tr><td>FR-09 · P0</td><td>验收报告为可选参考，结果绑定需求版本与代码指纹；相关变化后原报告标记过期并保留历史。用户手动完成不依赖报告存在、通过、有效或已确认方案/条件；开发可直接完成，已有报告不被改写成通过或有效。运行停止/并发保护保留，Agent 不自动完结。</td><td>建议 · 验收面板</td></tr>
        <tr><td>FR-10 · P0</td><td>普通会话归属项目，侧栏列出并可新建、直接打开；顶部只读显示项目与当前会话名称，无切换下拉。按当前执行器、模型、强度与原生权限直接读改代码、运行命令，不要求转成任务；仅用户明确要求转任务或按 FR-16 导入时创建看板任务。</td><td>项目会话交互已确认，建任务规则细化 · 项目会话列表</td></tr>
        <tr><td>FR-11 · P1</td><td>执行器按需调用内部 Agent，独立审查与分析保持各自上下文；调用状态、摘要与证据回传任务主会话并进入已有运行记录，不提供独立 Agent 配置页面。</td><td>能力细化建议，页面简化已确认 · 任务主会话与运行记录</td></tr>
        <tr><td>FR-12 · P0</td><td>候选限于 Codex、Claude、Cursor；统一执行器接口，首版先完成其中一个 Adapter，展示实测能力；首个实现与顺序待定。</td><td>范围由用户暂定，接口细化建议 · 执行器与认证弹窗</td></tr>
        <tr><td>FR-13 · P0</td><td>命令与权限请求绑定原 Run 进入审批队列；全局“运行中”汇总所有项目活动运行的待审批请求并标明项目，拒绝后保持任务并说明影响。</td><td>建议 · 审批卡片</td></tr>
        <tr><td>FR-14 · P0</td><td>支持执行器退出、断网和应用重启后的失败恢复；尚未启动的 queued 请求持久保留并继续调度，已启动或启动状态未知的 Run 必须先核对；全局“运行中”汇总各项目未终结运行与恢复提示，按原 Run 核对旧运行与目录锁，恢复不自动重放写操作。</td><td>建议 · 运行记录与恢复入口</td></tr>
        <tr><td>FR-15 · P0</td><td>导入已有本地 Git 项目并按活动项目规范路径去重；支持确认后移除项目，不删除仓库/代码/分支/worktree。运行、停止屏障或 Skill 导入中阻止移除；最后一个项目可移除为空状态。不提供已移除项目列表或恢复功能；同目录以后可重新导入为新项目，不承诺原 ID 或历史数据恢复。</td><td>导入与移除由用户补充，细化建议 · 空状态 / 本机项目区 / 项目菜单</td></tr>
        <tr><td>FR-16 · P0</td><td>内置任务清单导入 Skill：项目普通会话附加 Excel/CSV 任务表或提供 Issue 链接并明确要求导入后，Agent 自动识别、标准化与去重，直接幂等创建该项目待处理任务；会话报告任务编号、重复跳过与错误，不增加选择或确认流程。</td><td>内置 Skill 与直接导入由用户确认，细化建议 · 项目普通会话</td></tr>
        <tr><td>FR-17 · P0</td><td>从桌面全局侧栏“执行器与认证”入口或窄屏头部齿轮打开轻量认证弹窗，提供状态检查与重新检测；首次使用、切换执行器及启动实际 Run 前自动只读检查，区分安装、认证与未知状态；认证检测不启动模型或任务运行。</td><td>检查入口由用户确认，细化建议 · 全局侧栏 / 窄屏头部齿轮</td></tr>
        <tr><td>FR-18 · P0</td><td>聊天输入框底栏盾牌菜单仅提供“请求批准 / 帮我批准 / 完全访问权限”三行预设，映射所选执行器原生能力；会话和任务按执行器保存，切换恢复，下次回复/Run 生效并冻结快照。未知或自定义配置不伪造勾选；不可用预设禁用，实际生效未知不标为已沙箱。</td><td>用户补充，原生能力按版本验证 · 输入框左下盾牌入口</td></tr>
      </tbody></table>
    `
  },
  {
    id: "agents",
    title: "内部 Agent 协作规则",
    kicker: "协作编排",
    body: `
      <p><span class="status proposed">建议</span>所选执行器按需调用内部 Agent，Swift TaskEngine 继续约束权限、事件归属、写入锁和停止屏障。用户始终面对任务主会话；内部任务保留独立上下文与运行配置快照，调用状态、结果摘要和证据在主会话及已有运行记录中展示。</p>
      <p><span class="status confirmed">已确认</span>不提供独立 Agent 配置页面或导航入口，不要求用户配置固定角色列表。下列职责是内部协作规则，具体调用以执行器实际能力和任务需要为准。</p>
      <table><thead><tr><th>角色</th><th>职责</th><th>权限与产出</th></tr></thead><tbody>
        <tr><td>开发 Agent</td><td>实现已确认方案；若本次开发阶段来自用户“直接开发”，则使用任务标题、说明、已有备注和附件执行明确任务，记录缺少的验收标准，不伪称方案已确认。执行测试并报告变更。</td><td>所属项目目录唯一写入者；产出 diff、测试记录和未解决项。</td></tr>
        <tr><td>独立审查 Agent</td><td>从需求与 diff 检查缺陷、遗漏和风险。</td><td>只读代码；在独立会话给出带文件位置的发现，不直接修改实现。</td></tr>
        <tr><td>分析 Agent</td><td>按需调查代码结构、资料或技术问题。</td><td>只读指定上下文；产出可追溯结论，任务结束后汇总。</td></tr>
      </tbody></table>
      <h3>协作顺序</h3>
      <p>执行器按阶段权限与任务需要调用内部 Agent → 按需分析 → 开发完成并停止写入 → 冻结代码指纹对应的快照 → 独立审查读取快照 → 将发现和结果汇总至主会话。首版默认串行审查，保证审查结论绑定稳定代码；不同规范 cwd 的任务可并行，包括同项目独立 Worktree；同目录写入按 FIFO 排队并在 claim 后串行。审查发现问题只形成建议，由用户决定是否回到开发。</p>
      <p>首版先验证“一个执行器、一个写入者”闭环，再增加只读审查与分析演示。任务默认使用所属项目目录；用户可在任务详情选择 Git Worktree，内部 Agent 继承父 Run 冻结的 cwd；同目录写入自动 FIFO 排队，不同 Worktree 可并行，执行隔离由所选执行器的原生沙箱与权限控制。</p>
      <p>跨执行器协作属于待定扩展，仅在用户暂定的 Codex、Claude、Cursor 范围内考虑。每个 Agent 的执行器与模型分别配置；模型名称、会话格式和权限能力可能不同，不能仅凭 Adapter 存在就声明互操作成功；必须经过端到端实测。</p>
    `
  },
  {
    id: "interaction",
    title: "界面与关键交互",
    kicker: "界面与交互",
    body: `
      <h3>系统界面与材质</h3>
      <p>最低支持 macOS 26.0，不增加 macOS 25 及以下兼容方案。SwiftUI 优先使用系统 Liquid Glass 与原生控件，将玻璃用于导航、工具栏、输入控件及菜单浮层；正文、任务卡片、代码和 diff 保持稳定、易读的内容底色，避免大面积透明影响阅读。保留蓝色主操作、随档位变色的推理强度及文字/图标辅助的语义状态。</p>
      <p>筛选与选择控件的下拉指示采用独立 chevron 图标，不用字母或字符模拟。任务卡、会话执行摘要与认证列表中的执行器身份使用对应的 Codex、Claude、Cursor 标志，并保留可读名称。</p>
      <p>界面适配浅色与深色外观，并响应系统“减少透明度”“减少动态效果”“增加对比度”；减少透明度时提供清晰的实底与边界，减少动态效果时减弱材质与过渡动画。HTML 与 Figma 仅模拟材质及代表性状态，系统材质、自适应外观和无障碍设置须在 macOS 26 的 SwiftUI 实现中验证。</p>
      <p class="source">官方依据：<a href="https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass" target="_blank" rel="noopener">Adopting Liquid Glass</a>、<a href="https://developer.apple.com/design/human-interface-guidelines/materials" target="_blank" rel="noopener">Human Interface Guidelines · Materials</a>。</p>
      <h3>工作空间</h3>
      <p>左侧工作台保留“任务看板”和“运行中”工作视图；“运行中”是全局所有项目活动 Agent 的监控入口，角标与列表共用所有项目的未终结运行集合，包含排队、启动、执行、等待审批、正在停止及待恢复状态。选择其他项目不会改变全局运行集合；不受历史时间范围限制，不提供已结束运行筛选。成功、失败或确认停止后立即移出列表，历史配置、事件和证据仍保留在原会话及本地运行记录中。“本机项目”树中，每个项目下展示普通会话列表和“新建会话”入口，不提供全局普通聊天导航或独立 Agent 配置入口。用户可切换项目，也可直接点选某个项目下的具体会话，同时切换到其所属项目。中部看板展示四个核心阶段及“已完成”列，共五列。任务详情提供“会话、方案、变更、验收”页签，内部 Agent 调用状态、摘要和证据直接进入主会话，当前活动运行事件在全局“运行中”查看，结束后的证据保留在原会话与本地运行记录。卡片显示标题、模型、阶段、运行状态与最近结果；业务阶段和运行状态分别显示。项目“…”菜单仅保留移除等项目操作；“执行器与认证”位于桌面全局侧栏底部，打开轻量认证弹窗，桌面头部齿轮去重。窄屏无侧栏时保留头部齿轮作为全局认证入口，不保留全局“项目与设置”导航或独立设置页。候选仅为 Codex、Claude、Cursor。窄屏项目栏提供当前项目菜单与导入入口，窄屏导航仅为看板、会话、运行中。</p>
      <h3 id="active-runs">全局运行中 · FR-03/11/13/14</h3>
      <p>角标、运行列表、事件、待审批请求与恢复提示均从同一全局未终结运行集合派生，不按当前侧栏项目过滤。每项显示所属项目、任务或普通会话及执行器；子 Agent 的状态、摘要与事件归入父运行，保留父子标识，不混成独立无归属会话。等待审批、正在停止和待恢复仍属未终结；只有确认成功、失败或停止后才移出。全部项目都没有活动运行时才显示空态。</p>
      <p>从任一运行打开会话时，定位该 Run 原属项目与任务主会话或普通会话；审批、停止和恢复始终提交原 runId / projectId / conversationId 及适用版本，由宿主复核归属，不使用当前选中项目替换。事件按原 Run 归档，在全局监控中汇总展示，不写入其他项目消息历史，也不改变任务阶段。</p>
      <h3>导入本地项目</h3>
      <p>首次没有项目时展示“导入本地项目”主入口；侧栏“本机项目”旁与窄屏项目栏保留导入按钮，已有项目时也可导入和切换。正式 SwiftUI 应用通过系统目录选择器选择已有本地 Git 仓库，显示项目名称、仓库路径和默认执行器；执行器仅可选择 Codex、Claude、Cursor，模型由任务或普通聊天分别选择。</p>
      <ol><li>选择目录后只读校验：目录存在、可访问，且 Git 能识别仓库根目录；记录规范化后的仓库路径，名称预填为目录名并允许修改。</li><li>校验失败时分别提示“目录不存在”“缺少访问权限”或“不是有效 Git 仓库”，保留输入供用户重选或重试；取消目录选择或导入不创建项目。开发阶段的写入权限和项目目录检查仍在启动运行前执行。</li><li>同一规范化仓库路径已有活动项目时，提示已导入并切换到已有项目；已被移除的目录可再次导入为新的项目记录，不复用旧项目 ID 或自动带回旧任务、会话与运行历史。新项目导入成功后显示独立的空看板与空会话列表，该项目尚无运行历史；全局“运行中”继续显示其他项目的活动运行，用户通过该项目的“新建会话”开始普通聊天；项目切换只改变当前工作空间，其他项目运行继续按原归属记录。</li></ol>
      <p>导入只创建项目记录，不自动 clone 仓库、安装执行器或启动 AI。再次访问时若目录被移动、删除或权限失效，保留项目数据并显示访问阻塞，要求重新选择有效目录。</p>
      <p class="callout">HTML 原型的导入只模拟路径输入和项目记录，不访问本机目录，也不验证 Git 或文件权限。输入尚不存在的路径仍只是演示值，不能视为真实导入校验通过；系统目录选择与真实校验需在 SwiftUI 实现中验证。</p>
      <h3 id="project-removal" style="scroll-margin-top:150px">移除项目 · FR-15</h3>
      <p>在对应项目的“…”菜单中提供“移除项目”，窄屏从当前项目菜单进入。确认对话框展示项目名称、仓库路径及受影响的任务、会话和运行记录，说明移除后项目及其关联任务、会话和运行记录不再显示在当前工作空间，不提供恢复操作；本地仓库、代码、分支或 worktree 不删除，取消保持原状。</p>
      <p>项目存在活跃主/子 Run、正在停止的运行、任务阶段停止屏障或进行中的 Skill 导入时，阻止移除并引导先停止或等待完成，不能直接丢弃运行归属。满足条件后，将项目从活动工作空间移出，相关记录按原归属保留内部兼容即可，不要求永久清空已有存储；不提供已移除项目列表、恢复弹窗或恢复命令。其他项目和全机执行器认证状态保持不变。</p>
      <p>移除当前项目后切换至其他活动项目；最后一个项目移除后进入无项目空状态，刷新仍保持为空，不自动补回 sample 项目。无项目时可导入本地项目，同一目录以后重新导入时创建新项目，该项目的看板、会话列表和运行历史为空，全局“运行中”仍按所有项目活动运行汇总，不承诺恢复原 ID、配置、历史或来源关系。界面不提供“已移除项目”或“重置演示”入口。</p>
      <p class="callout">HTML 移除仅操作浏览器中的活动演示记录，不删除真实目录，也不执行 Git 或终止真实进程；旧存储的兼容保留不代表提供恢复功能。真实存储事务、目录访问和进程停止仍须在 SwiftUI 实现中验证。</p>
      <h3>新建任务 · FR-01</h3>
      <p>新建任务表单保留标题、说明与备注、类型和优先级；不展示任务工作区、执行器、模型、推理强度或运行权限选择。任务默认使用所属项目的 <code>project.path</code>；创建表单保持四字段，后续在任务详情选择“项目目录 / Git Worktree”，不接受任意外部执行路径；执行隔离跟随所选执行器的原生沙箱与权限。创建时自动采用当前项目的默认执行器，模型、强度与权限跟随该执行器的原生默认配置，不复制来源普通会话的选择，也不新增项目默认模型或额外设置页。任务从“待处理”开始，创建只保存任务与独立主会话，不发起模型请求、执行器预热或代码运行。</p>
      <p>“说明与备注”使用可编辑的多行文本框：Enter 插入换行，支持多行粘贴，可纵向拖动调整高度；Enter 不触发创建。保存与再次显示时保留段落和换行，不将其压成单行。</p>
      <h3 id="clipboard-attachments">粘贴图片与附件</h3>
      <p>原生输入框的 placeholder、可编辑文本与 caret 首行共用同一套 TextKit 排版、字体与内容边距，避免占位提示与光标错位。中文输入法产生 marked text 时立即隐藏 placeholder，不等待文本绑定提交；仅在内容为空且没有 marked text 时恢复。创建/编辑任务的说明与备注、任务主会话和项目普通会话保持一致。HTML 使用原生 textarea 占位提示，仅演示交互，不能替代 macOS TextKit 与输入法实测。</p>
      <p>创建或编辑任务的“说明与备注”、任务主会话和项目普通会话输入框支持 <kbd>⌘V</kbd> 粘贴截图、图片或在 Finder 复制的文件，也可通过通用附件入口添加。纯文本粘贴与输入法保持正常，多行内容保留换行。图片显示缩略图，其他文件显示文件名与大小；发送或保存前可打开预览、移除附件，移除附件不删除原文件。</p>
      <p>任务附件与说明一起保存为应用管理的本地副本，重启后仍可查看，编辑时保留未移除的附件。创建任务及待处理备注只保存数据，不启动执行器。普通文件每项不超过 25 MB，粘贴端拒绝目录、不可读取文件和超限文件并提示。向执行器发送的图片原始数据总量不超过 5 MiB；图片总量与执行器图片能力在适配器启动时校验，失败时保留已保存的消息和附件，将已预留的 Run 标为失败并说明原因，不静默忽略附件。图片通过对应执行器的原生 image 内容协议发送，不以纯文件路径文字冒充图片输入。</p>
      <p>创建后，用户可在任务主会话输入框底部调整执行器、模型、推理强度和权限；选择随该任务保存。修改项目默认执行器只影响之后新建的任务，不覆盖已有任务选择或历史 Run。执行器默认值未确认时如实显示“执行器默认”或未知状态，不推断具体模型、强度或已沙箱；真正运行前再按当前能力与认证状态校验。</p>
      <h3>任务详情</h3>
      <p>顶部包含阶段选择和运行控制；主会话输入区提供执行器、对应模型和推理强度选择。任务初始采用创建时的项目默认执行器，之后在会话中修改的选择随任务独立保存。待处理阶段的输入提示为“记录任务备注”，发送后不会出现 AI 回复；同时保留“进入讨论”和新增“直接开发”两个明确操作。“直接开发”读取任务标题、说明、已有主会话备注与任务/备注附件，使用该任务当前执行配置，校验成功后进入开发并立即启动一次真实 Run；操作进行中禁用重复点击。进入讨论后展示需求确认入口；开发阶段展示所属项目目录与变更；验收阶段展示可选报告的代码版本与检查结果。用户可从开发直接手动完成，完成入口不因报告缺失、未通过、过期或方案未确认而禁用；已有报告仅作参考，仍需先停止此任务的全部活动运行。</p>
      <h3 id="conversation-execution-options" style="scroll-margin-top:150px">会话执行器、模型与推理强度 · FR-04</h3>
      <p>项目普通会话与任务主会话参考 Codex 输入框布局：文本输入在上，底部工具栏以一个紧凑入口展示“执行器 · 模型 · 强度”摘要，强度按当前档位配色。点击摘要先打开一级紧凑推理面板，包含闪电图标、居中的“当前强度 + 默认/当前模型名 + chevron”可点击入口、重置操作和下方滑杆；初始使用执行器默认模型，无需先选择模型。默认模型未确认时显示“执行器默认”，不虚构具体版本。只有点击面板中部的模型名入口，才打开二级模型选择列表，二级保留 Codex、Claude、Cursor 切换及各自模型；选择模型后返回一级，更新当前模型、合法强度与底栏摘要。模型列表和滑杆不常驻并排。浮层支持关闭、键盘操作和窄屏显示，保留发送操作空间。每个普通会话和任务分别保存选择，切换后恢复各自配置，不增加全局默认模型或额外配置页面。</p>
      <p>一级推理面板使用随强度变色的离散滑杆，中部模型入口同时居中显示当前强度与默认/当前模型名，并提供“重置”操作；不使用强度分段按钮或原生下拉。滑杆起点为“默认”自动状态，其后仅包含当前执行器与模型实际支持的有序等级；默认位置表示未显式覆盖，不是额外的推理等级，也不发送新增的 effort 值。重置清除该会话/任务对当前模型的显式强度覆盖，恢复执行器默认策略；默认值未确认时显示“执行器默认”，不推断具体等级。无独立强度能力时滑杆禁用并解释原因，例如 Cursor Auto/Composer 2.5 与 Claude Haiku；Cursor Grok 4.7 仅开放其目录支持的四档。滑杆提供可访问名称、当前值文字和禁用说明，支持方向键逐档调整及 Home/End 到达合法端点。此布局仅用于会话输入框浮层，不回到新建任务表单。</p>
      <p>每次发送或启动 Run 时冻结执行器、模型 ID、模型显示名与推理强度，回复和运行记录显示本次配置快照。选择“执行器默认”时保留默认策略；实际执行器返回了生效强度才记录实际值，未返回则显示未确认，不伪造等级。请求值与实际生效值发生回退时分别留存并说明。运行中修改只影响下一次，旧运行和历史回复保持原配置。切换执行器保留同一个逻辑 Conversation 的历史；正式协议无法跨执行器复用时，为该 Conversation 创建并关联新的 executorSession，不伪装成继承另一执行器内部上下文。</p>
      <p>推理强度控件随当前合法档位改变颜色：默认使用中性蓝灰，低、中、高、超高、最高、Ultra 逐步从冷蓝过渡到紫色；滑轨、闪电图标、当前强度文字和输入框强度标签保持同色，同一档位在不同执行器下配色一致。无强度能力时使用中性禁用样式；始终保留当前值文字与可访问值，不能只靠颜色区分。</p>\n      <p>未提供独立强度能力或尚未验证时，显示“执行器默认”或“未开放”，禁用强度滑杆并说明原因，不发送臆造的 effort 参数。能力刷新导致已保存模型或强度不再可用时，说明原因与实际回退选项；回退仅影响下次运行，并在该 Run 快照记录，不能静默改写历史。</p>
      <p>模型列表按 2026-10-07 核对的精确版本展示，不再只显示家族名称。正式产品从所选执行器/账户获取目录并刷新缓存，保留实际 API ID、能力来源和检查时间；不得以 latest 等浮动别名冒充版本。Auto 是路由模式，无固定模型版本。HTML 使用离线目录快照和模拟回复，不自动实时同步；目录更新只影响后续选择，不改写历史 Run 名称。</p>
      <table><thead><tr><th>原型执行器</th><th>模型版本与推理强度</th><th>目录来源与验证边界</th></tr></thead><tbody>
        <tr><td>Codex</td><td>GPT-6.1-Sol、GPT-6-Astra、GPT-6-Sol、GPT-6-Luna、GPT-5.6-Sol、GPT-5.6-Terra、GPT-5.6-Luna。两款 Luna 为 low / medium / high / xhigh / max，其余加 ultra；6.1-Sol 与 5.6-Sol 默认 low，其余默认 medium。</td><td>本机 CLI 0.160.1 的公开目录缓存，获取时间 <code>2026-10-07T03:49:48.735814Z</code>；仅展示 7 个可见条目，不显示 hidden。API ID 保留为目录中的 <code>gpt-6.1-sol</code> 等精确值；本轮实时 model/list 初始化被只读探针阻断，缓存读取不证明模型推理授权。<a href="research/codex-model-catalog.json">目录核对记录</a>。</td></tr>
        <tr><td>Claude</td><td>Fable 5.1（<code>claude-fable-5-1</code>）、Opus 5.5（<code>claude-opus-5-5</code>）、Sonnet 5.5（<code>claude-sonnet-5-5</code>）：low / medium / high / xhigh / max；Haiku 4.5（<code>claude-haiku-4-5-20251001</code>）：无独立 effort。</td><td>按官方当前模型目录与 Claude Code 强度文档核对；SDK 账户可用范围仍需实际接入确认，选择默认时跟随执行器，不臆造默认档位。<a href="https://platform.claude.com/docs/en/models/overview" target="_blank" rel="noopener">模型目录</a> / <a href="https://code.claude.com/docs/en/model-config#adjust-effort-level" target="_blank" rel="noopener">强度说明</a> / <a href="research/claude-model-catalog.json">核对记录</a>。</td></tr>
        <tr><td>Cursor</td><td>主要列表为 Auto、Grok 4.7、Composer 2.5（<code>composer-2.5</code>）。Grok 4.7 使用目录返回的 <code>grok-4.7-{low,medium,high,xhigh}</code> 四档；Auto 与 Composer 2.5 无独立 effort。</td><td>本机 CLI 目录实测，ACP 配置实现为源码证据；主列表按用户要求只展示这三个系列，不将其视为完整账户目录。Auto 不编造版本号，fast 变体不混入本次主要列表；真实 ACP 切换与推理效果待联调。</td></tr>
      </tbody></table>
      <h3 id="conversation-execution-permissions" style="scroll-margin-top:150px">会话权限与执行隔离 · FR-18</h3>
      <p>输入框底部工具栏左侧以盾牌图标和权限摘要打开菜单，与右侧模型入口并列。菜单参考 Codex，仅列“请求批准”“帮我批准”“完全访问权限”三行，选中项勾选；不展示沙箱、审批策略、审批方的多字段表单，也不提供高级入口或额外设置页。按当前执行器和模型能力禁用不可用项并简短说明原因，不承诺三个执行器有相同边界；Claude 完全访问权限须有原生启动授权，不能伪造已授权。</p>
      <p>普通会话与任务各自按执行器保存选择，切换执行器恢复此前配置；点击预设后显式保存并更新摘要，只影响下一次回复/Run，旧运行与历史快照不变。跟随执行器、未知或已有自定义组合只显示当前状态短说明，不冒充某个预设，不自动勾选三行之一；无法适用的已保存配置提示重选。后台分别记录隔离与审批请求、实际生效策略及证据，未确认时保持未知，不能仅凭选择菜单标为已沙箱。</p>
      <h3 id="executor-auth-check" style="scroll-margin-top:150px">执行器认证状态检查 · FR-17</h3>
      <p>桌面全局侧栏底部的“执行器与认证”入口与窄屏头部齿轮打开同一轻量弹窗，展示 Codex、Claude、Cursor 的本机状态、最后检查时间与结果说明，提供“检查状态”和“重新检测”。项目“…”菜单不再含认证项，桌面头部不重复提供齿轮。弹窗关闭后回到当前工作视图，不占用独立页面；无项目时仍可使用对应的全局入口检查。不提供全局项目设置、Providers 或 Agent 配置页面。执行器的安装与认证状态属于本机；项目只选择执行器，切换项目不会形成不同的登录状态。</p>
      <table><thead><tr><th>状态</th><th>含义与交互</th></tr></thead><tbody>
        <tr><td>未检测</td><td>没有可用检测结果，可手动检查。</td></tr>
        <tr><td>检查中</td><td>执行只读检查，展示进度并避免重复请求。</td></tr>
        <tr><td>未安装</td><td>找不到经校验的目标执行器，显示安装指引；不自动安装。</td></tr>
        <tr><td>未认证 / 需 SDK 凭证</td><td>目标接入方式明确报告未认证，或缺少 SDK 所需凭证；展示对应登录或配置指引。</td></tr>
        <tr><td>已认证</td><td>对应接入方式已返回有效认证状态；不代表目标模型权限、额度或实际 Run 必然可用。</td></tr>
        <tr><td>凭证已配置未验证</td><td>仅确认存在 SDK 凭证或认证配置，尚未证明有效；不能显示为已认证。</td></tr>
        <tr><td>检测失败 / 未知</td><td>超时、网络异常、接口不支持或结果无法识别；保留原因并可重试，不推断为未登录。</td></tr>
      </tbody></table>
      <p>首次使用、切换执行器和启动实际 Run 前自动执行有超时的只读检测；检测不会调用模型、建立任务运行或预热 Agent。待处理任务仍保持模型请求为零。认证方式完成并返回应用后重新检测，仅更新状态，不自动启动任务或重放写操作；明确未安装或未认证时先展示阻塞原因，未知状态按实际证据提示，不能用失败代替登录结论。</p>
      <p>认证、目标模型访问权限、额度与实际运行能力分别展示和验证。凭证由执行器自身或系统凭证设施管理；项目、任务、聊天记录和原型 localStorage 不保存密钥。HTML 只提供明确标注的模拟检查与认证指引，不执行命令、登录、密钥输入或真实凭证验证；实际能力须在 SwiftUI Adapter 实现后联调。</p>
      <h3>可恢复的交互</h3>
      <ul><li>运行中切阶段：显示取消进度，并暂时禁用新运行；取消失败留在原阶段。</li><li>运行中换执行器、模型或推理强度：显示“下次运行生效”，运行详情保留本次快照。</li><li>审批请求：展示操作、目标目录、请求来源与原因；允许、拒绝均进入记录。</li><li>失败或离线：保留已生成内容与日志，显示重试入口和将采用的配置。</li><li>验收后修改代码：显示“结果已过期”，通过按钮要求重新检查。</li></ul>
      <h3>项目普通会话</h3>
      <p>每个项目可以拥有多个普通会话，项目树下展示会话名称并标识当前选中项；点选会话打开其独立消息历史与输入框；聊天内容顶部只读显示项目与当前会话名称，不设置切换下拉，不重复侧栏导航。“新建会话”在该项目下创建空会话，联动选择执行器、模型与支持的推理强度，不自动请求 AI。切换项目后保留各项目的会话记录、执行配置及上次选中状态，用户可直接选择需要继续的会话。尚未导入项目时，先展示导入入口，不创建无项目归属的普通会话。</p>
      <p><strong>删除普通会话：</strong>每条项目普通会话提供“…”更多菜单和右键菜单中的“删除会话”。确认框显示会话名称，取消保持不变；确认后从项目列表移除，刷新或重启后仍不显示。删除当前会话返回其项目看板，不自动新建会话。会话存在未终结运行或进行中的任务导入时禁用删除，提交时再次校验。任务主会话不能单独删除；已导入的看板任务、来源关系和批次审计保留，不随普通会话删除。</p>
      <p>普通会话具有固定 <code>projectId</code>，与任务主会话分开保存，没有待处理、讨论、开发或验收阶段。用户可直接要求读取、修改项目代码或运行命令，由当前执行器、模型、推理强度、原生权限及项目授权目录决定能力；写入前取得同目录唯一写入锁，与任务运行统一协调，不要求先转成看板任务。普通会话 Run 归属 Conversation，<code>taskId</code> 为空，审批、停止、恢复和配置快照同样进入运行记录。代码请求或 AI 建议不自动创建任务；仅用户明确要求转为任务或导入时创建所属项目看板任务，原会话历史保留，新任务使用独立主会话。</p>
      <p>窄屏与移动端原型的当前项目会话入口只打开该项目当前会话，聊天页顶部保持只读名称，不展开会话列表或提供新建、切换下拉。会话列表与新建仍属于项目侧栏。</p>
      <h3 id="task-import-skill">内置任务清单导入 Skill · FR-16</h3>
      <p>用户在项目普通会话通过通用附件按钮提供 <code>.xlsx</code>、<code>.xls</code> 或 <code>.csv</code> 任务表，再发送“将附件任务导入看板”等明确自然语言指令；也可粘贴项目 Issue 列表、单个 Issue 或一组 Issue 链接，并明确要求导入。该指令授权本次任务记录创建，Agent 直接执行，不追加导入审批或统一确认。仅附加文件或发送链接不自动启动导入，也不创建任务；未给出导入指令时只保留附件并继续沟通。</p>
      <p>用户始终在原普通会话中提出要求并接收执行进度与结果，不出现来源选择、字段映射、候选勾选或确认弹窗，也不设置独立导入页面、专属 Skill 按钮或 Agent 页面中的使用入口。</p>
      <ol><li><strong>自动识别与读取：</strong>Agent 从附件或链接识别来源，自动识别含任务的工作表与字段，按用户明确给出的 Issue 仓库、列表筛选和分页范围读取。目标项目固定为发起会话的 <code>conversation.projectId</code>，不随侧栏选中项目变化。</li><li><strong>标准化与去重：</strong>将来源整理为标题、描述、可选类型/优先级和来源。标题缺失或无法形成有效任务的行跳过并保留错误原因；稳定来源键相同的任务自动跳过，不覆盖已有任务。读取完整后，对有效且未重复的任务形成内部提交记录，无需用户映射字段或勾选候选。</li><li><strong>直接创建：</strong>以一个幂等事务提交本批次有效任务与来源记录，所有新任务进入“待处理”并拥有独立主会话，执行目录初始采用目标项目 <code>project.path</code>，创建后可在任务详情选择 Git Worktree，按 FR-01 采用该项目默认执行器与执行器原生默认配置，不复制导入会话的运行配置。事务失败整体回滚；重试同批次或重复发送相同来源不重复创建。仅有个别坏行时可提交其余有效行，并在结果区分创建、重复跳过和错误跳过。</li><li><strong>会话报告：</strong>回复导入来源与实际范围、创建数量、跳过重复数量和错误原因；列出可打开的任务编号。新任务不自动运行 AI、启动开发或推进阶段。完整读取失败或提交失败时明确说明创建数量为零，避免把失败描述成部分成功。</li></ol>
      <p><strong>必要澄清与授权：</strong>来源无法识别、工作表/Issue 范围存在歧义时，只在会话中请求完成本次导入所必需的信息；私有来源权限不足时提示连接并授权账户，不要求在聊天中发送凭证。澄清或连接完成后继续原指令，不增加任务选择或确认步骤。读取失败期间不写入任务；提交前取消创建零任务，已完成的导入不会因停止后续运行而自动删除。</p>
      <p><strong>来源与去重：</strong>Issue 使用供应方/域名、规范仓库标识和 Issue 编号组成 <code>sourceKey</code>；同一 Issue 出现在列表与单链接中时识别为重复。表格优先使用来源范围加稳定任务键；没有稳定键时，以文件/工作表来源及规范化任务内容生成去重键并自动处理。每项任务保留 <code>provenance</code>、<code>sourceKey</code> 和 <code>importBatchId</code>，便于追溯原始行或链接。</p>
      <p><strong>实现边界：</strong>这是产品内置 Skill，执行器候选仍为 Codex、Claude、Cursor 三种。解析、来源读取、去重和事务提交可由应用层 ImportService 完成；执行器缺少 Skill 调用能力时，由应用识别聊天中的明确导入请求并在原会话返回结果，保持相同交互。外部内容只作为任务数据，不扩大指令授权范围，也不触发代码执行、外部发布或任务阶段推进。实际工作簿解析、Issue 授权读取与分页适配在实现阶段验证。</p>
      <p class="callout">HTML 中的 Excel 与 Issue 导入使用示例任务与结果，不能视为已解析上传的工作簿或已抓取真实远程 Issue。CSV 只有在实际解析本地文件并验证后才标注为已解析；示例自动导入仅更新原型的演示记录。</p>
      <p class="callout">原型中的回复、耗时和检查结果均为演示数据；界面状态变化用于验证交互逻辑，不能证明执行器已接通。</p>

      <h3>任务目录与等待队列 · FR-06/07/14</h3>
      <p>任务详情提供“项目目录 / Git Worktree”选择，默认项目目录。Worktree 放在应用数据目录 <code>Worktrees/&lt;project-id&gt;/&lt;task-id&gt;</code>，使用独立 <code>codex/kanban-&lt;task-id&gt;</code> 分支，从项目当前已提交 HEAD 创建；没有初始提交时说明原因。不会复制未提交改动、自动提交、合并或删除；已有目录/分支冲突安全报错，相同合法 Worktree 可重用。</p>
      <p>同目录已有写入者时，直接开发、确认方案后的开发和普通会话请求均直接进入持久等待队列，不弹占用错误；在会话与全局“运行中”显示“排队中”并支持取消。排队不启动进程、不持目录锁，按同 canonical cwd 的 FIFO 顺序启动；不同 cwd 可并行。当前写入者停止确认后才交接，待恢复且未核对的运行仍占位。重启保留 queued；已启动或启动不确定的请求先恢复核对。</p>
`
  },
  {
    id: "architecture",
    title: "技术架构与执行器边界",
    kicker: "本地架构",
    body: `
      <p><span class="status proposed">建议</span>采用“SwiftUI → Swift actor TaskEngine → Agent Adapter → 独立 Agent 进程”的结构；SwiftUI 界面以 macOS 26.0 为最低系统要求，使用系统 Liquid Glass 与原生控件；SQLite/GRDB 保存任务、会话和运行数据。TaskEngine 统一处理阶段权限、队列、审批、取消与事件归属，界面订阅状态变化。</p>
      <table><thead><tr><th>执行器候选（用户暂定）</th><th>接入方式与验证状态</th></tr></thead><tbody>
        <tr><td>Codex</td><td>建议评估 app-server；会话、审批、运行控制与实际模型可用性均待实测。</td></tr>
        <tr><td>Claude</td><td>建议评估 Agent SDK 桥接进程；权限、会话恢复等能力待实测。</td></tr>
        <tr><td>Cursor</td><td>建议优先验证本地 CLI 的 ACP 接入；官方 SDK Bridge 为备选，Headless CLI 适合短任务。已完成文档调研、初始化握手、CLI 强度目录与 ACP 源码核对，真实任务能力待实测。<a href="#cursor-integration">查看接入方案与验收项</a>。</td></tr>
      </tbody></table>
      <p>候选范围由用户暂定为以上三种，未表示全部已接通或已验证兼容；首个实现与接入顺序仍待定。执行器、模型与推理强度联动配置，可用范围以所选执行器的实际能力为准。Adapter 建议统一提供模型目录及强度能力声明、只读安装/认证状态检测、创建/恢复会话、提交消息并启动运行、事件订阅、审批响应、取消运行与健康检查；能力不支持时明确限制对应选项。逻辑 Conversation、executorSession 与 Run ID 分开保存，恢复会话不能隐式重放已执行操作。</p>
      <h3>模型目录与推理强度的适配契约 · FR-04</h3>
      <p>Adapter 返回实际 API 模型 ID、包含精确版本的显示名、可用状态、支持的推理强度与可确认的执行器默认强度，同时记录能力来源、检查时间及账户可用范围，并刷新本地缓存。浮动别名与固定版本分别记录；Auto 等路由模式按执行器原名展示，不编造版本。配置提交前核对执行器 + 模型组合；能力缺失或未知时保留“执行器默认/未开放”，不把不同执行器的等级名称强行视为等价，也不发送未声明参数。跨执行器切换仅复用逻辑会话记录，executorSession 的创建、恢复及上下文传递必须按各 Adapter 的实际协议处理。</p>
      <table><thead><tr><th>执行器 / 协议</th><th>能力依据与接入边界</th></tr></thead><tbody>
        <tr><td>Codex app-server</td><td>本机生成的静态 JSON schema 中，<code>ModelListResponse.Model</code> 包含 <code>model</code>、<code>displayName</code>、<code>supportedReasoningEfforts</code> 与 <code>defaultReasoningEffort</code>；<code>TurnStartParams</code> 可按轮次覆盖 <code>model</code> 和 <code>effort</code>。已核对协议结构并读取本机新鲜公开目录缓存；实时 model/list 探针在初始化前被只读限制阻断，未调用模型，实际目录刷新与执行行为待联调。<a href="https://developers.openai.com/codex/app-server" target="_blank" rel="noopener">app-server 文档</a>。</td></tr>
        <tr><td>Claude Agent SDK</td><td>SDK 提供 <code>model</code> / <code>effort</code>，按精确模型版本开放合法等级；当前 Fable 5.1 / Opus 5.5 / Sonnet 5.5 支持五档，Haiku 4.5 无独立 effort。Agent SDK 的默认强度未明确，空值跟随执行器，不把 API 默认或 Claude Code 默认推作 SDK 默认。<a href="https://code.claude.com/docs/en/agent-sdk/python" target="_blank" rel="noopener">SDK 参考</a>。</td></tr>
        <tr><td>Cursor CLI / ACP</td><td>本机 CLI 模型目录已返回 low/high/xhigh/max 等变体，并明确支持 <code>--model '模型ID[effort=high]'</code> 参数表达。当前版本 ACP 源码返回 <code>models</code> / <code>configOptions</code> 并实现模型配置；声明版本特定的参数选择扩展时可分离强度。Adapter 按实际返回的合法参数或复合模型选项发送，不自行拼接后缀；未知版本与无强度模型回退执行器默认。实际 ACP 会话切换及推理行为仍待联调。<a href="https://cursor.com/docs/cli/reference/parameters" target="_blank" rel="noopener">CLI 参数</a> / <a href="https://cursor.com/docs/cli/acp" target="_blank" rel="noopener">Cursor ACP</a> / <a href="https://agentclientprotocol.com/protocol/v1/session-config-options" target="_blank" rel="noopener">ACP 配置规范</a>。</td></tr>
      </tbody></table>
      <h3 id="native-permission-contract" style="scroll-margin-top:150px">原生权限与隔离适配契约 · FR-18</h3>
      <p>三行名称统一产品意图，不保证每次操作都询问或三个执行器权限边界相同。下表字段仅供 Adapter 实现与验证，不在用户权限菜单并列显示。普通会话使用所属项目目录，任务默认使用项目目录并可选择本项目登记的 Git Worktree；沙箱控制文件系统/网络边界，审批控制操作能否请求许可。独立 cwd 或 Git Worktree 本身不等于 OS 沙箱。普通会话按当前原生权限直接执行代码工作，服从项目授权目录与唯一写入锁；仅看板任务额外受阶段收紧，讨论/验收只读、开发在授权目录执行。明确要求的隔离不可用或无法覆盖本次范围时阻止启动，不静默降级，也不擅用 force 绕过。</p>
      <table><thead><tr><th>执行器</th><th>请求批准</th><th>帮我批准</th><th>完全访问权限</th></tr></thead><tbody>
        <tr><td>Codex</td><td>sandbox: workspace-write；approvalPolicy: on-request；approvalsReviewer: user；工作区内获准执行，越界操作按需请求批准。</td><td>sandbox: workspace-write；approvalPolicy: on-request；approvalsReviewer: auto_review；自动评估审批请求，不扩大沙箱。</td><td>sandbox: danger-full-access；approvalPolicy: never；approvalsReviewer: user（此策略下不产生审批）。</td></tr>
        <tr><td>Claude Agent SDK</td><td>sandbox.enabled: true；autoAllowBashIfSandboxed: false；permissionMode: default。</td><td>sandbox.enabled: true；autoAllowBashIfSandboxed: false；permissionMode: auto；由原生分类器判断审批，Haiku 禁用，其他模型须 provider/版本及账户/组织允许。</td><td>sandbox.enabled: false；permissionMode: bypassPermissions；默认禁用，仅执行器允许且原生会话启动已授权时可用。</td></tr>
        <tr><td>Cursor CLI / ACP</td><td>sandbox: enabled；approvalMode: allowlist；命中 allow 规则的操作可直接执行，不保证逐操作询问。</td><td>sandbox: enabled；approvalMode: auto-review。</td><td>sandbox: disabled；approvalMode: unrestricted；已有拒绝规则继续有效。</td></tr>
      </tbody></table>

      <table><thead><tr><th>执行器</th><th>原生配置与产品适配边界</th></tr></thead><tbody>
        <tr><td>Codex</td><td>沙箱为 <code>read-only</code> / <code>workspace-write</code> / <code>danger-full-access</code>；审批策略新选择仅 <code>on-request</code> / <code>never</code>，<code>untrusted</code> 仅兼容已有 schema，弃用的 <code>on-failure</code> 不开放。审批者为 <code>user</code> / <code>auto_review</code>，自动审查不扩大沙箱；<code>never</code> 也不等于关闭沙箱。按实际协议在 thread/start、thread/resume 提交 sandbox、approvalPolicy、approvalsReviewer，在 turn/start 使用 sandboxPolicy 及对应审批字段；工作区可写根目录与网络访问另按能力声明。<a href="https://learn.chatgpt.com/docs/sandboxing" target="_blank" rel="noopener">沙箱</a> / <a href="https://learn.chatgpt.com/docs/config-file/config-reference" target="_blank" rel="noopener">配置</a> / <a href="https://learn.chatgpt.com/docs/sandboxing/auto-review" target="_blank" rel="noopener">自动审批</a>。</td></tr>
        <tr><td>Claude Agent SDK</td><td>permissionMode 为 <code>default</code> / <code>acceptEdits</code> / <code>plan</code> / <code>auto</code> / <code>dontAsk</code> / <code>bypassPermissions</code>；Haiku 不支持 auto，其余模型仍须核对组织/账户能力。bypass 仅在会话启动已启用且执行器允许时开放；plan 是权限模式，不能独自证明只读。Shell 沙箱使用 <code>sandbox.enabled</code>，并由 <code>autoAllowBashIfSandboxed</code> 区分正常审批与沙箱内自动批准；范围仅 Shell 及子进程的文件/网络，Read/Edit/Write/Web/MCP/hooks 及宿主 helper 不自动受该 Shell 沙箱保护，必须结合 SDK permissions / canUseTool 与宿主路径校验，任务运行另加阶段校验，不能将整个 Agent 标记为全工具 OS 隔离。明确启用隔离时要求 <code>failIfUnavailable: true</code>、<code>allowUnsandboxedCommands: false</code>、<code>excludedCommands: []</code>，macOS 使用原生 Seatbelt；默认跟随执行器，不恒定解释为手动审批。<a href="https://code.claude.com/docs/en/agent-sdk/permissions" target="_blank" rel="noopener">SDK 权限</a> / <a href="https://code.claude.com/docs/en/sandboxing" target="_blank" rel="noopener">沙箱范围</a> / <a href="https://code.claude.com/docs/en/agent-sdk/python#sandboxsettings" target="_blank" rel="noopener">SandboxSettings</a>。</td></tr>
        <tr><td>Cursor CLI / ACP</td><td>CLI 使用 <code>--sandbox enabled|disabled</code>；approvalMode 为 <code>allowlist</code> / <code>auto-review</code> / <code>unrestricted</code>，未指定时跟随执行器配置。官方 ACP 已记载 agent/plan/ask 和权限交互，未保证在线修改沙箱；保存下次启动配置并按需重建协议会话，保留逻辑聊天与历史。模型/强度配置能力不能推导出安全参数也支持 session/set_config_option。<a href="https://cursor.com/docs/cli/reference/configuration" target="_blank" rel="noopener">CLI 配置</a> / <a href="https://cursor.com/docs/cli/reference/permissions" target="_blank" rel="noopener">权限</a> / <a href="https://cursor.com/docs/cli/acp" target="_blank" rel="noopener">ACP</a>。</td></tr>
      </tbody></table>
      <p class="callout">HTML 只演示选项、配置恢复和快照，不运行执行器或验证真实 OS 隔离。正式接入必须分别验证配置是否接受、实际文件/网络边界、审批拒绝与强制停止；不能把原生字段存在当作运行隔离已通过。<a href="research/executor-sandbox-capabilities.json">原生权限与隔离核对记录</a>。</p>
      <h3>认证检测的接入约束</h3>
      <table><thead><tr><th>执行器</th><th>检测路线与证据边界</th></tr></thead><tbody>
        <tr><td>Codex</td><td>评估 CLI <code>login status</code> 或 app-server 的账户接口；能力、输出解析及与实际接入方式的对应关系待联调。身份状态不能代替模型访问或额度验证。</td></tr>
        <tr><td>Claude</td><td>CLI <code>auth status</code> 只说明相应 CLI 状态，不直接证明 PRD 采用的 Agent SDK 可用。SDK 检测 API key 或官方支持的云认证配置，存在凭证时先显示“凭证已配置未验证”；第三方产品不能默认复用 claude.ai 订阅登录。<a href="https://code.claude.com/docs/en/agent-sdk/quickstart" target="_blank" rel="noopener">SDK 认证要求</a> / <a href="https://code.claude.com/docs/en/cli-reference" target="_blank" rel="noopener">CLI 参考</a>。</td></tr>
        <tr><td>Cursor</td><td>本机 CLI <code>status</code> 已返回认证状态，模型目录读取成功；使用校验过的可执行文件绝对路径，不用裸命令 <code>agent</code>，以免命中本机 Grok 等其他产品。未执行登录动作；实际问答、模型权限/额度与 ACP 认证衔接仍待联调。<a href="https://cursor.com/docs/cli/reference/authentication" target="_blank" rel="noopener">CLI 鉴权</a>。</td></tr>
      </tbody></table>
      <p>检测器报告接入方式、可执行文件身份、状态来源、检查时间及脱敏错误信息，不输出凭证。状态检查采用独立探测生命周期，超时后回收探测进程并允许重试，不创建业务 Run；认证引导完成后的重新检测也不重放历史操作。</p>
      <p>事件附带 ownerType、conversationId、可空 taskId、runId、agentRunId 和适用的阶段版本；过期事件只归档到旧运行。工作目录锁由调度层持有，进程结束且锁释放后才能交接写入权。</p>
      <h3 id="cursor-integration" style="scroll-margin-top:150px">Cursor 接入调研 · 2026-10-06，10-07 补充</h3>
      <div class="callout"><strong>建议路线：SwiftUI → CursorAdapter → Cursor CLI ACP。</strong>ACP 提供双向会话与权限交互，适合作为本产品的首个 Cursor 可行性探针；SDK Bridge 保留为备选。此结论只决定 Cursor 内部接入路线的建议，不改变 Codex、Claude、Cursor 三种候选的实现顺序。</div>
      <p><span class="status confirmed">文档确认</span>官方支持通过 <code>agent acp</code> 启动 ACP 服务，以标准输入/输出传输逐行 JSON-RPC；包含会话创建/加载、消息更新、工具权限请求与取消。模式包括 agent、plan、ask，后两者文档定义为只读。<a href="https://cursor.com/docs/cli/acp" target="_blank" rel="noopener">Cursor ACP 官方文档</a>。</p>
      <p><span class="status proposed">10-06 本机探测</span>现有 <code>cursor-agent</code> 版本为 <code>2026.09.10-fd3934a</code>；<code>help acp</code> 与初始化请求成功，返回协议版本 1、<code>loadSession: true</code>。仅验证握手和能力声明，未验证登录、模型请求、实际恢复或工具运行；探针进程已终止。由于本机裸命令 <code>agent</code> 指向其他产品，Adapter 必须保存经校验的可执行文件绝对路径，不能只依赖 PATH。<a href="research/cursor-integration-probe.json">查看探针记录</a>。</p>
      <p><span class="status confirmed">10-07 补充核对</span>同版本 CLI 的 <code>status</code> 返回已认证，<code>models</code> 成功返回账户可用模型及强度变体，例如 GPT-5.3 Codex 的 low/high/xhigh、Sonnet 的 low/medium/high/xhigh/max；命令提示明确支持 <code>--model 'claude-opus-4-8[context=1m,effort=high,fast=false]'</code>。这是参数语法示例，不保证示例模型对当前账户可用。Auto/Composer 未列独立强度，不套用其他模型等级。官方 SDK 另明确支持 <code>model.params</code> 的 reasoning effort，并要求通过 <code>Cursor.models.list()</code> 发现每个模型的参数、合法值与 variants。<a href="https://cursor.com/docs/sdk/typescript#model-parameters" target="_blank" rel="noopener">官方模型参数</a> / <a href="research/cursor-reasoning-probe.json">补充核对记录</a>。</p>
      <p><strong>ACP 源码证据：</strong>本机版本的 CursorAcpAgent 实现返回模型及配置选项，提供 <code>setSessionConfigOption</code> 和模型切换入口；客户端声明 <code>clientCapabilities._meta.parameterizedModelPicker = true</code> 时分离模型参数，并将 effort/reasoning/thinking 类参数归入 <code>thought_level</code>。这是 Cursor 当前版本的扩展；未声明时使用返回的复合模型变体，不能将扩展视为通用 ACP 保证。源码核对与 CLI 目录证实存在配置路径，尚未发起模型请求，也不等于已验证真实会话切换、推理效果、工具审批或停止。</p>
      <h3>接入方式比较</h3>
      <table><thead><tr><th>方式</th><th>官方能力与限制</th><th>本产品建议</th></tr></thead><tbody>
        <tr><td>CLI ACP · 优先验证</td><td>本地进程、双向协议、持续会话、事件流、权限交互；每项能力按实际握手确认。</td><td>Swift 原生实现 Process/Pipe 与协议客户端，优先验证审批和阶段停止闭环。<a href="https://cursor.com/docs/cli/acp" target="_blank" rel="noopener">官方说明</a></td></tr>
        <tr><td>官方 SDK / SDK Bridge · 备选</td><td>TypeScript/Python SDK 可运行本地 Agent；Bridge 面向其他语言，以 loopback HTTP/1.1 的 Connect/protobuf 暴露 Agent/Run 接口，提供 macOS 二进制。</td><td>Swift 可封装 Bridge，无需依赖 IDE 窗口；需维护协议、流和进程生命周期，人工审批另行设计。<a href="https://cursor.com/docs/sdk/bridge" target="_blank" rel="noopener">Bridge 文档</a></td></tr>
        <tr><td>Headless CLI · 批处理备用</td><td><code>-p --output-format stream-json</code> 输出结构化事件；文字增量需加 <code>--stream-partial-output</code>。支持指定工作区、模型和恢复会话。</td><td>适合短检查或自动化任务；单向输出不替代 ACP 双向审批。不得以 print 模式或未传 force 推断只读。<a href="https://cursor.com/docs/cli/reference/parameters" target="_blank" rel="noopener">参数</a> / <a href="https://cursor.com/docs/cli/reference/output-format" target="_blank" rel="noopener">输出格式</a></td></tr>
        <tr><td>Cloud Agents API · 后续扩展</td><td>v1 为 public beta，支持 Agent/Run、SSE 与取消；目标可选 cloud、machine、pool。</td><td>My Machines 也能在本机执行工具，但需要 worker 和云端调度。当前本地直接接入优先，云调度不加入首版。<a href="https://cursor.com/docs/cloud-agent/api/endpoints" target="_blank" rel="noopener">API</a> / <a href="https://cursor.com/docs/cloud-agent/self-hosted/my-machines" target="_blank" rel="noopener">My Machines</a></td></tr>
        <tr><td>MCP / IDE 打开入口</td><td>可给 Agent 提供工具或打开编辑器；仅有工具配置或窗口启动不能证明会话与运行控制可用。</td><td>MCP 作为工具层；不替代 CursorAdapter，也不作为第四种执行器。</td></tr>
      </tbody></table>
      <h3>SwiftUI 与 ACP 的适配契约</h3>
      <p><span class="status proposed">产品实现要求</span>CursorAdapter 为每个任务/普通会话使用独立 ACP 进程，由 Swift actor 串行管理请求关联、事件归属与停止屏障。当前版本源码的模型管理器会同步同进程全部会话并写入 CLI 模型偏好，因此仅拆分 sessionId 不足以隔离配置；不同进程仍须验证共享持久偏好与并发启动的影响，并在每次 Run 前显式应用冻结配置。标准输出只解析协议，标准错误进入脱敏日志；处理 UTF-8 分片、多条消息、未知扩展和进程退出。只有明确启动运行时才建立执行器会话，待处理任务禁止模型请求和工作区预热。</p>
      <table><thead><tr><th>看板能力</th><th>ACP 映射与产品约束</th></tr></thead><tbody>
        <tr><td>握手 / 能力</td><td><code>initialize</code> 协商版本，记录完整能力快照；不兼容则停止连接。当前 Cursor 文档与本机探针为 v1 形态，不直接假设兼容 v2 或全部 ACP 能力。<a href="https://agentclientprotocol.com/protocol/v1/initialization" target="_blank" rel="noopener">初始化规范</a></td></tr>
        <tr><td>稳定主会话 / 恢复</td><td>Conversation 关联各执行器的 <code>sessionId</code>，任务会话绑定所属项目目录或已验证的任务 Worktree cwd；更换执行器不假设可直接复用旧协议会话。项目目录失效时阻止新运行，历史绑定路径保留为证据，不伪造迁移或重写历史 cwd。使用 <code>session/new</code>，仅在 <code>loadSession</code> 支持时调用 <code>session/load</code>。恢复历史重放与新消息分开处理；恢复失败保留本地记录，不自动重放写操作。<a href="https://agentclientprotocol.com/protocol/v1/session-setup" target="_blank" rel="noopener">会话规范</a></td></tr>
        <tr><td>一次运行 / 输出</td><td>每次 <code>session/prompt</code> 关联本地 Run ID；<code>session/update</code> 归档文字与工具事件。最终 <code>stopReason</code> 决定轮次状态，保留正常结束、拒绝、限额与取消等区别；正常结束不推进看板阶段。<a href="https://agentclientprotocol.com/protocol/v1/prompt-turn" target="_blank" rel="noopener">轮次规范</a></td></tr>
        <tr><td>模式 / 模型 / 推理强度</td><td>任务讨论建议 plan/ask，开发 agent，任务验收和独立审查只读；测试命令由受控测试执行器运行。普通会话可使用 agent 模式按当前原生权限直接工作，不套用任务阶段。从 <code>session/new</code> 返回的模型与配置读取能力，用 <code>session/set_config_option</code> 或模型切换接口提交；参数选择扩展按版本验证，未开放时选用执行器返回的复合变体。仅提交目录声明的模型和强度，无明确强度能力时使用执行器默认。当前源码已确认配置实现，实际会话接受与生效仍须联调。每次 Run 冻结配置，变更下次生效。<a href="https://agentclientprotocol.com/protocol/v1/session-config-options" target="_blank" rel="noopener">配置规范</a></td></tr>
        <tr><td>工具审批</td><td><code>session/request_permission</code> 映射 Approval，展示操作、路径、来源 Run；按请求给出的 <code>optionId</code> 返回决定。拒绝一次与整轮取消分别记录，不编造“始终允许”的记忆范围。<a href="https://agentclientprotocol.com/protocol/v1/tool-calls#requesting-permission" target="_blank" rel="noopener">权限规范</a></td></tr>
      </tbody></table>
      <p>Cursor 还定义 <code>cursor/ask_question</code> 和 <code>cursor/create_plan</code> 等扩展交互，客户端必须提供回答或拒绝路径，避免 Run 因未响应而悬挂。<code>cursor/task</code> 等内部任务事件可用于展示，但不据此承诺每个内部子 Agent 可独立停止。首版仍由 TaskEngine 创建可控的独立顶层会话，验证后才开放内部派生能力。<a href="https://cursor.com/docs/cli/acp" target="_blank" rel="noopener">Cursor 扩展说明</a>。</p>
      <h3>停止、权限与凭证</h3>
      <p><strong>停止屏障：</strong><code>session/cancel</code> 是无响应通知，发送后 Run 显示“正在取消”；待决权限请求返回取消，继续接收尾部事件，等原 prompt 返回 <code>stopReason: cancelled</code>。同时核实工具和宿主拥有的子进程已结束、队列已清空，再释放写入锁并切阶段。超时先终止本次拥有的进程树；无法确认工具停止则留在原阶段并阻塞新写入。具体超时值在联调后确定。<a href="https://agentclientprotocol.com/protocol/v1/prompt-turn#cancellation" target="_blank" rel="noopener">取消规范</a>。</p>
      <p><strong>只读约束：</strong>ACP 是通信协议，<code>cwd</code> 与客户端不提供文件/终端能力不构成沙箱。plan/ask 配合 Cursor 权限规则与实际隔离验证；任务写入、Shell、MCP 都纳入阶段权限，不能只限制文件编辑工具；普通会话按当前原生权限与项目授权范围处理。路径与符号链接边界、子进程回收是产品自己的要求，不承诺拦截全部 Agent 内部访问。Cursor 权限文档定义 Read/Write/Shell/Mcp 规则且 deny 优先。<a href="https://agentclientprotocol.com/get-started/architecture" target="_blank" rel="noopener">ACP 架构</a> / <a href="https://cursor.com/docs/cli/reference/permissions" target="_blank" rel="noopener">Cursor 权限</a>。</p>
      <p><strong>登录与凭证：</strong>优先使用 Cursor CLI 的浏览器登录与自身凭证管理，可在启动前执行 login；ACP 认证按官方 <code>authenticate</code> / <code>cursor_login</code> 流程接入。自动化可使用 API key。产品不把密钥放进命令参数、聊天或日志；如需自行保存，评估 Keychain 并仅向目标进程传递。SDK Bridge 另有每进程 bearer token，不等同于 Cursor API key，也不假设自动继承 IDE 登录。<a href="https://cursor.com/docs/cli/reference/authentication" target="_blank" rel="noopener">CLI 鉴权</a> / <a href="https://cursor.com/docs/sdk/bridge#authentication" target="_blank" rel="noopener">Bridge 鉴权</a>。</p>
      <h3>SDK Bridge 备用路线的附加条件</h3>
      <p>官方 SDK 支持本地持久 Agent、Run、恢复和工具集限制，但 Headless SDK 不提供人工逐次审批，沙箱默认关闭，Auto-review 不作为安全边界。若改用 Bridge，必须补齐本产品审批链路，每次创建/恢复显式应用权限策略；<code>tools</code>、<code>disallowedTools</code>、内联 MCP 等配置恢复时需重传。本地执行仍使用 Cursor 托管模型。<a href="https://cursor.com/docs/sdk/typescript" target="_blank" rel="noopener">SDK 能力与限制</a>。</p>
      <p>Bridge 断流不能视为取消，必须调用取消接口并确认最终状态；恢复事件流使用对应流的 offset。固定 Bridge/协议版本，校验 ready 握手，管理独立 bearer token 与关闭过程；Loopback 只绑定本机。<a href="https://github.com/cursor/sdk-bridge/blob/main/docs/streaming.md" target="_blank" rel="noopener">Bridge 流规范</a> / <a href="https://github.com/cursor/sdk-bridge/blob/main/docs/protocol.md" target="_blank" rel="noopener">生命周期规范</a>。</p>
      <h3>Cursor 接入的验收门槛 · FR-12/13/14</h3>
      <table><thead><tr><th>探针 / 验收项</th><th>通过条件与当前状态</th></tr></thead><tbody>
        <tr><td>可执行文件 / 握手</td><td>校验供应方、绝对路径、版本与协议；本机已验证初始化。完整兼容矩阵与后续版本行为待测。</td></tr>
        <tr><td>登录 / 模型 / 主会话</td><td>一次真实只读问答成功；记录实际模式/模型；应用重启后加载同一会话，历史不重复、不重放工具。待联调。</td></tr>
        <tr><td>阶段权限 / 审批</td><td>讨论与审查拒绝编辑、写入 Shell/MCP 和越界路径；开发以任务已选的项目目录或 Worktree 为冻结 cwd，并按原生权限执行写入；批准、拒绝、取消及问题/方案交互均有可回溯结果。待联调。</td></tr>
        <tr><td>取消 / 阶段切换</td><td>模型生成、执行命令、等待审批和子任务四类运行均可停止；终止确认后才切阶段；取消异常阻塞新写入，迟到事件只进入旧 Run。待联调。</td></tr>
        <tr><td>并行 / 故障恢复</td><td>两个不同项目目录的任务使用独立 ACP 进程并行，同项目写入任务串行，模型/强度配置互不串用；验证 CLI 持久模型偏好及并发启动，Run 前显式应用配置；同目录仅一写入者；断网、断流、进程崩溃、应用重启均先核对旧运行与锁。待联调。</td></tr>
        <tr><td>验收证据</td><td>开发停止后只读审查冻结快照，报告绑定需求版本与代码指纹；代码变化使报告失效。Cursor 结束轮次不会自动完成任务。待联调。</td></tr>
      </tbody></table>
      <p class="source">调研使用 Cursor 与 ACP 官方资料、本机 CLI 返回及已安装版本源码；文档、目录/静态源码、协议探针、真实任务联调分别标注。Cursor ACP 对项目/用户 MCP 配置的支持不等于支持团队 Dashboard MCP；需在探针中核对实际服务器与阶段权限。尚未调用模型、安装或升级执行器，也未实现 SwiftUI Adapter。</p>
    `
  },
  {
    id: "data",
    title: "数据实体与一致性",
    kicker: "数据契约",
    body: `
      <table><thead><tr><th>实体</th><th>关键字段 / 关系</th></tr></thead><tbody>
        <tr><td>Project</td><td>项目 ID、名称、规范化仓库根路径、默认执行器、最近选中的普通会话 ID、活动状态、可选内部移除标记/时间、目录访问状态与创建时间；同规范路径仅限制活动项目重复。</td></tr>
        <tr><td>Task</td><td>所属项目 ID、可选 worktreePath（缺省使用 project.path，非空须为本项目登记的独立 Git Worktree）、标题、描述、可选类型/优先级、阶段、阶段版本、可选 <code>directImplementationPhaseVersion</code>（仅匹配此次开发阶段的明确跳过方案确认授权，旧记录缺省为空）、主会话 ID、执行器选择（创建时取项目默认值，后续独立保存）、模型 ID/显示名或执行器默认策略、推理强度选择、按执行器保存的权限与隔离选择、需求版本；导入任务另存 provenance、sourceKey、importBatchId。</td></tr>
        <tr><td>Conversation</td><td>逻辑会话 ID、名称、固定所属项目 ID；任务主会话 / Agent 子会话 / 项目普通会话三种类型；普通会话独立保存执行器、模型 ID/显示名、推理强度与按执行器索引的权限/隔离选择；消息、附件引用和摘要。任务主会话引用所属 Task 的执行配置，避免两处选择冲突。</td></tr>
        <tr><td>ExecutorSession</td><td>逻辑 Conversation ID、执行器标识、远端/本地 sessionId、绑定目录、已提交/已确认的原生权限及会话状态；权限变更需要重建时保留旧会话关联；一个逻辑会话可关联更换执行器后创建的新协议会话，历史 Run 保留原 session 关联。</td></tr>
        <tr><td>Run</td><td>所属项目 ID、ownerType（task/chat）、conversationId、可空 taskId、executorSessionID、进程 ID 与启动时间、冻结的实际 cwd（新运行取任务选定目录或普通会话所属 project.path，历史值原样保留）、适用的任务阶段/需求快照（普通会话无任务阶段）、冻结的执行器/模型 ID及显示名/推理强度请求快照、可确认的实际生效强度、冻结的权限/隔离请求及适用的任务阶段约束、实际生效策略与验证状态、状态、持久 FIFO 顺序/提交时间、冻结 prompt 与附件引用、开始/结束时间和停止原因；回复关联对应 Run 快照。</td></tr>
        <tr><td>AgentRun</td><td>主 Run ID、角色、子会话 ID、权限、所属项目目录及历史实际 cwd 快照、冻结的执行器/模型/推理强度快照和独立状态。</td></tr>
        <tr><td>RequirementRevision</td><td>需求、方案、验收项、版本号、确认时间；运行引用确定版本。</td></tr>
        <tr><td>AcceptanceReport</td><td>验收项结果、证据、代码指纹、需求版本、检查配置版本与人工结论。</td></tr>
        <tr><td>Approval / Event</td><td>请求操作、目标、决定、来源运行；事件序号和可回放时间线。</td></tr>
        <tr><td>ImportBatch</td><td>批次 ID、固定 projectId/conversationId、关联指令消息 ID、来源类型及文件/链接引用、实际读取范围、自动识别的工作表和字段、读取/处理/提交状态、内部有效/重复/错误记录、幂等键、创建/跳过数量和错误信息。</td></tr>
        <tr><td>ImportCandidate / Provenance</td><td>内部处理记录；批次内行 ID、原始工作表/行号或规范 Issue 标识、sourceKey、标准化字段、校验与去重结果、跳过原因；提交后关联新建或已存在的任务 ID，不作为手动选择或确认界面。</td></tr>
        <tr><td>ExecutorCheck</td><td>本机执行器标识、接入方式、校验过的可执行文件路径、安装/认证状态、状态来源、检查时间、脱敏错误与模型能力另行验证的标识；不包含密钥，不以 projectId 划分独立登录状态。</td></tr>
        <tr><td>ModelCapability</td><td>执行器与账户能力范围、实际 API 模型 ID、精确版本显示名及可选浮动别名、可用状态、支持的强度列表与可确认的默认强度、能力来源、检查时间及缓存状态；路由模式不编造版本，未知/不支持单独标识，不把 HTML 离线快照存成实时账户能力。</td></tr>
        <tr><td>PermissionCapability</td><td>执行器/版本、支持的原生审批模式与隔离字段、模型/组织限制、配置适用时机、能力来源和检查时间；请求配置与实际生效/未知状态分开，记录不可用时的阻塞原因。</td></tr>
      </tbody></table>
      <h3>建议一致性规则</h3>
      <p>活动项目按规范化仓库根路径去重；已移除目录重新导入时创建新的 Project，旧记录可作内部兼容保留但不参与活动项目恢复；任务默认取所属项目 <code>project.path</code>，可保存经同仓库公共 Git 目录与登记校验的 <code>worktreePath</code>；Skill 创建的任务初始使用其固定目标项目目录。未终结 Run 或阶段停止屏障期间不能切换任务目录，历史实际 cwd 不随选择修改。历史 Run 的实际 cwd 继续作为原始证据保留，不改写、不声称已迁移，恢复须先核对实际会话与进程。创建任务时解析目标项目默认执行器，模型、强度与权限保留执行器原生默认策略，后续项目默认变更不覆盖该任务；创建任务、聊天与运行时固定所属项目 ID，查询和事件落库均校验项目归属。切换项目不得把正在运行的结果写入当前选中的其他项目，也不得复用其他项目的审批、会话或代码上下文。项目名称不是唯一标识。</p>
      <p>项目看板、任务详情和会话消息按所属项目隔离；全局“运行中”是展示投影的例外，汇总所有项目未终结运行及其事件、待审批和恢复提示，每项保留项目归属。全局展示不改变实体归属，不把其他项目审批复用为当前项目授权；相关操作以原 Run 的固定标识校验和执行。侧栏项目选择只影响项目内视图，不过滤该全局集合。</p>
      <p>移除前重新检查活跃 Run、子 Run、停止屏障和导入提交状态，并冻结该项目新请求；项目活动状态与关联可见性以同一事务更新，失败不留下半移除状态；旧记录的内部保留不提供恢复能力，不要求永久删除已有数据。重新导入同目录创建新项目，不自动复用原 ID、带回历史或启动 AI。移除不改变其他项目和全机执行器认证，不执行任何仓库、分支或 worktree 删除。最后一个项目移除后保存明确的空工作空间状态，初始化不得把它当作首次安装重新播种示例项目。</p>
      <p>执行器安装/认证检查结果在本机共享，Project 只保存默认执行器选择。认证状态缓存不能替代启动实际 Run 前的检测，也不能由密钥存在、一次网络失败或其他接入方式的登录状态推导；任务和聊天只引用所用执行器，不保存凭证。</p>
      <p>导入批次绑定明确导入指令及发起会话与项目，来源完整读取后自动处理有效行，读取失败不写入 Task。提交前校验内部有效记录与目标归属，并在事务中重新检查重复来源；任务与导入结果、来源关系一并提交或回滚。批次幂等键、内部行 ID 和来源去重防止重试或重复指令生成重复任务；无效行跳过不会使整批有效记录失败，其错误必须进入会话结果。</p>
      <p>“直接开发”必须是带 taskId、expectedPhaseVersion 的明确用户命令，仅接受待处理任务。阶段切换、新 phaseVersion 的直接开发授权、唯一主 Run 与操作消息在同一事务提交；失败全部回滚到待处理。<code>directImplementationPhaseVersion</code> 仅在开发且等于当前 phaseVersion 时有效，离开开发或保存新方案即清除，不代替 RequirementRevision.confirmedAt，也不制造验收条件。后续 Run 仍服从唯一主运行、规范 cwd 的 FIFO/目录锁及原生权限；需要独立验收时仍使用真实方案/条件，不生成虚构证据。手动完成独立于报告与修订确认，不检查报告是否存在、通过、有效或 confirmedAt，仅保留阶段并发校验与停止屏障；重启不得按授权标记自动重放。</p>
      <p>Task 阶段更新与取消屏障串行处理；运行配置启动后不可修改。会话/任务中的执行器、模型、强度与权限/隔离选择是下次运行配置，不改写旧 Run 或历史回复；能力回退应提示并记录在新快照。切换执行器关联新的 ExecutorSession 时保留逻辑 Conversation 和历史，并继续满足单任务唯一活跃主 Run。消息与事件按归属落库。重启保留未 claim 的 queued Run 与冻结上下文；已启动或启动状态不确定的 Run 根据进程 ID、启动时间及执行器会话标识先重连核对旧运行，或确认终止；核实工作目录锁状态后才允许同 cwd 的后续 Run 启动；等待请求可先持久入队。无法核实旧进程或锁时阻塞写入，展示恢复入口，不把未知状态视为成功，不自动重放写操作。</p>
      <p>普通会话与任务 Run 使用同一目录写入锁；所有可能写入该目录的会话和任务均须取得唯一写入权，停止确认后才释放。普通会话无任务阶段，不受任务讨论/验收的只读规则限制；其运行按 Conversation 归属保存，代码请求不自动生成 Task。</p>
      <p>代码指纹涵盖 HEAD、已暂存/未暂存 diff，以及未跟踪文件的内容摘要；排除规则必须显式定义并纳入指纹版本。任何相关代码变化或验收条件变化都会使原报告失效。仓库示例路径采用 <code>~/Projects/sample-app</code>。</p>
    `
  },
  {
    id: "acceptance",
    title: "情境验收与质量标准",
    kicker: "验收标准",
    body: `
      <table><thead><tr><th>场景 / 关联需求</th><th>操作</th><th>必须观察到的结果</th></tr></thead><tbody>
        <tr><td>项目导入 · FR-15</td><td>首次从空状态导入有效 Git 仓库，再从侧栏导入另一个仓库。</td><td>正式应用使用系统目录选择器；显示名称、路径及三种默认执行器选择；新项目的看板、会话列表和运行历史为空，可从项目下新建会话；全局“运行中”仍保留其他项目活动运行；不启动 AI、clone 或安装。HTML 仅验证记录与界面变化，真实目录校验待实现。</td></tr>
        <tr><td>导入异常与去重 · FR-15</td><td>正式应用选择不存在、无权限或非 Git 目录；取消选择；重复导入同一规范路径。</td><td>无效目录展示具体原因且不创建项目；取消不改变记录；重复导入活动项目则切换，不增加重复活动记录；目录已移除时允许重新导入为新项目，不恢复旧 ID 或历史。原型不以输入路径判断真实有效性。</td></tr>
        <tr><td>项目移除与重新导入 · FR-15</td><td>从对应项目“…”菜单移除并取消一次，再确认移除；检查本机项目区与空态，之后重新导入同一目录。</td><td>确认显示名称、路径与关联记录影响；取消无变化。移除后活动列表隐藏，无已移除项目列表、恢复操作或重置演示入口；重新导入创建新项目及空工作空间，不承诺旧 ID/任务/会话/日志恢复。其他项目与全机认证不变，不删除仓库、代码、分支或 worktree；不要求永久清空旧存储。</td></tr>
        <tr><td>项目移除阻塞与空状态 · FR-05/15/16</td><td>项目运行、子运行、正在停止/阶段屏障或 Skill 导入中尝试移除；停止后移除最后一个项目并刷新，再导入本地目录。</td><td>进行中操作阻止移除并引导先停止/等待；无活动项目后显示空状态，刷新不补回 sample，仍可导入，但不出现恢复或重置演示入口。HTML 验证演示状态，真实进程停止、持久事务与目录行为另行联调。</td></tr>
        <tr><td>项目隔离 · FR-03/10/15</td><td>项目 A 创建任务与聊天，运行中切换项目 B，再返回 A。</td><td>B 的项目看板与会话不显示 A 的任务或消息；全局“运行中”仍汇总 A、B 的未终结运行、相关事件、待审批与恢复提示，并明确显示项目归属，切换项目不改变集合。打开 A 的会话定位 A；从全局入口审批、停止或恢复 A 的运行时仍只作用于 A 的原 Run。A 的迟到事件按原归属记录；返回 A 后数据保留，目录访问失效时阻塞新运行并显示重新授权或重选目录入口。</td></tr>
        <tr><td>新建任务默认执行配置 · FR-01/04/18</td><td>分别以 Codex、Claude、Cursor 为当前项目默认执行器创建任务；修改项目默认后再创建；在既有任务会话调整执行配置，并从另一配置的普通会话导入任务。</td><td>新建表单没有工作区、执行器、模型、强度或运行权限控件；执行目录初始为目标项目 project.path；创建表单不提供工作区，任务详情可选择 Git Worktree。新任务采用目标项目当前默认执行器与执行器原生默认策略，不复制来源聊天配置。已有任务选择和历史快照不随项目默认变更；后续可在任务会话底栏调整。创建仍为待处理且不启动 AI，实际默认值与运行能力另行联调。</td></tr>
        <tr><td>任务目录与 Git Worktree · FR-01/07/16/18</td><td>在项目 A 手动创建与通过 Skill 导入任务，切换项目 B 后运行 A 的任务；尝试同目录第二写入者，模拟项目目录失效，查看旧 Run 的 cwd。</td><td>创建界面无工作区选择；默认使用所属项目 project.path，任务详情可选择本项目 Git Worktree，不随侧栏项目变化。Worktree 从当前已提交 HEAD 创建独立任务分支，主目录 staged/unstaged/untracked 保持原样；不自动合并、删除或复制脏改动。同 cwd 第二写入者持久 FIFO 排队且不持锁，释放后自动 claim；不同 Worktree 可并行。目录失效阻止启动；历史 cwd 与快照不被重写。</td></tr>
        <tr><td>任务多行说明 · FR-01</td><td>新建任务时在说明与备注按 Enter 换行，粘贴多行文字，纵向拖动改变高度；保存后重新查看。</td><td>多行文本框可编辑，Enter 仅换行、不提交创建；多行粘贴与纵向调整可用，保存及显示保留原换行和段落。</td></tr>
        <tr><td>图标语义与下拉指示 · FR-01/04/12</td><td>检查看板筛选、任务卡、会话执行摘要与认证列表的图标。</td><td>下拉指示采用独立 chevron 图标，不使用文字 v/∨；执行器身份使用对应 Codex、Claude、Cursor 标志，保持名称可读，不用通用圆环或字母替代。</td></tr>
        <tr><td>待处理隔离 · FR-01/02</td><td>新建任务、输入备注、重启应用。</td><td>备注恢复；模型请求和 Agent 预热计数均为零。</td></tr>
        <tr><td>待处理直接开发 · FR-01/02/06/08</td><td>创建包含标题、多段说明、主会话备注与图片/文件附件的待处理任务，无已确认方案；点击“直接开发”，并快速重复点击。</td><td>保留“进入讨论”；一次显式操作进入开发并启动一个真实主 Run，使用该任务当前配置、所属项目目录与完整任务/备注/附件上下文。阶段、授权版本、唯一 Run 与用户操作消息原子保存；不创建虚构方案、确认或验收项；重复点击不能重复运行。</td></tr>
        <tr><td>直接开发阻塞与恢复 · FR-01/05/06/14</td><td>同目录已有写入者、目录失效、阶段版本变化或注入事务失败时点击“直接开发”；随后登录完成、刷新或重启应用。</td><td>同目录忙时原子进入开发并创建唯一 queued Run，不弹占用错误，展示等待且可取消；FIFO 依次 claim，排队不占锁，目录释放后自动执行一次。目录失效、版本冲突或事务失败仍保持待处理且无半切换。重启保留未启动队列；已启动或启动不确定的 Run 先恢复核对，不重复提交 prompt。</td></tr>
        <tr><td>直接开发授权边界与验收 · FR-02/08/09</td><td>直接开发后保存新方案或离开开发，再走普通讨论 → 开发；未补标准尝试验收，随后在方案页补充并确认标准。</td><td>直接开发授权随保存新方案或离开开发清除，不能复用于其他阶段版本；普通讨论 → 开发仍要求已确认方案。需要独立验收时补充并确认真实标准，报告继续绑定需求版本和代码指纹；该可选路径不阻止用户从开发直接手动完成，完成不检查报告或修订确认。</td></tr>
        <tr><td>阶段取消 · FR-05/06</td><td>开发运行中切到验收。</td><td>主/子运行停止、队列清空后进入验收；迟到事件不改变新阶段。</td></tr>
        <tr><td>会话执行配置与快照 · FR-03/04</td><td>点击输入框底栏摘要打开一级推理面板，先直接调整强度；再点击中部模型名打开二级列表，切换执行器并选模型返回一级；以鼠标及键盘检查，运行中修改，再启动下次运行。</td><td>初始直接使用执行器默认模型；一级只展示紧凑推理面板，含闪电、居中强度/模型名/chevron、重置与下方随强度变色的离散滑杆；二级才显示执行器切换和模型列表，选模型返回一级并更新底栏摘要，列表与滑杆不常驻并排。窄屏不溢出且发送按钮可用；各会话/任务选择独立保存；模型和强度随执行器联动；旧运行及历史回复保留冻结配置，下次回复/运行采用新配置。</td></tr>
        <tr><td>推理强度滑杆 · FR-04</td><td>在一级推理面板调整强度，通过中部模型名进入二级列表切换执行器与模型后返回；使用鼠标、方向键及 Home/End 调整强度后重置；检查 Cursor Auto/Composer、Grok 与 Claude Haiku。</td><td>随强度变色的离散滑杆包含起点“默认”自动状态及当前模型合法等级，默认不算额外推理等级；当前值居中，读屏可获名称与值；重置清除显式覆盖并恢复执行器默认策略，未知默认不伪造等级。不支持独立强度时禁用并说明，Grok 为默认自动位置加四个合法强度档位；无分段按钮或强度下拉，新建任务不出现该控件。变更只影响下次回复/Run，旧快照保留。</td></tr>
        <tr><td>执行器切换与能力回退 · FR-03/04/12</td><td>同一普通会话或任务切换执行器；选择不支持强度的模型，或刷新后旧模型/等级不可用。</td><td>逻辑 Conversation 与历史保留，协议不兼容时关联新 ExecutorSession；未知/不支持展示默认或未开放，不发送伪参数；回退原因和下一次实际配置明确，真实模型目录与账户能力须联调。</td></tr>
        <tr><td>权限预设菜单与恢复 · FR-18</td><td>打开底栏盾牌菜单，选择预设后切换执行器再返回；检查默认/未知、自定义组合、Haiku 与未授权 Claude；运行中修改并启动下一轮。</td><td>菜单仅三行“请求批准 / 帮我批准 / 完全访问权限”，无多字段表单、高级入口或设置页；不可用项禁用并说明，未知/自定义不伪造勾选。选择后按会话/任务和执行器保存恢复，旧 Run 不变，下轮记录映射策略，实际生效未知不显示已沙箱。</td></tr>
        <tr><td>执行隔离与审批边界 · FR-02/07/13/18</td><td>启用隔离并测试越界文件/网络、权限拒绝、隔离不可用；分别验证普通会话的代码操作与任务只读阶段。</td><td>原生隔离与审批分别验证，固定项目目录不当作 OS 沙箱；普通会话按原生权限和授权目录运行，与任务共享目录锁，只有任务额外施加阶段限制。明确要求的隔离不可用时阻止启动，无静默降级或 force；Claude 沙箱外工具另受限制，Cursor 安全配置按启动生命周期应用。HTML 只验证演示交互，真实边界和停止须联调。</td></tr>
        <tr><td>写入隔离 · FR-07/11</td><td>开发停止后，审查读取冻结指纹对应的快照，并申请第二个写入 Agent。</td><td>首版开发与审查串行，审查保持只读且绑定快照；同规范 cwd 第二写入者自动 FIFO 排队且可取消；不同项目目录与同项目独立 Worktree 可并行。待恢复写入未确认停止前继续占位，后续同 cwd 不越过队列。</td></tr>
        <tr><td>全局运行中工作视图 · FR-03/11/13/14</td><td>A、B 项目各启动运行，并产生子 Agent、等待审批与待恢复状态；切换选中项目，再从全局列表打开会话、审批、停止或恢复；使运行成功、失败或确认停止。</td><td>角标、列表、事件、待审批和恢复提示覆盖所有项目未终结运行，显示各自项目归属，子 Agent 归父运行；选择 A、B 不改变全局集合。打开会话定位原项目，审批、停止、恢复只提交并作用于原 Run；无历史时间限制或已结束筛选。终结后从列表与角标移出，历史证据继续保存；所有项目均无活动运行才显示空态。</td></tr>
        <tr><td>内部 Agent 呈现 · FR-03/11</td><td>执行器在任务中按需调用分析或独立审查 Agent，查看任务主会话与运行记录。</td><td>调用状态、摘要和证据在主会话与既有运行记录可追踪；没有独立 Agent 配置页面、导航或固定角色配置要求；任务唯一主运行、写入隔离与阶段停止规则仍生效。</td></tr>
        <tr><td>验收失效 · FR-08/09</td><td>验收通过后修改未提交代码或验收条件。</td><td>旧报告显示过期并保留原结果，用户可按需重新验收；手动完成仍可用，不把过期报告改成有效或通过。</td></tr>
        <tr><td>项目会话导航 · FR-10/15</td><td>从项目侧栏新建并打开项目 A 的两条会话，再打开项目 B 的会话并返回 A；检查聊天页顶部和窄屏当前项目会话入口。</td><td>项目侧栏保留会话列表与新建，消息和选择状态独立保留，点选会话同步选择所属项目；聊天顶部仅显示项目与当前会话，无切换下拉；窄屏入口只打开当前会话，不展开列表或混入其他项目会话。</td></tr>
        <tr><td>手动完成 · FR-01/05/09</td><td>开发阶段分别没有报告、报告未通过、报告过期或方案/条件尚未确认；用户主动完成。再在主/子运行活动时完成。</td><td>无需先进入验收或生成报告，人工操作可完成；已有报告原样保留，不伪造通过、有效或确认。全部主/子运行与队列停止确认后才更新阶段，失败维持原阶段；Agent 输出与运行成功不能自动完成。</td></tr>
        <tr><td>占位与中文输入 · FR-01/10</td><td>创建备注与两个会话输入框为空时定位 caret，中文 IME 组合、提交、删除并清空。</td><td>placeholder 与 caret 首行基线/边距一致；marked 期间立即隐藏，提交后继续隐藏；仅清空且无 marked text 时恢复。附件粘贴与普通文本编辑不受影响。</td></tr>
        <tr><td>图片与文件粘贴 · FR-01/10</td><td>在任务说明和会话中粘贴截图、Finder 文件及多行文字，预览、移除并保存后重启；发送图片至各执行器。</td><td>文本与输入法正常；任务附件持久化且待处理不启动执行器；粘贴端拒绝超限文件，普通文件单项 25 MB、发送图片合计 5 MiB 的限制明确；图片启动校验失败保留已保存消息与附件，并将预留 Run 标为失败；图片使用原生 image 内容，不仅传递路径。</td></tr>
        <tr><td>删除普通会话 · FR-10</td><td>从会话“…”或右键菜单取消/确认删除当前会话；运行或导入期间尝试删除；删除含已导入任务的会话。</td><td>取消不变，确认后返回项目看板且重启不再显示；运行或导入时禁止删除；任务主会话无此操作，已导入任务、来源及批次审计仍可追溯。</td></tr>
        <tr><td>普通会话代码工作与建任务 · FR-10</td><td>直接要求读改项目代码并运行命令；另一会话/任务申请同目录写入；随后明确要求转为任务或导入清单。</td><td>无需新建看板任务即可按当前执行配置运行，审批、停止、恢复与快照归属 Conversation；同目录写入保持唯一。代码请求与 AI 建议不自动创建任务，仅明确转任务/导入创建所属项目任务；任务只读阶段规则仍独立有效。HTML 仅演示，不执行真实代码。</td></tr>
        <tr><td>聊天触发 Skill · FR-16</td><td>通过普通会话通用附件按钮提供任务表，先不发送导入要求，再发送“将附件任务导入看板”；或发送 Issue 链接并明确要求导入。</td><td>仅附件或链接不自动导入；明确指令授权本次创建，Agent 直接导入并在原会话报告结果，没有来源/字段选择、候选勾选、确认弹窗或专属 Skill 入口。</td></tr>
        <tr><td>任务表直接导入 · FR-16</td><td>在项目普通会话提供含有效行、空标题和重复来源的任务表，以自然语言要求导入。</td><td>Agent 自动识别工作表与字段；有效且未重复记录直接进入该项目待处理；坏行、重复分别跳过并告知，任务编号可打开，不启动 AI。Excel 真实解析与自动识别需实现验证；HTML 示例任务与结果单独标注。</td></tr>
        <tr><td>Issue 范围与授权 · FR-16</td><td>提供 Issue 列表和一组重叠链接并要求导入；模拟范围歧义、私有来源未授权或读取失败。</td><td>Agent 读取明确范围并按仓库/编号去重，会话报告实际范围与数量；仅必要歧义通过会话澄清；权限不足提示连接授权且不索取聊天中的密钥；读取失败创建零任务。HTML 示例不能作为真实远程读取证据。</td></tr>
        <tr><td>直接导入幂等与隔离 · FR-10/16</td><td>重试同批次、重复发送同来源导入要求、提交中发生错误，或执行期间切换项目。</td><td>重试与重复来源不重复创建；事务失败整体回滚；目标固定为 conversation.projectId，全部新任务为待处理；来源可追溯，任务不因侧栏切换进入其他项目，取消未提交批次创建零任务。</td></tr>
        <tr><td>认证状态与失败 · FR-12/17</td><td>从桌面全局侧栏或窄屏头部齿轮打开认证弹窗，手动检查/重新检测，分别模拟未安装、未认证、已认证、仅配置凭证和检测超时。</td><td>认证为轻量弹窗，入口位于最外层，项目菜单无认证项、桌面头部无重复齿轮；无独立设置页，关闭回原工作视图。状态和原因分别显示；超时为检测失败/未知，可重试，不标未登录；仅存在 SDK 凭证不标已认证；检查过程中模型请求与业务 Run 创建次数为零。HTML 显示模拟标识。</td></tr>
        <tr><td>自动检测与全局归属 · FR-02/17</td><td>首次使用、切换执行器、启动实际 Run 前检测；切换项目，完成认证引导后返回应用。</td><td>使用同一本机状态而非每项目独立登录；检查不预热 Agent；返回后重新检测，不自动启动任务或重放写操作；认证成功仍单独显示模型权限、额度与运行能力的验证状态。</td></tr>
        <tr><td>接入方式与凭证边界 · FR-12/17</td><td>核对 Codex 账户接口、Claude CLI/SDK 配置与 Cursor 路径身份。</td><td>每种检查依据所用 Adapter；CLI 认证不替代 SDK 认证，Cursor 不命中其他产品的 agent；密钥不进入任务、聊天或原型 localStorage。真实认证与模型能力须由实现后的联调记录证明。</td></tr>
        <tr><td>审批拒绝 · FR-13</td><td>拒绝命令或权限请求。</td><td>操作未执行，记录拒绝原因和后续影响，用户可继续讨论。</td></tr>
        <tr><td>异常恢复 · FR-12/14</td><td>断网、执行器退出或应用重启。</td><td>保留消息、证据及未启动的持久 FIFO 队列；queued 无进程、无写入锁，重启仍可调度。已启动或启动状态不确定的 Run 先重连核对或确认终止旧进程，无法核实时保留目录占位，后续同 cwd 继续等待，不自动重放写操作。</td></tr>
      </tbody></table>
      <p>验证包括原型交互、原生界面、调度层自动测试和真实执行器联调。原生界面须在 macOS 26 验证浅/深色、减少透明度、减少动态效果与增加对比度：导航和控件层材质清晰，正文、任务卡及 diff 可读且操作可达。HTML/Figma 只验证设计模拟与行为预期，不能证明 SwiftUI 系统材质或无障碍实测通过；取消、写入锁、审批和模型兼容须由联调记录证明。</p>
      <p>建议非功能门槛：长运行期间界面保持可操作；日志能追踪每个 Run；停止与失败恢复过程保留明确状态和证据，确认旧运行已结束后才允许新写入。</p>
    `
  },
  {
    id: "roadmap",
    title: "建议交付顺序与基础规则",
    kicker: "交付计划",
    body: `
      <table><thead><tr><th>里程碑</th><th>交付范围</th><th>出口条件</th></tr></thead><tbody>
        <tr><td>M0 · 评审</td><td>本 PRD、任务看板/详情/聊天 HTML 原型；在 Codex、Claude、Cursor 中确定首个实现及接入顺序。</td><td>用户确认界面与关键规则，完成候选执行器可行性探针。</td></tr>
        <tr><td>M1 · 内部技术闭环</td><td>macOS 26.0+ SwiftUI 系统 Liquid Glass 界面、本地项目导入/移除与切换、四阶段、一任务一会话、普通聊天、模型与推理强度能力选择、原生权限/执行隔离及运行快照、单执行器、单写入者、持久化与取消。</td><td>验证原生材质、外观与系统无障碍适配，并以真实本地任务验证内部闭环、项目隔离、原生沙箱/审批和异常恢复；此里程碑不代表对外首版交付。</td></tr>
        <tr><td>M2 · 完整首版</td><td>补齐全部 P0：内置任务清单导入 Skill、执行器认证检测、结构化验收、代码指纹、审批与失败恢复；加入 P1 的独立只读审查、按需分析，结果融入任务会话。</td><td>全部 P0 情境与任务会话中的多 Agent P1 演示通过，证据可回溯，满足完整首版交付标准。</td></tr>
        <tr><td>M3 · 后续扩展</td><td>在 Codex、Claude、Cursor 三种范围内补齐其余 Adapter，评估跨执行器与阶段模型覆盖；任务默认项目目录并支持独立 Git Worktree 与同 cwd 持久 FIFO。</td><td>接入次序另行确认；分别完成互操作和冲突恢复验证后开放，不自行扩大执行器范围。</td></tr>
      </tbody></table>
      <h3>评审用基础规则</h3>
      <p><span class="status proposed">建议</span>新任务进入待处理；单任务最多一个活跃主 Run；同一工作目录同时只有一个写入者；审查默认只读；任务固定在所属项目目录执行，同目录写入串行，不同项目目录可并行。任务创建自动采用项目默认执行器与执行器原生默认配置，创建表单不增加执行配置；任务与普通聊天分别保存执行器、模型、支持的推理强度及按执行器索引的原生权限与隔离配置。可选能力以实际接通状态为准，阶段模型覆盖留待后续。</p>
      <p>分析 Agent 按需参与任务，不设置全局启用开关。交付顺序不代表已承诺开发日期。</p>
    `
  },
  {
    id: "decisions",
    title: "待定事项与决策记录",
    kicker: "待定决策",
    body: `
      <table><thead><tr><th>决策项</th><th>建议方向</th><th>确认依据</th></tr></thead><tbody>
        <tr><td>首个实现与接入顺序</td><td>从用户暂定的 Codex、Claude、Cursor 中选择首个 Adapter；Codex app-server、Claude SDK 桥接为建议。Cursor 建议先验证 CLI ACP，SDK Bridge 备选，详见接入调研。</td><td>用真实仓库验证启动、写入、审查、停止与恢复；Cursor 已确认初始化及配置路径，真实任务联调未完成，三种均不视为已接通，尚未排序。</td></tr>
        <tr><td>最低 macOS 版本 · 已确认</td><td>macOS 26.0；SwiftUI 使用系统 Liquid Glass 与原生控件，不增加 macOS 25 及以下兼容方案。</td><td>本轮用户确认；原生实现验证浅/深色及系统透明度、动态效果和对比度设置。</td></tr>
        <tr><td>凭证存储</td><td>优先评估系统 Keychain 或执行器自身凭证管理。</td><td>确认认证方式、进程读取边界和迁移方案。</td></tr>
        <tr><td>首版跨执行器</td><td>先完成单执行器闭环，在 Codex、Claude、Cursor 范围内评估后续协作；执行器与模型分别配置。</td><td>用户确定首版价值取舍；有实际互操作证据再声明支持。</td></tr>
        <tr><td>阶段进入与显式启动</td><td>已确认：待处理点击“直接开发”原子进入开发并显式启动一次真实 Run；保留“进入讨论”原行为。其他阶段入口是否同时启动继续按原交互规则及后续评审处理。</td><td>仅该用户动作生成一次启动意图；不能据此扩展为后台阶段监听、认证完成后启动或重启自动重放。</td></tr>
        <tr><td>已完成列与集成方式</td><td>已确认：用户可从开发直接手动完成，验收报告可选；首版由用户决定代码合入方式。</td><td>完成保留运行停止/并发保护，Agent 不自动完结；提交/合并/发布仍需明确操作。</td></tr>
      </tbody></table>
      <h3>手动完成与可选报告 · 已确认</h3>
      <p><span class="status confirmed">已确认</span>用户主动完成无需强制验收报告。开发可以直接完成；报告缺失、未通过、过期，或需求/方案版本未确认均不构成完成门禁。有报告则保留原状态作参考，不伪造报告或改写验收结论。运行停止、并发与归属校验继续保留；Agent 不自动完结任务。</p>
      <h3>本轮已确认决策 · 2026-10-06</h3>
      <p><span class="status confirmed">已确认</span>用户移除“默认模型与运行预算”整块设计：不提供项目默认模型、可配置的主运行并发上限、单次时间/Token/金额预算及全局代码分析开关。已同步调整 FR-06、FR-14、数据实体与交付范围；任务和普通聊天各自选择模型、按需只读分析、写入隔离及停止恢复规则继续保留。</p>
      <p><span class="status confirmed">已确认</span>用户补充项目导入入口，新增 FR-15。首次空状态和侧栏均提供入口，导入已有本地 Git 仓库后建立独立项目工作空间；目录选择、校验、去重和数据隔离作为实现与验收要求。</p>
      <p><span class="status confirmed">已确认</span>用户将普通聊天移至每个项目层级下：取消全局普通聊天导航，项目树提供会话列表和新建入口，支持直接点选具体会话；任务主会话仍独立，普通会话可直接执行代码工作，用户明确要求转任务或导入时才创建所属项目任务。</p>
      <p><span class="status confirmed">已确认</span>用户确定 FR-16 的最终交互：项目普通会话提供表格附件或 Issue 链接并明确要求导入后，由 Agent 自动识别、去重并直接创建待处理任务，在会话报告结果；不设置专属入口、手动选择或统一确认。明确导入指令已授权任务记录创建，仅附件或链接不自动导入。来源无法识别、范围歧义或缺少权限时才请求必要澄清或连接授权；支持规模和来源适配以真实实现验证，不阻塞当前交互评审。</p>
      <p><span class="status confirmed">已确认</span>用户移除独立 Agent 配置页面及其导航入口；内部 Agent 由执行器按需调用，状态、摘要和证据融入任务主会话与已有运行记录。此决定简化界面，继续保留单任务唯一活跃主运行、同目录唯一写入者、阶段停止屏障和独立验收报告等内部规则；执行器选择与认证检查仍保留在会话输入区及轻量认证弹窗。</p>
      <p><span class="status confirmed">已确认</span>用户补充执行器认证状态检查入口，新增 FR-17；从桌面全局侧栏或窄屏头部齿轮打开轻量认证弹窗，支持手动和自动只读检测，区分本机安装、认证、凭证未验证和检测未知状态。认证与模型权限/额度分离，HTML 只演示检查与引导，不新增配置页面或保存密钥；真实能力按接入方式联调。</p>
      <h3>新增已确认决策 · 2026-10-07</h3>
      <p><span class="status confirmed">已确认</span>最低系统要求为 macOS 26.0，视觉方向采用 SwiftUI 系统 Liquid Glass：导航、工具栏、输入控件和菜单浮层使用材质，正文、任务卡与代码 diff 保持稳定内容底；适配浅/深色及减少透明度、减少动态效果、增加对比度。HTML/Figma 为设计模拟，原生实现与系统无障碍实测尚未完成；既有执行器、会话、Skill 与权限交互规则不变。</p>
      <p><span class="status confirmed">已确认</span>普通项目会话和任务主会话均联动选择执行器、对应模型与支持的推理强度，各自独立保存。每次回复/Run 冻结配置，运行中修改下次生效；切换执行器保留逻辑会话，协议无法复用时关联新 executorSession。实际模型目录和强度由 Adapter/账户能力提供，不新增全局默认模型、Agent/Providers 页面或预算；HTML 模型目录为按日期核对的离线快照，回复仍为模拟。</p>
      <p><span class="status confirmed">已确认</span>聊天执行配置采用 Codex 式输入框底部的紧凑摘要入口，先打开一级紧凑推理面板，再点击中部模型名进入二级执行器/模型列表，选择后返回一级并更新摘要；初始使用执行器默认模型，强度使用当前档位颜色强调，并适配窄屏；下一次回复/运行生效规则不变。Cursor CLI 与当前 ACP 源码已确认强度配置路径，按各模型能力开放，真实会话推理与隔离仍需联调。</p>
      <p><span class="status confirmed">已确认</span>Codex、Claude 模型展示精确版本并跟随执行器最新可用目录；Cursor 主要列表展示 Auto、Grok 4.7、Composer 2.5。模型目录记录 API ID、能力来源与更新时间，Auto 保留路由语义；HTML 仅保存本轮离线快照，不宣称实时同步或改写历史。</p>
      <p><span class="status confirmed">已确认</span>FR-18 权限入口采用 Codex 式三行菜单：“请求批准 / 帮我批准 / 完全访问权限”，移除面向用户的沙箱、审批及审批方多字段表单，不增加高级入口或设置页。后台按执行器原生能力映射，模式不可用则禁用并说明，未知/自定义不伪造预设勾选；会话/任务按执行器保存恢复，下一次回复/Run 生效，旧快照与阶段/目录约束保留。</p>
      <p><span class="status confirmed">已确认</span>移除聊天内容顶部的会话切换下拉，项目与当前会话名称改为只读展示；窄屏当前项目会话入口只打开当前会话。项目侧栏的会话列表与新建入口继续按 FR-10 保留。</p>
      <p><span class="status confirmed">已确认</span>普通项目会话直接支持代码工作：可按当前执行器、模型、推理强度、原生权限与项目授权目录直接读改代码、运行命令，无需先转为看板任务。普通会话没有任务阶段，Run 归属 Conversation，审批/停止/恢复/快照照常记录，并与任务共享同目录唯一写入锁；仅明确转任务或导入才创建看板任务。此决定不默认开启完全访问权限，任务讨论/验收只读规则继续保留。</p>
      <p><span class="status confirmed">已确认</span>FR-15 保留项目导入与移除：入口位于各项目“…”菜单，确认名称、路径和关联应用记录影响后移除；进行中的运行、停止屏障或 Skill 导入阻止移除。本地仓库、代码、分支和 worktree 不删除，其他项目与全机认证保留；最后一个项目移除后保持真实空状态。同目录可重新导入为新项目，不提供原项目恢复，不新增需求编号。</p>
      <p><span class="status confirmed">已确认</span>移除全局“项目与设置”入口与独立设置页：项目操作收拢到各项目“…”菜单；认证收拢至最外层，桌面全局侧栏底部提供“执行器与认证”，窄屏保留头部齿轮，均打开原轻量弹窗。项目菜单移除认证项，桌面头部齿轮去重，认证状态与项目默认执行器选择功能不变。项目导入通过本机项目区、无项目空态与窄屏项目栏进入；窄屏导航仅保留看板、会话、记录。原有运行阻塞、运行故障恢复和数据隔离规则不变，已移除项目恢复功能取消。</p>
      <p><span class="status confirmed">已确认</span>新建任务移除执行器、模型、推理强度与运行权限控件，自动使用当前项目默认执行器及其原生默认配置；不复制普通会话选择，不新增默认模型或设置页面。后续在任务主会话输入框底栏按 FR-04/18 调整，项目默认变更不覆盖已有任务及历史快照。筛选下拉使用独立 chevron 图标，所有执行器身份采用对应的 Codex、Claude、Cursor 标志。</p>
      <p><span class="status confirmed">已确认</span>任务执行目录默认所属项目的 <code>project.path</code>，新建任务维持四字段；按 2026-10-08 新决定，任务详情可选择 Git Worktree，Skill 导入任务初始仍为项目目录。隔离由执行器原生沙箱和权限控制；同目录唯一写入者与阶段停止规则保留，不同规范 cwd（包括同项目独立 Worktree）可并行。历史 Run 的 cwd 与证据原样保留，此设计调整不代表已迁移旧会话、进程或代码。</p>
      <p><span class="status confirmed">已确认</span>新建任务的“说明与备注”为可编辑多行文本框，支持 Enter 换行、多行粘贴和纵向调整大小，保存与再次显示保留换行；Enter 不提交创建。</p>
      <p><span class="status confirmed">已确认</span>会话执行配置先展示一级紧凑推理面板，含闪电图标、中部可点击的当前强度/模型名/chevron、重置及下方 Codex 式随强度变色的离散滑杆；中部模型名打开二级列表，选择执行器及模型后返回一级更新摘要，初始直接使用执行器默认模型。滑杆包含“默认”自动位置和当前模型实际合法档位，默认不算新增推理等级；重置恢复执行器默认策略。不支持时禁用并解释，提供键盘操作与可访问值，不回到任务创建表单。</p>
      <p><span class="status confirmed">已确认</span>取消“已移除项目”入口及整个项目恢复功能，并移除“重置演示”入口。移除仍不删除本地仓库代码，进行中的运行、停止屏障或 Skill 导入阻止移除；同目录以后可以重新导入为新的项目记录，不承诺恢复原 ID 或历史数据，不要求永久删除已有内部存储。执行器故障恢复、会话配置恢复和推理强度重置不受此决定影响。</p>
      <h3>新增已确认决策 · 2026-10-08</h3>
      <p><span class="status confirmed">已确认</span>待处理任务新增“直接开发”，与“进入讨论”并存。仅用户明确点击该入口时，按任务标题、说明、已有备注和附件原子进入开发并启动一次真实 Run；此次开发阶段可跳过讨论与方案确认，不伪造方案或验收标准。启动准备失败维持待处理；授权在离开开发或保存新方案后清除；普通讨论 → 开发与原生权限规则保持；独立验收为可选参考路径，不阻止用户手动完成。后台刷新和认证完成不创建运行意图；重启保留已接受但未启动的 queued 请求，已启动或不确定是否启动的运行先恢复核对，不重放执行。</p>
      <p>决策记录应保存决定、日期、影响需求编号和验证证据。未确认事项在实现前保持可配置或留出接口；不得以建议默认值替代用户决定。</p>

      <h3>持久等待队列与 Git Worktree · 已确认 · 2026-10-08</h3>
      <p><span class="status confirmed">已确认</span>同目录占用作为正常等待处理，取消占用弹窗并自动持久 FIFO 排队，支持取消排队；排队不持锁，真正启动时 claim 后取得写入权。任务详情支持选择 Git Worktree 独立开发，默认仍为项目目录；从已提交 HEAD 创建独立分支，不复制未提交改动，不自动合并或删除。不同规范 cwd 可并行；恢复未确认继续占位。尚未启动的 queued 请求重启保留，已启动或启动状态未知的 Run 先恢复核对，不自动重放。</p>
`
  }
];
