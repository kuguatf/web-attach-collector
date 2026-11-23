# 网页附件采集识别工具

macOS 桌面应用：按栏目或单页采集网页中的**附件与正文**，并输出到本地数据库、飞书多维表格或 Obsidian。面向不写代码的使用者，重点解决“列表页 + 详情页 + 翻页 + 附件下载 + 正文入库”这一整套重复工作。

![platform](https://img.shields.io/badge/platform-macOS%2013%2B%20Apple%20Silicon-black)
![swift](https://img.shields.io/badge/Swift-5.9-orange)
![version](https://img.shields.io/badge/version-V2.2-blue)

## 功能

- **附件采集**：识别普通链接、`onclick` 跳转、标签属性中的附件地址；支持关键词过滤、扩展名过滤、大小上限与失败重试。
- **正文采集**：在详情页提取正文，自动去除导航、页脚、分享、评论等噪声；可选 OCR 处理扫描件。
- **站点采集方案**：本地规则探测列表、翻页、正文容器与附件选择器；校验不通过时可调用兼容 OpenAI 接口的模型生成声明式方案，预览前 3 条并人工确认后按站点缓存复用。
- **分类采集**：多个栏目独立配置入口、采集内容、页面发现、翻页、输出与参数覆盖。
- **三种输出**：本地 SQLite、飞书多维表格、Obsidian 笔记（附件笔记与正文笔记）。
- **增量采集**：按地址或“地址 + 内容校验值”跳过未变化内容，支持强制全量。
- **定时运行**：通过 launchd + `--silent` 后台执行，日志按天落盘。
- **密钥本地保存**：大模型 API Key 与飞书 App Secret 随应用配置保存（文件权限 0600），不使用钥匙串。

## 系统要求

- macOS 13 及以上，Apple Silicon
- 构建需要 Swift 5.9+（Xcode Command Line Tools 即可，无需 Xcode 工程）
- 飞书输出需要自建应用与多维表格；智能判定需要兼容 OpenAI Chat Completions 的服务

## 构建与运行

```bash
./Scripts/build_app.sh release
open "dist/网页附件采集识别工具.app"
```

修改代码后若行为未更新，先清理旧构建产物：

```bash
rm -rf .build/arm64-apple-macosx/release
./Scripts/build_app.sh release
```

也可以直接使用 `dist/` 下的 `.app`、`.dmg` 或 `.zip`（构建产物不纳入版本库）。应用未做 Apple 公证，首次打开如被拦截，请右键应用选择“打开”。

## 快速开始

1. 打开应用，在「① 采集设置」填写入口地址。
2. 在「② 全局输出目标」至少启用一个输出：本地数据库、飞书或 Obsidian。
3. 点击「开始采集」，在「⑤ 运行日志」查看进度。
4. 若目标站点有列表、详情和翻页，在「③ 分类采集」中新增分类，填写栏目入口后生成「采集方案」，检查预览并点击「保存方案并开始采集」。

## 配置与数据位置

| 内容 | 路径 |
| --- | --- |
| 主配置 | `~/Library/Application Support/网页附件采集识别工具/config/default.json` |
| 站点采集方案缓存 | `~/Library/Application Support/网页附件采集识别工具/site-plans.json` |
| 增量记录 | `~/Library/Application Support/网页附件采集识别工具/incremental.sqlite` |
| 智能判定/正文定位缓存 | `~/Library/Application Support/网页附件采集识别工具/smart-cache.sqlite` |
| 附件暂存 | `~/Library/Application Support/网页附件采集识别工具/attachments/` |
| 运行日志 | `~/Library/Logs/网页附件采集识别工具/YYYY-MM-DD.log` |

配置文件包含大模型 API Key 与飞书应用密钥（明文，权限 0600），请勿提交到代码仓库或分享给他人。

## 文档

- [使用说明书](使用说明书.md)：安装、界面、分类、采集方案、输出、增量、定时运行与排错
- [PRD](PRD.md)：需求、交互规则、错误提示与验收标准
- [采集方案设计](采集方案设计.md)：方案 JSON 字段、生成流程与校验规则
- [验收对照表](验收对照表.md)：逐条验收与实测记录

## 项目结构

```text
.
├── Package.swift
├── Scripts/                 # 构建脚本与 Info.plist
├── Sources/WebAttachCollector/
│   ├── AppModel.swift       # 界面状态与操作
│   ├── Views.swift          # SwiftUI 界面
│   ├── CollectionEngine.swift
│   ├── SitePlan.swift       # 采集方案生成、校验、缓存与执行
│   ├── PageLoader.swift     # 静态/动态页面加载
│   ├── ContentLocator.swift # 正文定位
│   ├── FeishuOutput.swift
│   ├── ObsidianOutput.swift
│   ├── Stores.swift         # SQLite 输出与增量
│   └── ...
└── validation/              # 验证脚本
```

## 使用边界

本工具仅用于采集已获授权访问的公开页面资源，不提供登录、验证码或付费内容绕过能力。请遵守目标网站服务条款与 robots 约定，控制采集频率。

## 版本

当前版本 V2.2：新增站点采集方案 v1，并将密钥改为随应用配置保存。
