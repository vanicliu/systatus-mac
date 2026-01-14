# systatus-mac

一个用于 SwiftBar 的系统状态插件，菜单栏显示简洁状态，下拉展示详细信息。

[English](README.md) | [中文](README.zh.md)

![systatus-mac 截图](assets/swiftbar-demo.png)

## 功能

- 菜单栏图标在电量低于 30% 时显示电量百分比。
- 下载/上传网速（缓存采样，无需 sleep）。
- Wi‑Fi 名称（读取 `en0` 的首选网络列表）。
- VPN 状态（通过 `scutil --nc list` 判断 ON/OFF）。
- 电池 + CPU 占用同一行显示。
- 内存与磁盘使用情况。
- 双列对齐布局 + SwiftBar 分隔线。

## 需求

- macOS
- SwiftBar
- zsh

## 安装

1. 将 `keystats.1s.sh` 放入 SwiftBar 插件目录。
2. 赋予可执行权限：

```sh
chmod +x keystats.1s.sh
```

3. 在 SwiftBar 刷新插件。

## 说明

- Wi‑Fi 名称来自 `en0` 的首选网络列表第一项。
- VPN 状态为任意连接中的服务即显示 ON。
- 为保证对齐，建议使用等宽字体（如 SF Mono）。

## 自定义

- `RIGHT_COL` 控制右侧列对齐位置。
- `SYSINFO_INTERVAL` 控制 CPU/内存/磁盘缓存刷新间隔。

## 许可

MIT
