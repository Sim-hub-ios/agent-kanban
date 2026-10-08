# Agent Kanban

基于 SwiftUI 的本地 Agent 工作台，支持任务看板、项目会话、执行器运行监控、目录排队与 Git Worktree 开发。最低支持 **macOS 26.0**，使用系统 Liquid Glass 界面。

## 构建与运行

需要 Xcode 26 / Swift 6.2，以及 Git。

```sh
./macos/scripts/build-app.sh debug
open 'macos/build/Agent Kanban.app'
```

也可以在 Xcode 中打开 `macos/AgentKanban.xcodeproj`，运行 `AgentKanban` scheme。详细说明见 [macOS 客户端文档](macos/README.md)。

构建脚本生成本机 ad hoc 签名应用；开发者签名、公证与分发尚未配置。Codex、Claude Code 与 Cursor Agent 由各自的官方 CLI 安装和认证，实际模型与权限取决于本机执行器及账号能力。

## 测试

```sh
swift test --package-path macos
```

默认测试使用临时数据与受控执行器，不请求真实模型。真实执行器联调的启用方式与验证边界见 [验证说明](macos/VALIDATION.md) 和 [执行器接入说明](macos/EXECUTORS.md)。

## 文档与目录

- [产品需求文档](docs/product/prd.html)、[系统设计文档](docs/product/design.html) 与 [交互原型](docs/product/prototype.html)：可直接在浏览器打开。
- [UI 设计稿](docs/product/figma-ui/index.html)：HTML 设计稿与组件资源。
- `macos/Sources/`：SwiftUI 应用、持久化核心与执行器适配。
- `macos/Tests/`：工作流、队列、Git Worktree 与执行器测试。
- `macos/Assets/`：应用图标与资源说明。

任务、消息和附件默认保存在本机 `~/Library/Application Support/AgentKanban`。构建产物、本机数据库、诊断原始记录与凭据不纳入版本控制。
