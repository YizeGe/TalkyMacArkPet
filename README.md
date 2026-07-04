# TalkyMacArkPet

TalkyMacArkPet 是一款专为 macOS 设计的原生桌面宠物应用。它是 [MacArkPet](https://github.com/Wanduforl/MacArkPet) 的进阶衍生版本，基于原生 Swift / AppKit / SwiftUI 构建，不仅支持将《明日方舟》干员的 Spine 模型在桌面上进行透明渲染与物理交互，还创造性地引入了 **屏幕状态感知**、**AI 角色生成**、**CP 多角色剧本互动** 和 **Web 剧本编辑器** 等前沿功能，让你的桌面伴侣真正拥有“灵魂”。

## ✨ 核心特性 / Features

- **原生 macOS 体验与物理交互**
  - 基于 `WKWebView` 渲染 Spine/WebGL 模型，背景完全透明、无边框。
  - 支持左键拖拽、重力下落、触底反弹、支持在屏幕底部、Dock 栏以及活动窗口顶部站立。
  - 拥有完善的托盘菜单，支持事件穿透（点击穿透）、置顶显示和位置重置。
- **屏幕状态智能感知 (Screen Awareness)**
  - 能够智能分析当前 Mac 的活动窗口（如：正在写代码、看视频、浏览网页或是长时间挂机）。
  - 会根据你的屏幕状态（如“深夜”、“长时间挂机”）触发干员特定的台词和动作。
- **CP 多角色剧本联动 (Multi-Character Interaction)**
  - 支持同时在桌面上放置多个干员。
  - 内置 CP 对话引擎：当桌面上有特定组合（如：水月 + 海沫，拉普兰德 + 德克萨斯）时，干员之间会自动识别并触发精心编排的连续对话。
- **内置 Web 剧本编辑器 (Web Editor)**
  - 项目内置了一个轻量级本地 Web 服务器（访问 `http://localhost:19191` 即可进入）。
  - 提供可视化界面供你管理干员档案，甚至可以**自己编写或修改干员对话彩蛋**，定制干员对你的专属称呼。
- **AI 智能生成 (AI Agent Integration)**
  - 结合大语言模型与 PRTS 百科爬虫，全自动抓取干员资料并生成符合角色性格特征的“情境对话”。
  - 完全脱离手工录入的繁琐，角色库可无限扩展。

## ⚠️ 版权与免责声明 / Legal & Copyright

**本项目为纯爱好者用爱发电的非营利开源项目，不包含任何商业化元素。**

1. **素材归属**：本项目并不包含任何《明日方舟》的游戏素材或资源压缩包。应用运行时所下载和渲染的所有 Spine 模型资源及相关美术素材，其著作权与知识产权均属于 **上海鹰角网络科技有限公司 (Hypergryph)**。
2. **禁止商用**：请勿将本项目及通过本项目获取的任何游戏素材用于商业用途，或进行任何可能损害版权方利益的行为。如果您进行 Fork 或二次分发，请务必遵守版权方的相关二创规定。
3. **免责声明**：本项目属于非官方的粉丝自制项目，与鹰角网络 (Hypergryph)、悠星网络 (Yostar) 均无官方从属或合作关系。

## 🫡 致敬与感谢 / Acknowledgements

- **Hypergryph (鹰角网络)**：感谢鹰角网络创造了《明日方舟》这样一款充满魅力的游戏，以及塑造了如此多深入人心的干员形象。
- **[Ark-Pets (isHarryh)](https://github.com/isHarryh/Ark-Pets)**：感谢原作者开启了将罗德岛干员搬上桌面（Windows 平台）的浪漫尝试。
- **[MacArkPet (Wanduforl)](https://github.com/Wanduforl/MacArkPet)**：感谢 Wanduforl 在 Windows 版的基础上，成功将其移植到了 macOS 平台，为本作奠定了坚实的原生 Mac 基础框架。
- **PRTS Wiki**：感谢 PRTS 社区对《明日方舟》数据的悉心整理与维护，为本项目 AI 获取角色设定提供了重要的数据来源。
- 所有相关 Spine WebGL 运行时及相关开源库的贡献者。

## 🚀 安装与运行 / Installation

**📦 对于普通用户（推荐）**
最简单的方法是直接下载打包好的安装包，无需配置任何开发环境：
1. 前往本仓库的 [Releases 页面](https://github.com/geyize/TalkyMacArkPet/releases) 
2. 下载最新的 `MacArkPet-xxx-macOS.dmg` 文件
3. 双击打开 dmg 文件，将 `MacArkPet` 拖入 `Applications` (应用程序) 文件夹即可双击运行。

---

**🛠 对于开发者 (Build from Source)**

环境要求：
- macOS 13 (Ventura) 及以上版本
- Xcode Command Line Tools 或 Xcode (支持 Swift 5.9+)

**1. 源码编译与运行**
```bash
git clone https://github.com/geyize/TalkyMacArkPet.git
cd TalkyMacArkPet
./script/build_and_run.sh
```

**2. 打包为 Release 发行版 (DMG / ZIP)**
```bash
./script/package_release.sh
```
编译产物将生成在 `release/` 目录下。

## 📁 目录结构

```text
Sources/MacArkPet/     Swift 核心源码 (界面, 物理引擎, Web服务器, 对话引擎)
Resources/             Web前端资源, 静态配置与 Spine 运行时
agent/                 Python 端 AI 爬虫与剧本生成脚本
script/                构建与打包脚本
docs/                  说明文档
```

## 📜 许可证 / License

本项目源代码遵循 **GNU General Public License v3.0**。详细信息请参阅 [LICENSE](LICENSE) 文件。
请注意，开源协议仅适用于本项目源代码，**不授予** 您对运行时下载的第三方资源及官方游戏素材的任何权利。在重新分发或构建时，请务必阅读 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
