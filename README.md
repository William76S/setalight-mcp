# setalight-mcp

[中文](#中文) · [English](#english)

## 中文

用于 **macOS / set.a.light 3D v2.5** 的本地 MCP 适配器。通过标准 stdio 连接 Codex、Claude Desktop、Claude Code 等支持 MCP 的客户端，提供窗口截图、鼠标和键盘操作。

这是独立的非官方项目。它通过软件界面操作，不是 set.a.light 内部场景 API；不会直接解析或改写 `.set` 工程。

### 环境要求

- macOS 14 或更高版本，已解锁且有可用显示器。
- 本机安装并启动 set.a.light 3D v2.5，应用标识为 `com.elixxier.SALv2`。
- Python 3.10+，无需第三方 Python 运行依赖。
- Xcode Command Line Tools，用于编译 Swift 助手。

Windows、Linux、Claude 网页版以及远程托管的 MCP 连接不适用于控制本机软件。不同 set.a.light 版本的界面可能不同，坐标必须根据当前截图确定。

### 安装

```sh
git clone https://github.com/William76S/setalight-mcp.git
cd setalight-mcp
sh build.sh
python3 server.py --doctor
```

`build.sh` 在本机生成并进行 ad-hoc 签名的 `SetALight MCP.app`。它不是 Apple 公证应用，构建结果仅适用于当前编译架构。重新编译或移动目录后，可能需要重新核对系统授权和客户端路径。

### 系统授权

在 macOS「系统设置 → 隐私与安全性」中核对 **SetALight MCP**：

- **辅助功能**：用于鼠标、键盘及窗口操作。
- **屏幕录制**：用于读取 set.a.light 窗口图像。

系统可能将授权归属到启动助手的宿主应用；以系统显示的应用身份为准。授权由用户完成，适配器不会自行开启权限。`status` 和 `screenshot` 不会请求新授权。

获用户明确同意后，可使用以下命令发起相应系统授权流程：

```sh
python3 server.py --call request_access --args '{"confirmed":true,"permission":"accessibility"}'
python3 server.py --call request_access --args '{"confirmed":true,"permission":"screen_recording"}'
```

macOS 的这些权限本身并非仅限某个目标应用；本项目代码将操作和截图限制到 set.a.light。截图以 PNG 返回 MCP 客户端，不自动写入磁盘；客户端可能将图像传给其使用的模型服务。适配器自身不建立网络连接。

### Claude Desktop

生成适用于当前安装位置和 Python 解释器的配置：

```sh
python3 server.py --config claude-desktop
```

将输出的 `setalight` 条目合并进 Claude Desktop 配置的 `mcpServers`，保留其他已有配置。macOS 配置文件通常位于：

```text
~/Library/Application Support/Claude/claude_desktop_config.json
```

完全退出并重新启动 Claude Desktop，在本地 MCP 连接列表中确认 `setalight` 可用。配置生成命令只打印内容，不修改客户端设置。

### Claude Code

生成注册本地 stdio 服务的命令：

```sh
python3 server.py --config claude-code
```

检查并执行输出的命令，然后运行：

```sh
claude mcp get setalight
```

也可在 Claude Code 中通过 `/mcp` 查看连接状态。配置使用绝对路径，并通过参数列表传递给 Python，支持含空格的安装目录。

### Codex

生成适用于当前安装位置的 TOML 配置：

```sh
python3 server.py --config codex
```

将输出的 `[mcp_servers.setalight]` 配置合并到 `~/.codex/config.toml`，保留其他已有配置；如果已经存在同名条目，更新该条目，不要重复添加。配置包含 Python 和脚本的绝对路径，以及 150 秒工具超时，以覆盖原生助手最长 120 秒的调用。配置生成命令只打印内容，不修改客户端设置。

Codex CLI、IDE 扩展以及使用同一 Codex 主机配置的桌面客户端可使用这份配置。重新启动对应客户端，并通过 `/mcp` 查看连接状态。也可在终端检查：

```sh
codex mcp get setalight
codex mcp list
```

如果偏好 CLI 注册方式，可运行 `python3 server.py --config codex-cli`，检查并执行输出的 `codex mcp add` 命令。该方式使用 Codex 的默认超时；需要较长截图或批处理调用时，在 `[mcp_servers.setalight]` 下设置 `tool_timeout_sec = 150`。

必须使用运行在这台 Mac 上的本地会话。单纯在 Codex Cloud 中添加本地路径无法启动这台 Mac 上的助手。组织管理策略也可能限制可用 MCP 服务。

### 工具

| 工具 | 功能 |
| --- | --- |
| `status` | 读取应用运行状态、权限、窗口边界及显示器信息。软件未启动时仍返回诊断。 |
| `screenshot` | 捕获一个可见的 set.a.light 窗口，返回 PNG 与坐标换算信息。默认选择最大窗口；可用 `windowId` 指定对话框。 |
| `focus` | 激活已运行的软件。 |
| `fit_window` | 将主窗口调整到主显示器可用区域。 |
| `click` / `click_hid` | 经窗口归属校验的 HID 左键点击，两者行为相同。 |
| `scroll_hid` | 在指定位置滚动；`deltaY` 为非零整数，正数向上，负数向下。 |
| `drag_hid` | 经校验的平滑拖动，包含 Unity 所需的相对位移。 |
| `keypress` | 在目标软件位于前台时发送按键，例如 `cmd+a`、`return`、`shift+tab`。 |
| `type_text` | 输入 Unicode 文本，不使用剪贴板；不自动清空字段或按回车。 |
| `batch` | 顺序执行 1–20 个已确定的输入步骤，失败或切换前台应用时停止。 |
| `request_access` | 用户明确同意后发起指定的系统授权流程。 |

`screenshot` 的 `maxWidth` 范围为 640–2560，默认 1600。输入坐标使用全局屏幕点，不直接使用截图像素。按照截图返回的 `coordinateMapping` 换算：

```text
screenX = originX + imageX * pointsPerPixelX
screenY = originY + imageY * pointsPerPixelY
```

每次操作前使用当前窗口图像确定位置，操作后重新截图验证。事件发送成功不代表软件已完成预期修改。批处理只适合单个已知控件内的确定步骤，不应用于未观察的条件分支。

### 错误处理与限制

- 同一用户的多个客户端通过进程锁串行访问助手；忙碌时返回错误，不排队执行过时的坐标操作。
- 点击、滚动和拖动检查目标窗口、显示器及辅助功能命中归属；前台改变时停止后续输入。
- 拖动中断会释放鼠标按钮。输入不是事务，失败前的步骤可能已生效；检查界面后再决定是否继续。
- `batch` 错误包含 `completedCount`、`failedIndex` 和已完成步骤结果。输入被拒绝或中断时，MCP 返回 `isError: true`。
- 每次文字输入及单个批次合计最多 4096 个 UTF-16 单元。未知字段、非有限坐标、非法滚动值会被拒绝。
- 软件菜单和自定义 Unity 控件主要依赖视觉定位；适配器不理解灯具或场景的语义。
- 不支持后台无人值守的锁屏操作、同时手动操控鼠标键盘，或跨机器控制。客户端取消请求不能回滚已发送的事件。
- `--call screenshot` 的命令行输出包含 PNG 的 Base64 数据，终端诊断优先使用 `--doctor`。

协议通过 stdin/stdout 传输逐行 JSON-RPC；stdout 仅用于协议响应。支持协商版本 `2025-11-25`、`2025-06-18`、`2025-03-26`、`2024-11-05`，客户端需接受其中一种版本。

### 故障排查

| 现象 | 处理 |
| --- | --- |
| 找不到原生助手 | 在仓库目录运行 `sh build.sh`。 |
| `running: false` | 手动启动 set.a.light 3D v2.5。 |
| 没有可用显示器或截图超时 | 解锁 Mac、接好显示器，并检查屏幕录制授权。 |
| 输入被拒绝 | 检查辅助功能授权及窗口遮挡，重新截图定位。 |
| Codex 或 Claude 无法启动服务 | 重新生成配置，核对 Python 和 `server.py` 的绝对路径，然后重启客户端。 |
| 修改未生效 | 先核对当前界面与字段焦点，不要直接重放整批动作。 |

## English

A local, unofficial MCP adapter for **set.a.light 3D v2.5 on macOS 14+**. It provides window screenshots and validated HID mouse/keyboard input over stdio. It does not expose a scene API or edit `.set` files directly.

Build with `sh build.sh`, then run `python3 server.py --doctor`. Python 3.10+ and Xcode Command Line Tools are required; there are no third-party Python runtime dependencies. The helper is locally ad-hoc signed and must be built for the Mac on which it will run.

Use `python3 server.py --config claude-desktop` to print the configuration entry for Claude Desktop. Merge it with existing `mcpServers` entries and restart the client. Use `python3 server.py --config claude-code` to print the corresponding Claude Code registration command. Neither command edits client settings.

For Codex, run `python3 server.py --config codex` and merge the resulting `[mcp_servers.setalight]` table into `~/.codex/config.toml`. Update an existing table instead of adding a duplicate. This includes absolute executable paths and a 150-second tool timeout. Restart your local Codex client and check `/mcp` or `codex mcp get setalight`. The CLI, IDE extension, and desktop clients using the same Codex host share this configuration. Alternatively, `--config codex-cli` prints a registration command using the client's default timeout. These commands only print configuration; they do not change client settings.

Accessibility permission enables input; Screen Recording separately enables screenshots. Only the user grants these permissions. The adapter restricts input and capture to the running application `com.elixxier.SALv2`, although the underlying macOS permissions are broader. It opens no network connections; the connected client may send returned screenshots to its model provider.

Screenshots include image-to-screen coordinate mapping. Observe the current image before input and verify the result afterward. Interrupted input can be partly applied; do not blindly replay a batch. The Mac must remain unlocked with an active display. Local Codex clients, Claude Desktop, and local Claude Code can use this stdio service; cloud sessions, the Claude website, and remote connectors cannot directly launch the local helper.

References: [Codex MCP setup — official OpenAI documentation](https://learn.chatgpt.com/docs/extend/mcp?surface=cli), [Claude Desktop local MCP setup](https://modelcontextprotocol.io/docs/develop/connect-local-servers), [Claude Code MCP setup](https://code.claude.com/docs/en/mcp), [MCP stdio transport](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports).
