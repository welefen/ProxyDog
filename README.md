# ProxyDog

原生 macOS HTTP/HTTPS 抓包调试工具，界面与工作流参考 Proxyman。使用 Swift + SwiftUI + SwiftNIO 编写，无需 Xcode 工程即可构建。

## 功能

- **HTTP / HTTPS 抓包**：本地 HTTP 代理监听 `127.0.0.1:8888`，通过本地根证书对 HTTPS 做 TLS 解密（MITM），明文与加密流量统一展示。
- **实时请求列表**：方法、状态码、大小、耗时、协议类型图标；域名分组、失败标记、收藏（Pinned）。
- **请求详情**：Overview（URL、客户端、耗时、大小、解密状态）、Headers（请求/响应表头，点击复制）、Body（JSON 树、文本、图片预览、二进制 Hex、Pretty/Raw 切换）。
- **检索与清理**：全文搜索、按域名过滤、暂停/恢复抓包、清空、单条删除、收藏。
- **导出**：HAR 1.2 文件导出、复制为 cURL。
- **系统代理**：一键设置/关闭 macOS 系统 HTTP/HTTPS 代理（需要管理员授权）。
- **外观与语言**：浅色为默认设计，完整支持深色模式，默认跟随系统；界面内置简体中文与 English，默认跟随系统语言，可在设置中切换（切换后自动重启生效）。
- **数据埋点**：使用 Aptabase，App Key 在首次启动向导中交互式询问，可跳过；不采集任何请求内容。

## 截图

主界面：左侧域名导航、中间请求列表、右侧详情。

![请求列表](Docs/screenshots/main-window.png)

Body 详情：JSON 树与 Pretty/Raw 切换。

![请求详情](Docs/screenshots/request-body.png)

设置页：连接、外观、证书、埋点配置，底部显示版本号。

![设置](Docs/screenshots/settings.png)

首次启动向导：安装根证书、填写 Aptabase App Key、设置系统代理。

![首次启动向导](Docs/screenshots/onboarding.png)

## 语言

界面支持简体中文与 English 两套文案，默认跟随系统语言（本机为中文时即中文界面）。设置 → 外观 → 语言 可在「跟随系统 / 简体中文 / English」之间切换，切换后应用会自动重启。所有界面文案都放在 `Resources/Localization/` 下的 `.strings` 片段里，新增文案时同步补全两种语言，并用 `python3 scripts/check_localization.py` 校验。

## 环境要求

- macOS 14 或更高版本
- Xcode Command Line Tools（`xcode-select --install`），Swift 5.9+；不需要安装完整 Xcode

## 构建与运行

```bash
# 构建可双击运行的 ProxyDog.app（输出到 build/ProxyDog.app）
./scripts/build_app.sh

# 构建并启动
./scripts/run_app.sh
```

首次构建会通过 SwiftPM 拉取 swift-nio / swift-nio-ssl 并编译 BoringSSL，耗时数分钟。

## 使用

1. 启动后代理自动监听 `127.0.0.1:8888`（可在设置中修改端口）。
2. 首次启动向导中安装 ProxyDog 根证书，否则 HTTPS 流量只能看到 CONNECT 隧道。
3. 打开设置页的「System proxy」，或手动把客户端代理指向 `127.0.0.1:8888`。
4. 用 curl 验证：

```bash
curl -x http://127.0.0.1:8888 http://example.com/
curl -k -x http://127.0.0.1:8888 https://example.com/   # -k：curl 尚未信任 ProxyDog 根证书
```

抓到的请求会实时出现在列表中，点击任意一条查看详情。

## 根证书

- 位置：`~/Library/Application Support/ProxyDog/Certificates/ca.crt`
- 安装 / 移除：设置页 → Certificate；安装需要管理员授权，走系统标准授权弹窗。
- 证书仅用于本机抓包调试，卸载应用后建议在「钥匙串访问」中删除该根证书。

## 数据埋点

埋点使用 Aptabase。App Key 在首次启动向导第 3 步交互式询问，也可以随时在设置页修改；留空或跳过则完全不上报。事件只包含启动、开始/停止代理、导出等行为与操作系统版本等基础信息，不含任何请求内容，因此不提供隐私协议页面。

## 项目结构

```
Sources/ProxyDog/
├── ProxyDogApp.swift        # SwiftUI 入口、窗口、菜单
├── AppState.swift           # 应用状态与动作（UI 唯一数据入口）
├── main.swift               # 正常启动 / --headless 分流
├── Models/                  # 抓包数据模型、存储、设置、HAR、埋点
├── Core/                    # NIO 代理引擎、证书颁发、系统代理
├── UI/                      # 主窗口、设置页、首次启动向导、设计系统
└── Dev/                     # headless 运行与自检
scripts/                     # 构建、运行、测试、截图、图标、演示流量
Support/                     # Info.plist、应用图标
```

## 开发与测试

```bash
# 快速编译检查
./scripts/build.sh

# 端到端代理测试：明文 HTTP、HTTPS 解密、POST、失败请求、抓包断言、端口复用
./scripts/test_proxy.sh

# 无界面自检：证书签发、HAR 导出、cURL 导出、进程内重启、端口占用、设置持久化
./.build/debug/ProxyDog --headless --selftest

# 无界面启动代理（输出 JSON Lines 抓包事件）
./.build/debug/ProxyDog --headless --port 8899 --out /tmp/captures.jsonl

# 校验中英文案完整性
python3 scripts/check_localization.py

# 生成演示流量 / 重置应用状态 / 截取窗口
./scripts/demo_traffic.sh
./scripts/reset_app.sh
./scripts/screenshot.sh /tmp/proxydog.png
```

开发调试时可以载入一组示例流量，便于在没有真实请求时检查界面（`--sample-tab body` 会打开 Body 页，`--sample-request N` 选中第 N 条）：

```bash
defaults write com.proxydog.app app.onboardingCompleted -bool true
./build/ProxyDog.app/Contents/MacOS/ProxyDog --sample-traffic
./build/ProxyDog.app/Contents/MacOS/ProxyDog --sample-traffic --sample-tab body
```

## 已知限制

- 仅支持 HTTP/1.1：TLS 握手时 ALPN 只协商 `http/1.1`，不支持 HTTP/2 帧解析。
- 上游 TLS 不校验证书，便于抓取自签名证书的开发服务器。
- WebSocket 显示为 101 隧道，不解码帧。
- 单个请求/响应体最多保存 2 MB（超出部分仍然透传，仅不入库）。
- 关闭系统代理时直接关闭代理开关，不会恢复开启前的原有代理配置。

## 版本

v1.0.0
