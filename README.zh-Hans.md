<p align="center">
  <img src="Luma/Assets.xcassets/BrandMark.imageset/BrandMark.png" width="144" alt="Luma 标志">
</p>

<h1 align="center">Luma · 流光</h1>

<p align="center">家的画面，留在自己的局域网。</p>

<p align="center">
  <a href="README.md">English</a> · <a href="README.zh-Hant.md">繁體中文</a> · <strong>简体中文</strong>
</p>

<p align="center">
  <img src="docs/assets/badge-ios.svg" alt="iOS 26 及以上">
  <img src="docs/assets/badge-swiftui.svg" alt="SwiftUI 与 Liquid Glass">
  <img src="docs/assets/badge-local.svg" alt="局域网使用">
  <img src="docs/assets/badge-languages.svg" alt="三种界面语言">
</p>

<p align="center">
  <a href="#preview">界面预览</a> · <a href="#features">功能</a> · <a href="#installation">安装</a> · <a href="#build">构建</a>
</p>

Luma 是面向 **iOS 26 及以上**的局域网摄像头查看器，使用 SwiftUI 原生 Liquid Glass 界面，通过 RTSP 播放海康威视设备的视频，通过 ISAPI 控制兼容设备的云台。应用提供繁体中文、简体中文和英文界面。

