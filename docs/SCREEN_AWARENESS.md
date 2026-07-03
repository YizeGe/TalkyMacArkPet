# MacArkPet 屏幕感知系统

## 概述

MacArkPet 新增的屏幕感知功能让桌宠能够「看到」你在屏幕前做什么，然后根据角色的设定说出有情境感的话。

**运行时不需要 AI、不需要联网、不截屏、不录屏。** 所有台词都是预先生成的，情境匹配通过关键词规则完成。

## 工作原理

```
你的屏幕 → App 名称 + 窗口标题 → 关键词匹配 → 情境判定 → 角色台词
                 ↑                           ↑
           系统 API 获取                 ScreenTriggers.toml
                                       (用户可自行编辑)
```

## 触发的台词情境

| 情境 | 示例场景 | 触发时机 |
|------|---------|---------|
| `coding` | 写代码、GitHub、LeetCode | 检测到 IDE/代码平台 |
| `watching_video` | B站、YouTube、Netflix | 检测到视频网站 |
| `gaming` | Steam、游戏、明日方舟 | 检测到游戏平台 |
| `social` | 微信、微博、贴吧 | 检测到社交平台 |
| `working` | Notion、Office、飞书 | 检测到办公软件 |
| `chatting` | Discord、QQ、Telegram | 检测到聊天工具 |
| `shopping` | 淘宝、京东、亚马逊 | 检测到购物网站 |
| `reading_news` | 知乎、Reddit、新闻 | 检测到新闻/社区 |
| `ai_chat` | ChatGPT、Claude | 检测到 AI 对话平台 |
| `studying` | Coursera、维基百科 | 检测到学习平台 |
| `writing` | 语雀、Typora | 检测到写作工具 |
| `deep_night` | 凌晨 0-5 点 | 时段判断 |
| `idle_long` | 5 分钟无操作 | 系统 idle 检测 |
| `long_screen_time` | 连续用屏过久 | 计时器 |

## 编辑触发规则

配置文件位于：

```bash
~/Library/Application Support/MacArkPet/Config/ScreenTriggers.toml
```

第一次启动时会自动从 App 内复制默认配置。你可以用任何文本编辑器修改它。

### 示例：增加一个新网站的触发

```toml
# 在 [website_categories.coding] 下增加
[website_categories.coding]
new_website = ["new-website.com", "NewWebsite"]
```

### 完整的格式说明

```toml
[website_categories.情境名]
任意关键词 = ["APP的bundleID1", "APP的bundleID2", "窗口标题关键词1"]
```

- **bundle ID**：包含 `.` 的字符串，如 `com.microsoft.VSCode`
- **窗口标题关键词**：普通字符串，如 `GitHub`、`bilibili`
- **情境名**必须是以下之一：`coding`, `watching_video`, `social`, `chatting`, `reading_news`, `shopping`, `gaming`, `working`, `email`, `designing`, `writing`, `ai_chat`, `studying`, `browsing`, `developing`

## 支持的 20 个角色

| # | 角色 | 角色 ID | 台词数 |
|---|------|---------|-------|
| 1 | 阿米娅 | `002_amiya` | ~50 条 |
| 2 | 凯尔希 | `003_kalts` | ~45 条 |
| 3 | 能天使 | `103_angel` | ~50 条 |
| 4 | 德克萨斯 | `102_texas` | ~30 条 |
| 5 | 拉普兰德 | `140_whitew` | ~35 条 |
| 6 | 荒芜拉普兰德 | `1038_whitw2` | ~35 条 |
| 7 | 缪尔赛思 | `1011_slag` | ~40 条 |
| 8 | 水月 | `437_mizuki` | ~35 条 |
| 9 | 余 | `2026_yu` | ~40 条 |
| 10 | W | `356_whislash` | ~35 条 |
| 11 | 陈 | `010_chen` | ~35 条 |
| 12 | 斯卡蒂 | `263_skadi` | ~30 条 |
| 13 | 浊心斯卡蒂 | `1012_skadi2` | ~25 条 |
| 14 | 艾雅法拉 | `148_kjera` | ~35 条 |
| 15 | 银灰 | `181_slver2` | ~40 条 |
| 16 | 史尔特尔 | `350_surtr` | ~30 条 |
| 17 | 玛恩纳 | `179_maam` | ~35 条 |
| 18 | 铃兰 | `377_bubble` | ~40 条 |
| 19 | 焰影苇草 | `378_asbesto` | ~25 条 |
| 20 | 令 | `222_ling` | ~35 条 |

另含 `_default` 通用台词兜底。

## 隐私说明

- **不截屏**：不使用屏幕录制 API
- **不联网**：所有数据本地处理
- **不记录**：屏幕上下文不会被保存
- **可关闭**：如果有隐私顾虑，可以在代码中注释掉 `ScreenWatcherService.shared.start()`
- **透明**：所有触发规则以 TOML 明文配置，用户可以查看和修改

## 技术细节

- 使用 `NSWorkspace.shared.frontmostApplication` 获取前台应用
- 使用 Accessibility API (`AXUIElementCopyAttributeValue`) 获取窗口标题
- 使用 `CGEventSource.secondsSinceLastEventType` 检测闲置时间
- 配置文件使用 TOML 格式，支持用户自定义扩展
- 台词好感度系统：好感度 ≥ 40 时解锁更亲密的台词
