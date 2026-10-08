# LiteDownloader（简洁下载器）

一个 macOS 原生下载器，使用 SwiftUI 编写。核心下载引擎借鉴了 [PCL-CE](https://github.com/PCL-Community/PCL-CE)「下载自定义文件」的思路：通过 HTTP Range 多线程分段下载来提速。

## 功能

- 三个输入项：**下载地址**、**保存到**、**文件名**
- 实时显示：进度条、已下载/总大小、百分比、速度、预估剩余时间
- **多线程分段下载**：文件 ≥ 4 MiB 时按 8 MiB/段切分、最多 8 连接并发（支持 Range 的服务器）
- 自动回退：文件较小或服务器不支持 Range 时，退化为单线程顺序下载
- 单段失败自动重试 2 次；支持重定向与 gzip
- 下载中可随时取消，临时文件自动清理

## 技术要点

- 入口 `StartCustomDownload` 校验地址并准备落盘目录
- `Range: bytes=0-0` 探测文件总大小
- `AdaptiveRangeDownloader` 风格的分段并发下载（`withThrowingTaskGroup` + 信号量限流）
- 每段写入独立 `.part.N` 临时文件，全部完成后按序合并，成功后再改名落盘

## 构建

需要 macOS + Xcode Command Line Tools（`swiftc`）。Apple Silicon 可直接运行：

```bash
./build.sh
```

产物为 `dist/简洁下载器.app`。如需安装到系统应用程序目录：

```bash
cp -R "dist/简洁下载器.app" /Applications/
```

## 使用

1. 填入下载地址（`http` / `https`）
2. 选择保存目录（默认 `~/Downloads`）
3. 填写文件名（会根据 URL 自动填充）
4. 点击「开始下载」

## 目录结构

```
.
├── Sources/            # Swift 源码
│   ├── App.swift
│   ├── ContentView.swift
│   └── DownloadEngine.swift
├── Icon/               # App 图标（icns + 生成脚本）
├── build.sh            # 一键构建脚本
└── README.md
```

## 说明

- 仅支持 `http/https` 直链，**不支持**需要登录态（Cookie）的网盘（如百度网盘、夸克网盘）。
- v1 暂未实现暂停/续传与跨会话断点续传。
