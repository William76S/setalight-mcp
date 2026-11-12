# setalight-mcp

[中文](#中文) · [English](#english)

## 中文

**v0.4.0** — 用于 **macOS 14+ / set.a.light 3D v2.5** 的本地 MCP 适配器，支持 **Codex、Claude Desktop 和 Claude Code**。通过软件界面读取并设置参数、操作场景、保存工程和检查渲染输出。Python 运行部分仅使用标准库。

这是独立的非官方项目，不是 set.a.light 内部场景 API，不解析或改写 `.set` 文件。参数识别使用本机 Apple Vision；鼠标、键盘和文件对话框由 Swift 助手操作。

### 安装

需要 Python 3.10+、Xcode Command Line Tools，以及已安装并运行的 set.a.light 3D v2.5（`com.elixxier.SALv2`）。

```sh
git clone https://github.com/William76S/setalight-mcp.git
cd setalight-mcp
sh build.sh
python3 server.py --doctor
```

构建生成当前机器架构的 `SetALight MCP.app`，并进行本地 ad-hoc 签名；不是 Apple 公证应用。移动安装目录或重新构建后，核对权限和客户端路径。

Mac 必须已解锁、有可用显示器。语义参数工具要求 **英文界面、SETUP 工作区**。不同版本、缩放、折叠面板和自定义布局会影响可识别控件；工具只报告实际观察到的参数。

BASIC 与 STUDIO 的功能不同。遇到软件的“仅 STUDIO 版可用”提示时，返回 `EDITION_RESTRICTED` 并停止；同一连接会记住已确认受限的对象参数。升级适配器不会解锁软件的付费功能。

### 权限与数据

在「系统设置 → 隐私与安全性」中核对 **SetALight MCP** 的辅助功能和屏幕录制权限。系统可能将权限归属到启动它的宿主应用，以系统显示的身份为准。

- 辅助功能用于输入、命中检查和原生文件对话框。
- 屏幕录制用于捕获 set.a.light 窗口和本机文字识别。
- 适配器自身不联网，不自动保存截图。MCP 客户端可能把返回的文字或图像发送给其模型服务。
- `status`、`screenshot` 和 `inspect_ui` 不触发授权对话框。只有在用户明确同意后，才调用 `request_access`：

```sh
python3 server.py --call request_access --args '{"confirmed":true,"permission":"accessibility"}'
python3 server.py --call request_access --args '{"confirmed":true,"permission":"screen_recording"}'
```

### 连接客户端

以下命令打印当前 Python 和安装目录的绝对路径配置，不修改已有客户端设置。

| 客户端 | 生成配置 | 应用方式 |
| --- | --- | --- |
| Codex | `python3 server.py --config codex` | 合并到 `~/.codex/config.toml`，保留其他配置。 |
| Codex CLI | `python3 server.py --config codex-cli` | 执行输出的 `codex mcp add` 命令。 |
| Claude Desktop | `python3 server.py --config claude-desktop` | 合并到 `~/Library/Application Support/Claude/claude_desktop_config.json` 的 `mcpServers`。 |
| Claude Code | `python3 server.py --config claude-code` | 执行输出的 `claude mcp add` 命令。 |

已有 `setalight` 条目时更新该条目，不要重复添加。重启客户端后，用 `/mcp`、`codex mcp list` 或 `claude mcp get setalight` 检查连接。

Codex TOML 输出包含 `startup_timeout_sec = 10` 和 `tool_timeout_sec = 150`。使用 CLI 注册时，可在 `[mcp_servers.setalight]` 中补上这些值。单次操作总时限为 120 秒。

这些连接必须在同一台 Mac 上运行。Claude 网页版、Codex Cloud 和远程托管连接不能仅凭本地路径控制这台电脑。

### 高效设置参数

1. 调用 `status` 检查权限，必要时用 `fit_window` 将窗口移入屏幕。
2. 用 `inspect_ui` 读取当前对象、可见参数 ID、当前值、控件类型和观察凭据。
3. 用 `select_object` 按 SETLIST 中显示的名称选择对象。建议使用能对应检查器标题的明确名称；同名可见行用 `occurrence` 区分，无法验证身份时停止。
4. 把一组修改放进一次 `set_parameters` 调用。数值框批量填写；滑块、开关和选项分别读取实际状态。
5. 用 `configure_scene` 在一次调用中配置多个有名称的对象。

例如，对当前选中对象设置一组变换（工具名 `set_parameters`）：

```json
{
  "values": {
    "position_x": 4.2,
    "position_y": 3.1,
    "height": 2.4,
    "pitch": -25,
    "roll": 0,
    "yaw": 135
  }
}
```

`expected` 可提供修改前的值；不一致时停止。选择项使用界面显示的完整文字，例如 `{"values":{"aperture":"f/5.6","iso":"ISO100"}}`。用 `list_options` 查询实际可见选项，不猜测设备支持的范围。

| 参数类别 | 处理方式 |
| --- | --- |
| 带标签的数值框 | 动态识别标签、配对当前数值；例如位置、角度及对象尺寸。 |
| 光源功率、色温 | 识别滑轨和当前位置，按实际读回值校准；达不到请求精度时返回错误。 |
| 光源开关、单灯、支架、目标锁定 | 识别图标状态，按布尔目标设置，避免无条件反转。 |
| 相机曝光与器材选项 | 读取选项菜单并按完整文字选择；每次选择后核对读回值。 |
| 面板下方参数 | `discover_parameters` 滚动已展开的检查器，列出可识别参数。 |
| 未识别的颜色面板、姿势骨骼或其他自定义控件 | 使用观察后的原始操作；不会把未知控件伪装成已支持的语义参数。 |

参数目录是当前界面的能力清单，不是覆盖全部版本和每个控件的固定清单。只在成功读回所有请求值时返回 `uiEffectVerified: true`。锁定、禁用、截断文字、取整和参数联动都可能导致读回不一致。

变换按位置先于旋转的顺序写入，与 JSON 键顺序无关。`pitch`、`roll`、`yaw` 使用明确返回的 **0.05° 容差**，处理软件重算欧拉角造成的细微差异；结果同时返回 `requested` 和实际 `after`。其他数值按显示精度核对。功率的数码字体另用七段像素识别，减少相近数字混淆。

### 工具

| 工具 | 用途 |
| --- | --- |
| `status` / `screenshot` / `inspect_ui` | 诊断、窗口 PNG、文字和参数识别；`inspect_ui` 默认不返回图像。 |
| `discover_parameters` | 扫描检查器内可识别参数。 |
| `select_object` | 按 SETLIST 名称选择并检查对象。 |
| `set_parameters` / `configure_scene` | 批量设置当前对象或多个对象；报告修改前、读回值和部分失败。 |
| `list_options` / `choose_option` | 枚举可见选项、设置并验证一个选项。 |
| `click_control` / `menu_command` | 按可见文字操作按钮、页签或菜单，并返回新观察。 |
| `save_project` | 通过原生“另存为”对话框保存，核对文件和工程标题。 |
| `render` | 新建当前场景快照，在 VIEW 中执行 Render Shot，等待对应完整 JPEG。 |
| `scene_command` | 撤销、重做、快照、对准模特、单灯/光源/支架切换、视图和姿势面板命令。 |
| `focus` / `fit_window` | 激活已运行软件，或调整主窗口。 |
| `click` / `click_hid` | HID 点击，支持 `clickCount: 1` 或 `2`。 |
| `scroll_hid` / `drag_hid` | 滚动、平滑拖动；路径和前台归属检查。 |
| `keypress` / `type_text` / `batch` | 按键、Unicode 输入、最多 20 步原始操作。 |
| `request_access` | 经用户同意后请求指定的系统权限。 |

`save_project.path` 必须是绝对 `.set` 路径且父目录存在，已有文件默认拒绝覆盖。`render.output_directory` 必须是当前工程的图像目录，目录名称与工程标题一致。渲染会新建快照并切到 VIEW；只核对该快照的 JPEG，超时表示尚未确认完成，软件可能仍在渲染。返回 SETUP 后可继续改参数。

### 原始操作与错误恢复

原始输入需要 `screenshot` 或 `inspect_ui` 返回的 `observation`，也可使用同一服务进程最近一次观察。凭据包含进程、窗口、边界和时间，超过三分钟或窗口几何变化时拒绝输入。内容布局变化后仍需重新观察。

截图坐标是像素，输入坐标是全局屏幕点：

```text
screenX = coordinateMapping.originX + imageX * coordinateMapping.pointsPerPixelX
screenY = coordinateMapping.originY + imageY * coordinateMapping.pointsPerPixelY
```

- 同一用户的所有客户端共享进程锁；忙碌时拒绝新输入，不排队执行旧坐标。
- 批处理在第一步前检查所有按键、参数类型和长度；任一步失败立即停止。
- 取消通知会终止剩余工作和助手进程；拖动会释放鼠标。已发生的修改不会回滚。
- `set_parameters` 失败时返回 `before`、`verified`、`remaining`；检查现场后决定下一步，不要直接重放整批。
- 文本每次及每个批次合计最多 4096 个 UTF-16 单元。多对象调用最多八个对象、48 个参数。
- 原始事件发送成功、菜单点击、快捷键执行都不等于对应场景修改已验证。
- 不支持锁屏无人值守或同时手动操控鼠标键盘。

### 故障排查

| 现象 | 处理 |
| --- | --- |
| 找不到助手 | 在安装目录运行 `sh build.sh`。 |
| `running: false` | 启动 set.a.light 3D v2.5。 |
| 权限或命中失败 | 检查系统权限、遮挡和屏幕状态。 |
| `STALE_OBSERVATION` | 重新观察并重新定位。 |
| 参数缺失或歧义 | 选中对象、展开相应面板、切换英文界面。 |
| `EDITION_RESTRICTED` | 当前版本不支持；处理软件提示后继续其他参数。 |
| `READBACK_MISMATCH` | 检查返回的实际值，以及锁定、禁用、取整和联动关系。 |
| 客户端未显示新工具 | 重启连接，核对配置指向的 `server.py` 路径。 |

标准输入输出使用逐行 JSON-RPC。支持协议协商版本 `2025-11-25`、`2025-06-18`、`2025-03-26`、`2024-11-05`。程序输出仅用于协议或明确请求的 CLI 结果。

## English

A local **macOS 14+ / set.a.light 3D v2.5** MCP adapter for **Codex, Claude Desktop and Claude Code**. It uses Apple Vision for local OCR and a Swift helper for app-specific input, window capture and native save dialogs. Python requires no third-party runtime packages.

This is an independent, unofficial UI adapter, not an internal scene API. It does not parse or modify `.set` files directly. An unlocked Mac, an active display, Accessibility and Screen Recording permissions are required. Semantic controls require the English UI and SETUP workspace. Windows, Linux and remotely hosted clients are not supported.

Build with `sh build.sh`, diagnose with `python3 server.py --doctor`, and generate client configuration with `--config codex`, `codex-cli`, `claude-desktop` or `claude-code`. Merge configuration without removing existing entries, then restart the client. Codex should allow a 150-second tool timeout; operations have a 120-second total limit.

Prefer `inspect_ui` → `select_object` → `set_parameters`. Submit related fields together. `configure_scene` handles up to eight named objects and 48 parameters. `discover_parameters` scans expanded inspector sections. `list_options` reads visible menu choices. Unknown, ambiguous or disabled controls are not treated as successfully configured.

Numeric fields are filled in batches. Recognized sliders use measured value feedback; toggles are set to a requested state. All requested values must pass readback before `uiEffectVerified` is true. Position is applied before rotation. Euler angles have an explicit 0.05-degree tolerance, returned alongside requested and actual values. Gold power digits use a separate seven-segment pixel reader. Custom color panels, skeletal posing and unrecognized widgets still require observed raw UI operations. The capability list is generated from the current screen and does not claim universal control coverage. BASIC/STUDIO feature restrictions are respected: a recognized edition notice stops the operation with `EDITION_RESTRICTED`. Visible duplicate names use a one-based `occurrence`; an object identity that cannot be verified is rejected.

`save_project` accepts an absolute `.set` path with an existing parent, refuses existing destinations unless `overwrite` is true, and verifies the file and project title. `render` creates a current-scene snapshot, clicks Render Shot in VIEW, and waits for that snapshot’s stable, complete JPEG in the matching project image directory. A timeout is not a completed render.

Raw input requires a recent observation from the same process/window geometry. Coordinates are global screen points, not image pixels; use the screenshot's coordinate mapping. Re-observe after layout changes. Requests are serialized across clients, malformed batches fail before input, and cancellation stops remaining actions. Applied changes are never rolled back automatically; inspect partial results before retrying.

The adapter makes no network requests and does not automatically save screenshots. Returned text/images may be forwarded by the MCP client to its model provider. The helper is locally ad-hoc signed, not notarized. Permission requests require explicit user approval.

Official application behavior and edition differences: [set.a.light 3D v2.5 manual](https://www.elixxier.com/wp-content/uploads/2022/09/set_a_light_3d_v2_5_manual_v1.07_en.pdf).
