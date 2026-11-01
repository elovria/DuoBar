# DuoBar

一个可自定义的 macOS 菜单栏工具，用一个图标同时显示电量、网络和系统状态。

![DuoBar 菜单栏图标预览](docs/icons.png)

## 功能

- 自由组合圆环、中心图标和底部圆点，显示电量、Wi-Fi、CPU、内存、网速等状态。
- 点击图标查看详情，控制 Wi-Fi、音量和充电，快速进入系统设置。
- 支持独立指示灯、电量百分比、登录启动和应用内更新。
- macOS 26 使用液态玻璃面板，macOS 14、15 使用毛玻璃面板。

## 安装

需要 **macOS 14 或更高版本、Apple Silicon（M1 及后续芯片）**。

1. 从 [Releases](https://github.com/elovria/DuoBar/releases/latest) 下载最新的 `arm64.dmg`。
2. 打开安装包，将 DuoBar 拖到“应用程序”。
3. 首次启动如被系统拦截，请在“系统设置 → 隐私与安全性”中点“仍要打开”。安装包使用自签名证书，尚未经过 Apple 公证。

显示 Wi-Fi 名称需要定位权限；启用蓝牙指示灯时会申请蓝牙权限。Wi-Fi 密码仅在选择“记住密码”后保存到本机钥匙串，可在 DuoBar 设置中清除。企业 Wi-Fi 请通过系统设置连接。

## 从源码构建

需要安装完整的 Xcode。

```bash
git clone https://github.com/elovria/DuoBar.git
cd DuoBar
scripts/build.sh
```

生成的应用位于 `build/app.noindex/DuoBar.app`。运行 `scripts/package.sh` 可生成 DMG 安装包。

## 开源许可

DuoBar 采用 [MIT License](LICENSE) 开源。

DuoBar 是独立的非官方项目，与 Apple Inc. 没有关联。