**当前为开发预览版。** 安装包及各版本实际验证范围见 [版本发布](https://github.com/Jacky-0227/luma/releases)。不同摄像头固件的兼容性、云台实际运动与性能仍需要真机验证。

<a id="preview"></a>

## 界面预览

以下为 0.1.3 在 iOS 26 模拟器中的实际截屏，展示首次欢迎页、摄像头栏目和仪表板。图片使用英文；应用支持英文、繁体和简体，不含真实摄像头画面。

<p align="center">
  <img src="docs/assets/welcome-en.png" width="220" alt="Luma 首次欢迎页">
  <img src="docs/assets/home-en.png" width="220" alt="Luma 摄像头栏目">
  <img src="docs/assets/dashboard-groups-en.png" width="220" alt="Luma 仪表板分组，离线占位图">
</p>

<a id="features"></a>

<details>
<summary>自定义仪表板 · 分组与摄像头排序</summary>
<p align="center">
  <img src="docs/assets/dashboard-groups-en.png" width="250" alt="自定义仪表板分组，封面为离线占位图">
  <img src="docs/assets/dashboard-editor-en.png" width="250" alt="仪表板编辑页的摄像头选择、顺序与布局">
</p>
0.1.3 模拟器实际截屏。测试摄像头处于离线状态，封面显示占位图，不包含真实监控画面。
</details>

<details>
<summary>查看云台控制 · 离线演示</summary>
<p align="center"><img src="docs/assets/ptz-en.png" width="300" alt="八方向、停止与变焦云台控制"></p>
测试设备刻意保持离线，图片用于展示控制界面，不代表已连接真实摄像头。
</details>

## 功能范围

| 功能 | 当前实现 |
| --- | --- |
| 实时播放 | 手动添加设备、主／子码流切换、声音开关、全屏、画面适配及有限次数重连 |
| 自定义仪表板 | 分组命名、摄像头排序、每页 4／8／16 或自定义 1–64 个画面、1–8 列布局及快照封面；所有画面保持原比例 |
| 云台控制 | 自动检测兼容海康 ISAPI 的方向与变焦能力及通道；可独立配置网页控制端口 |
| 首页预览 | 显示上次打开并成功播放后的本地静态快照，标明“上次画面”；首页卡片不启动实时连接 |
| 简洁导航 | 日常页面使用栏目名称，品牌标语仅在首次打开的欢迎页展示 |
| 截图与手动录像 | 保存到手机；每段录像最多五分钟 |
| 本地媒体库 | 查看截图、回放应用录制的视频、分享导出和确认后删除 |
| 配置备份 | 导入／导出不含密码的 JSON 设备配置 |
| 语言与外观 | 繁体中文、简体中文、英文；浅色／深色和 iOS 26 原生 Liquid Glass |

目前**未实现**摄像头 SD 卡／NVR 历史录像查询与回放、双向对讲、系统画中画（PiP）、自动发现、云台预置位和持续后台录像。应用内本地媒体库用于回看在手机上手动录制的视频。

项目不提供远程访问、云中继、云账号、在线推送或自动云备份。

## 语言与外观

首次启动跟随 iPhone 的首选语言，也可从应用设置进入系统的 Luma 设置，单独选择语言。界面、输入错误和本地网络权限说明均有三语资源。中文桌面名称为「流光」，英文为「Luma」。列表随系统切换浅色／深色，播放页使用深色背景。

## 局域网使用

1. 将 iPhone 连接到摄像头所在的局域网，确认 RTSP 已在设备上启用。
2. 打开 Luma 并允许“本地网络”访问。
3. 添加设备，填写 IP 地址、RTSP 端口、通道、用户名和密码。按设备实际设置选择码流及传输方式。
4. Luma 会自动查询设备的云台能力，支持时显示相应控制，无需手动开启，也不会等待检测完成才播放。设备的网页端口若有修改，可在“高级控制连接”中调整；它与 RTSP 端口分别配置。

云台检测分别读取各方向与变焦能力，兼容海康 ISAPI 限时和连续运动，不会通过移动摄像头来检测。账号需要对应权限；HTTP 使用 Digest 认证，HTTPS 使用系统信任的证书。松手、离开画面、进入后台或按住达两秒时会发送停止指令。连续控制需要设备收到停止指令；停止未获确认时，会暂停新的移动并提示重试。详见[云台兼容说明](docs/PTZ-compatibility.md)。

在「仪表板 → +」中自定义名称、选择摄像头及排列顺序。每页可选 4、8、16 或自定义 1–64 个画面，列数可选 1–8。第一页的摄像头组成封面；所有画面按原比例缩放，空余位置留黑边，不拉长、压缩或裁切。封面使用内存中的小型设备快照，不支持快照接口时显示占位图。分组保存在本机，暂不包含在设备配置导出中。

0.1.3 补充旧版海康接口与响应格式，停止指令不再等待移动请求返回。[云台协议资料](docs/PTZ-protocol-reference.md)区分了已实现的 ISAPI／IPMD 兼容，以及已研究但尚未实现的 ONVIF、PSIA 和 SDK 接口。

首页预览在成功出画面后自动抓取一次，与媒体库分开保存，重启应用仍保留，并按原比例显示。首次使用需打开对应摄像头一次；连接失败时保留旧图。更改连接源或删除摄像头会使对应预览失效。预览只保存在手机本地，不包含在系统备份或配置导出中。

在实际视频播放后可截图或开始录像。录像到五分钟自动停止；离开播放页、进入后台或切换清晰度也会结束录像并完成文件写入。只有收到完成回调并成功入库后，才显示保存成功。录像容器由源流和 VLC 决定，不保证全部为 MP4；可用应用内播放器回看。

多画面按所选页面数量播放，更多画面会占用更多解码能力、内存和带宽。可配置上限不代表每台手机都能流畅播放对应数量；实际流畅度、耗电和温度取决于手机、摄像头编码与码率。首次连接可先用单路子码流验证。

## 本地数据与隐私

- Luma 没有在线账号服务。摄像头连接直接发生在手机与所配置的设备之间。
- 摄像头密码存放在系统钥匙串中，不写入配置备份。
- 截图和录像保存在应用本地媒体目录，该目录排除系统备份；应用不会自动上传媒体。
- 导出的配置不包含密码、截图或录像，但会包含设备地址等配置。分享前请检查内容。
- 导入配置会保留已有同 ID 的设备；新增设备需要重新填写密码。
- 分享导出由用户选择目标应用。导出后的文件由所选目标管理。

GitHub Actions 只负责构建源码，不需要摄像头地址、视频、密码或 Apple 登录凭据。正常观看时，Windows 电脑和构建运行器不参与视频传输。使用 GitHub 或 Apple 账号是构建和签名流程的一部分，不是 Luma 的在线服务。

<a id="build"></a>

## 开发环境

可在 Windows 上编辑源码，由 GitHub Actions 的 macOS 运行器完成 Xcode 编译、测试和打包；也可在具备对应工具链的 Mac 上开发。

| 项目 | 配置 |
| --- | --- |
| 最低系统 | iOS 26.0 |
| Xcode | 26.2 |
| Swift | Swift 5 语言模式，完整并发检查，显式主线程隔离 |
| 工程生成器 | XcodeGen 2.46.0 |
| CocoaPods | 1.16.2 |
| 播放组件 | MobileVLCKit 3.7.3 |
| App Bundle ID | `app.luma.viewer` |
| CI 运行器 | `macos-15`，使用 Xcode 26.2 |

`project.yml` 是工程配置源，XcodeGen 生成 Xcode 工程，CocoaPods 生成 workspace。生成的工程和依赖目录不提交。工具下载及播放组件使用固定版本和校验值；运行器镜像及间接工具依赖仍可能变化，因此不承诺构建结果逐字节一致。

### 在 Windows 上检查资源

安装 Python 3 后，在项目根目录运行：

```powershell
python scripts/validate-project.py
```

检查包括三语键名和格式占位符、权限说明、图标原图及资源引用。它不代替 Swift 编译、模拟器测试或真机测试。CI 会从 `design/Luma-icon-source.png` 生成 1024 × 1024 的应用图标，再校验用于打包的资源。

### 云端测试与安装包

将源码放入自己的 GitHub 仓库并启用 Actions。工作流在 `main` 的代码变更后运行，也可在网页手动触发。仅修改文档的推送不会自动触发构建。

已安装并登录 GitHub CLI 时，在仓库目录执行：

```powershell
gh workflow run ios.yml
gh run list --workflow ios.yml --limit 5
```

将 `RUN_ID` 替换为实际运行 ID，查看结果并下载产物：

```powershell
gh run view RUN_ID
gh run download RUN_ID --name Luma-iPhone-unsigned --dir build/download
gh run download RUN_ID --name Luma-test-report --dir build/report
```

网页入口为 **Actions → Build Luma for iPhone → 对应运行 → Artifacts**。工作流成功完成测试和打包后才提供未签名 IPA；失败运行可能只有诊断报告。通过网页下载产物时先解压 ZIP，取得 `Luma-unsigned.ipa`。

工作流执行资源校验、固定依赖安装、iOS 模拟器单元与界面测试、真实 VLC 截图／录像／回放集成测试，以及 arm64 真机 Release 打包与 IPA 检查。集成测试使用本地生成的视频，不连接实际摄像头。

产物包括未签名 IPA 和精简诊断报告，默认保留一天，请及时下载。工作流最长运行 35 分钟，同分支的新运行会取消旧运行。构建依赖托管服务的可用额度，使用前请检查自己账号的 [GitHub Actions 计费与额度](https://docs.github.com/en/billing/concepts/product-billing/github-actions)。

### 在 Mac 上开发

使用 Xcode 26.2，安装对应 iOS 模拟器运行时。在项目根目录运行与 CI 相同的准备脚本：

```bash
export DEVELOPER_DIR=/Applications/Xcode_26.2.app/Contents/Developer
bash scripts/ci-bootstrap.sh
open Luma.xcworkspace
```

脚本会准备图标、生成工程并安装固定依赖。开发时打开生成的 workspace；安装到自己的设备需要在 Xcode 或签名工具中配置自己的开发团队。

<a id="installation"></a>

## 从 Windows 安装到 iPhone

此仓库构建的 IPA **未签名**，需要自行签名后安装。

1. 确认 iPhone 运行 iOS 26 或更新版本。
2. 从 [Sideloadly 官方网站](https://sideloadly.io/)安装 Windows 版本，并按其说明准备 Apple 设备驱动等前置组件。
3. 用数据线连接 iPhone，解锁手机并信任电脑。
4. 在 Sideloadly 中选择手机和下载的 `Luma-unsigned.ipa`，使用自己的 Apple 账号签名及安装。
5. 根据 iPhone 提示信任开发者并开启开发者模式，然后启动 Luma。
6. 允许本地网络访问，在应用内填写设备信息。

Sideloadly 支持免费 Apple 账号；免费签名通常有效七天，需要定期续签。实际安装、启动和续签仍需用自己的手机验证，具体要求以 [Sideloadly 官方说明](https://sideloadly.io/)为准。不要把 Apple 密码或含摄像头账号的 RTSP 地址提交到代码、Issues 或构建日志中。

## 真机验证清单

模拟器和自动化测试无法覆盖真实摄像头、局域网及免费签名的全部行为。使用前请验证：

- 免费签名后的安装、启动和续签。
- 摄像头认证、主／子码流播放、声音和清晰度切换。
- 云台方向、变焦、松手停止、控制通道与账号权限。
- 连续录制多段视频，停止后的回看与分享导出。
- 四画面资源占用、长时间观看的耗电与温度。
- 本地网络权限拒绝后重新开启、Wi-Fi 断开与恢复。
- 横竖屏、进入后台后返回和切换设备。
- 三种语言、常用字体大小和辅助功能下的界面。

## 项目目录

| 路径 | 用途 |
| --- | --- |
| `Luma/` | SwiftUI 界面、设备配置、播放和本地服务 |
| `Luma/Resources/` | 三语界面与权限说明 |
| `Luma/Assets.xcassets/` | 图标、品牌图案与颜色 |
| `Tests/` | 核心逻辑、捕获存储及真实 VLC 集成测试 |
| `UITests/` | 界面流程与三语截图 |
| `project.yml`、`Podfile` | 工程配置与播放依赖 |
| `.github/workflows/ios.yml` | 自动化测试和未签名 IPA 打包 |
| `scripts/` | 工具准备、资源校验、测试与产物检查 |
| `design/` | 图标原始素材 |

## 第三方组件与许可

Luma 使用 [VideoLAN VLCKit](https://github.com/videolan/vlckit)及其包含的开源组件。许可、来源和再分发注意事项见 [ThirdPartyNotices.md](ThirdPartyNotices.md)。分发自己构建的二进制前，应核对并履行相关组件的许可要求。

界面与名称为独立设计，项目与海康威视、IPCams 没有关联或背书关系。
