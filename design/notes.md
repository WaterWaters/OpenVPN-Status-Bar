# VPNStatusBar v2 · 初始化配置设计说明

> 设计稿：`design/mockup.html`（含初始化向导交互演示，浏览器直接打开）
> Token：`design/tokens.css`
> 状态：**设计稿待批准 → 通过后落地 SwiftUI**

## 目标与背景

**现状（v1）**：app 通过路径探测调用 `vpn-runner.sh`，脚本从**上一级文件夹**读取
`dev-ai.ovpn`（第一个 .ovpn）与 `.user`（明文 USERNAME/PASSWORD）完成连接与鉴权。
依赖固定目录结构，分发/换电脑时要手动摆放文件、手动编辑凭据，明文密码落盘。

**目标（v2）**：**不再依赖本地文件**，改为在 app 内完成初始化：

1. **导入 ovpn 配置文件**（文件选择器 / 拖放）
2. **输入鉴权信息**（用户名 + 密码）
3. 凭据**存入 Keychain**（而非明文 .user），ovpn 复制进 app 自己的数据目录
4. 之后一切照旧：连接 / 断开 / 断线自动重连 / 日志展示

## 新增状态：未配置（unconfigured）

状态机新增初始态 **未配置**（首次启动 / 清除配置后）：

| 元素 | 未配置时的表现 |
| --- | --- |
| 菜单栏图标 | 灰 `network.slash`（当前已断开样式） |
| 状态块 | 瓷砖灰底斜杠图标 · 灰点 · 标题「未配置」 · 时长 `--:--:--` · 元信息「导入 VPN 配置后开始」 |
| 主操作按钮 | **「导入配置…」**(中性/蓝系) → 打开初始化向导 |
| 自动重连开关 | 禁用（无配置无可连），打开向导后仍可进入 |
| 详情/日志 | 日志显示「（暂无日志）」 |

状态流转：`未配置 --(导入完成)--> 已断开`；已配置状态下从面板底部 **「配置…」** 进入向导（修改模式：预填当前文件名与用户名，密码留空=保持原密码）。

## 初始化向导（面板内第三步流程）

设计为**面板内向导**（不跳新窗口，与现状一致的弹窗面板内完成）：

### Step 1 · 选择配置文件
- 虚线拖放区：「把 .ovpn 拖到这里，或 **选择文件…**」
- 点「选择文件…」→ 系统文件选择器（仅允许 .ovpn）
- 选中后显示文件卡：文件名 + 解析出的摘要（远程地址 `remote`、协议 `proto`、隧道网段、证书是否内嵌）
- 校验失败（非 .ovpn / 内容缺失 remote）→ 行内错误提示，不允许下一步

### Step 2 · 鉴权信息
- 用户名输入框 + 密码输入框（SecureField）
- 密码可见性切换（眼睛图标）
- 说明行：「密码仅存入 macOS 钥匙串，连接时临时生成认证文件，断开即删除」
- 此步可选「跳过」(仅当 ovpn 内已内嵌凭据/仅需证书)，默认要求填写

### Step 3 · 保存并完成
- 摘要确认：配置文件名 + 服务器地址 + 用户名（脱敏）
- 主按钮「保存并完成」→ 进度 300ms → 回到主面板（已配置 → 已断开），事件行「配置已保存：dev-ai.ovpn」
- 次按钮「上一步」

## 存储与安全

| 数据 | 存储位置 | 说明 |
| --- | --- | --- |
| ovpn 配置 | `~/Library/Application Support/VPNStatusBar/config.ovpn` | 导入时复制，不依赖原文件 |
| 用户名 | UserDefaults（可选，或 Keychain 一并存） | 非敏感 |
| 密码 | **Keychain**（`kSecClassGenericPassword`，服务 `VPNStatusBar`） | 唯一明文凭据落点 |
| auth 临时文件 | 连接时生成 `.auth.tmp`（0600），断开即删 | 沿用 v1 |
| ovpn 内含明文密码行 | 导入时提示「已去除内嵌密码，使用钥匙串凭据」并清洗 | 可选增强 |

**兼容**：不读取上一级文件夹的 `dev-ai.ovpn` / `.user`（v1 目录结构不再必需）；
旧安装首次启动显示未配置，用户重新导入一次即可。

## 与现状的差异（交互）

| 现状（v1） | 新设计（v2） |
| --- | --- |
| 依赖上一级文件夹文件，无初始化 UI | 面板内三步导入向导 |
| 明文 .user 文件 | Keychain 密码 + 用户名 |
| 无"未配置"状态 | 新增未配置初始态 + 导入入口 |
| 配置只读（跟随文件） | 面板底部「配置…」→ 修改模式：更换 ovpn / 修改凭据 |

## SwiftUI 落地计划（设计通过后执行）

**修改文件（无删除，新增 1 个）：**

1. `Sources/VPNStatusBar/VPNManager.swift`
   - 新增 `@Published var isConfigured: Bool`（= 配置存在）
   - 状态机增 `unconfigured` 分支；`status` 初值按 `isConfigured` 决定
   - 配置读写：`saveConfig(ovpn:username:password:)` / `loadConfig()` / `clearConfig()`
     - ovpn → Application Support 目录复制
     - 密码 → Keychain（Security.framework）；用户名 → UserDefaults
   - `connect()` 改为基于已存配置生成 auth 临时文件后调 runner（runner 改为参数化：`--config` + `--auth`，不再依赖同目录文件）
2. `Sources/VPNStatusBar/ContentView.swift`
   - 未配置态渲染（状态块/按钮文案/开关禁用）
   - 导入向导视图 `SetupSheet`：三步流程 + 文件选择（NSOpenPanel）/拖放 + SecureField + 校验 + 保存；支持 `new`（导入）/ `edit`（修改配置，预填当前信息，密码留空=保持原密码）两种模式
   - 面板底部「配置…」入口（齿轮行）→ 修改模式向导
3. `Sources/VPNStatusBar/App.swift`
   - 无大改；图标 unconfigured 时灰
4. 新增 `Sources/VPNStatusBar/Keychain.swift`（Keychain 封装：set/get/delete）
5. `dist/vpn-runner.sh`：参数化改造（接收 `--ovpn <path>`、`--auth <path>`）

**验证**：
- 首次启动 → 未配置 → 导入 dev-ai.ovpn + 凭据 → 保存 → 连接成功
- 重启 app 凭据仍在（Keychain）；清除配置 → 回未配置
- 浅色/深色下对比度达标