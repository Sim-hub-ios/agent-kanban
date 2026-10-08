# Agent Kanban 应用图标

三列任务看板，蓝紫色液态玻璃。背景为不透明、满铺的方形图案，由 macOS 26 统一生成圆角和外缘，避免传统透明图标被缩小后放入白色底板。

- `AppIcon-source.png`：内置 imagegen 编辑后的原图（1254 × 1254）。
- `AppIcon.png`：1024 × 1024 主图。
- `AppIcon.icon`：供 Xcode / actool 编译的现代图标源，应用使用生成的 `Assets.car`。
- `AppIcon.icns`：16–1024 px 的兼容图标资源。
- 重新生成图标尺寸：`zsh macos/scripts/build-icon.sh`。
- 应用内部执行器标识继续使用各执行器对应图标。

## 生成方式与提示词

使用 Codex 内置 imagegen；未使用 CLI/API 回退。保留三列玻璃看板主题，修正了第一版预制圆角、透明留白与 macOS 26 系统图标底板叠加的问题。通过系统 `sips` 缩放，使用 `actool` 编译现代图标，另以 `iconutil` 生成兼容资源。

Apple 要求 iOS / iPadOS / macOS 的图标输入保留方形，背景满铺且不透明，让系统应用最终遮罩：[App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons)。现代图标的构建方式见 [Creating your app icon using Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)。

### 本次填充修正提示词

```text
Use case: precise-object-edit. Edit target: the attached Agent Kanban app icon. Preserve the existing three frosted glass kanban columns, their rounded task cards, their proportions, layout, blue/cyan/violet colors, and the premium dark-indigo Liquid Glass visual identity. Change only the enclosing background and framing to make this a production full-bleed macOS 26 app icon input: eliminate ALL external transparency, eliminate the pre-rounded square container silhouette, eliminate the outer bevel/frame and any transparent margin. Extend the dark midnight-indigo glass gradient naturally all the way to every edge and all four square corners of the canvas. The result must be a perfectly square, fully opaque image from edge to edge; macOS will provide the rounded-corner mask. Keep the central three-column emblem boldly sized and centered, occupying about 70 percent of canvas width and 65 percent of canvas height. Smooth controlled glass highlights and a restrained blue glow, no white backing plate, no surrounding border, no extra outer rounded box. No text, no new symbols, no watermark. This is the icon artwork itself, not an icon mockup or an icon on a sheet. Keep the recognizable existing emblem unchanged as much as possible.
```

### 初版提示词

```text
Use case: logo-brand / stylized-concept. Create one final production macOS application icon for 'Agent Kanban', a native macOS 26 app for managing local AI coding agents and task boards. Asset type: a single square app icon, 1024x1024 or higher square resolution. Art direction: refined macOS Liquid Glass, modern Apple desktop visual language, beautiful but extremely restrained. A substantial rounded-square midnight-indigo glass tile centered with a small consistent transparent margin around the silhouette, corners beautifully smooth. Within the tile, one bold, easily recognizable Kanban-board emblem: three upright frosted glass columns, a few chunky rounded task-card blocks arranged asymmetrically, representing pending, doing and done. Make the emblem a unified custom brand mark, legible at 32 pixels; no tiny text, no thin outlines, no decorative UI controls. Main colors consistent with the app: luminous periwinkle blue and cool cyan, with a subtle violet accent, against a dark navy / deep indigo translucent base. Use convincing polished glass thickness, gentle refraction, crisp soft edge highlights, controlled depth, a soft internal blue glow. Front-on orthographic view, perfectly balanced centered geometry, generous breathing room. Sophisticated professional developer productivity app, calm and precise, not a game. Only the single icon object with a genuinely transparent exterior, no scene or mockup, no sheet of variants. No words, letters, numbers, logos of existing AI products, no robot, no sparkle stars, no mascot, no chrome bevels, no rainbow gradients, no scattered floating particles, no platform badge, no watermark.
```
