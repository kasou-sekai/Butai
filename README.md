# Butai

Butai 是一个 macOS 原生 Spaces 增强工具。当前仓库包含可运行的 Phase 2 技术预览，覆盖工作区命名与切换，以及预设保存、补全和窗口布局恢复。

## 当前能力

- 自动读取当前显示器的普通桌面数量、顺序和当前桌面；
- 工作区名称与 Mission Control 的普通桌面按顺序同步；
- 使用版本化 JSON 原子保存配置，并保留上一份自动备份；
- 收到 Space 变化通知后重新读取 WindowServer 的真实状态；
- 通过合成 Dock 滑动手势直接切换，不依赖 Control+方向键设置；
- 在所有 Spaces 显示不抢焦点的顶部浮窗，悬停展开工作区列表；
- 菜单栏入口、设置窗口、浮窗位置调整和系统兼容性检查；
- 从当前桌面的可见普通窗口保存默认预设和归一化布局；
- 手动添加应用、文件、Finder 文件夹、URL、VS Code 文件夹或工作区；
- 评分式窗口匹配，补全时优先复用已有窗口；
- 使用辅助功能 API 恢复高置信度匹配窗口的位置和大小；
- 在设置、菜单栏和顶部浮窗执行预设，并展示逐项结果摘要；
- 私有 Space ID 仅用于运行时快照，不写入配置文件。

Caps Lock 事件吞噬和应用专用适配器仍属于后续阶段。当前自动捕获以应用和窗口标题进行通用匹配；需要明确文件夹或项目语义时，可在“预设与窗口”中手动添加对应项目。

## 运行

本机需要 macOS 14+ 和 Swift 6.2+。用 Xcode 打开 `Package.swift`，选择 `Butai` scheme 后运行；也可以在终端执行：

```sh
DEVELOPER_DIR=/Volumes/Data/Applications/Xcode-beta.app/Contents/Developer swift run Butai
```

首次运行后，在菜单栏的面具图标中打开“设置…”。“工作区”页面会显示自动检测到的桌面数量和当前桌面；“预设与窗口”页面用于保存、编辑和执行预设。辅助功能权限用于桌面切换与窗口布局恢复。

直接使用 Swift Package 启动的是开发形态。签名、公证、登录时启动和正式发布仍属于后续阶段。

## 测试

```sh
DEVELOPER_DIR=/Volumes/Data/Applications/Xcode-beta.app/Contents/Developer swift test
```

测试覆盖工作区数量约束、含预设的配置/备份持久化、窗口布局边界、评分式窗口匹配、执行结果统计以及导航参数验证。

## 打包测试应用

```sh
zsh scripts/package_app.sh
```

脚本会生成临时签名的 `dist/Butai.app` 和 ZIP 测试包，并把现有 app 移入 `dist/archive`。测试版未经 Apple 公证，仅用于本机开发验证。

## 技术边界

macOS 没有提供满足产品需求的公开 Spaces 查询和切换 API。经用户确认，Butai 通过运行时加载的私有 CGS/SkyLight 读取接口和未公开的 Dock 手势事件实现原生 Spaces 增强。这些实现通过协议隔离，可能随 macOS 更新而需要适配，也不适合 Mac App Store。首版仍只正式支持单显示器和普通 Spaces。
