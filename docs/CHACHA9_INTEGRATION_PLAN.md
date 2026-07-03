# 🖥️ chacha9 × MacArkPet 集成计划书

> 撰写日期：2026-06-27
> 状态：规划中
> 适用范围：仅管理员可用（非公开功能）

---

## 一、总览

### 目标
在 chacha9 网站上增加一个**桌宠管理面板**（管理员专用），实现在线管理桌面宠物的台词库、角色数据和玩家统计。

### 原则
- **仅管理员可访问**（管理员 Key 鉴权）
- **MacArkPet 只读不写**（数据从 chacha9 拉取，不在桌面端编辑）
- **数据同步为手动触发**（不自动轮询，避免依赖问题）

---

## 二、功能范围

### 阶段一：台词在线管理（MVP）

```
chacha9 管理面板 → 修改台词 JSON → 保存到服务器
         ↓
MacArkPet 同步按钮 → 从 chacha9 下载最新台词
```

#### chacha9 端新增

| 项目 | 说明 |
|------|------|
| **管理页面** | `/admin/pet/voices` — 管理员专用页面 |
| **API** | `GET /admin/api/pet_voice_lines` — 返回完整 `CharacterVoiceLines.json` |
| **API** | `PUT /admin/api/pet_voice_lines` — 更新台词库（只接受管理员 Key） |
| **UI 表格** | 按角色展示所有台词，支持搜索、编辑、保存 |
| **鉴权** | 请求头带 `X-Admin-Key: ***`，与现有管理员接口一致 |

#### MacArkPet 端新增

| 项目 | 说明 |
|------|------|
| **设置项** | 新增 chacha9 服务器 URL + 管理员 Key 配置 |
| **同步按钮** | 右键菜单新增「同步台词」功能 |
| **同步逻辑** | GET → 校验 JSON → 覆盖本地 `CharacterVoiceLines.json` → 重新加载 |

#### 数据流

```
[管理员浏览器] → 编辑台词 → PUT /admin/api/pet_voice_lines
                                         ↓
                                    存储 JSON 到服务器
                                         ↓
[MacArkPet] → 同步按钮 → GET /admin/api/pet_voice_lines
                                         ↓
                                    覆盖本地 JSON → 语音服务重新加载
```

---

### 阶段二：宠物数据云端同步

在台词管理基础上，增加好感度/体力等养成数据的云端同步。

| 项目 | 说明 |
|------|------|
| **API** | `GET /admin/api/pet_stats?character_id=xxx` — 获取角色养成数据 |
| **API** | `PUT /admin/api/pet_stats` — 上传/合并养成数据 |
| **数据项** | `affection`, `energy`, `dailyStreak`, `lastInteractionDate` |
| **同步时机** | 退出应用时上传，启动时下拉（可选） |

#### 数据流

```
MacArkPet 退出 → PUT /admin/api/pet_stats {all_characters: {…}}
         ↓
chacha9 存储到数据库表 pet_stats
         ↓
MacArkPet 启动 → GET /admin/api/pet_stats → 合并到本地
```

---

### 阶段三：网页端控制桌宠（远期）

在管理面板上直接控制桌面宠物的行为。

| 项目 | 说明 |
|------|------|
| **远程动作** | 网页端点击「送一份礼物」→ API 触发桌宠显示喂食气泡 |
| **状态查看** | 网页端实时显示当前桌面好感度、在线状态 |
| **通知** | 网页端写留言 → 桌宠说话时显示 |

实现方式：MacArkPet 定时轮询 chacha9 的 `/admin/api/pet/notifications` 接口获取待办消息。

---

## 三、管理员页面 UI 示意

### `/admin/pet/voices` 台词管理页面

```
┌──────────────────────────────────────────┐
│  🔙 返回后台        桌宠台词管理           │
│                                            │
│  ┌──────────────────────────────────┐      │
│  │  搜索角色...              [筛选] │      │
│  └──────────────────────────────────┘      │
│                                            │
│  ┌────────┬──────┬──────────┬──────────┐   │
│  │ 角色    │ 类型 │ 台词 1    │ 台词 2   │   │
│  ├────────┼──────┼──────────┼──────────┤   │
│  │ 阿米娅  │ 互动 │ "早呀！"  │ "一起加  │   │
│  │        │      │          │ 油哦！"  │   │
│  │        ├──────┼──────────┼──────────┤   │
│  │        │ 休息 │ "休息一  │ ……       │   │
│  │        │      │ 下吧"    │          │   │
│  │        ├──────┼──────────┼──────────┤   │
│  │        │ 喂食 │ "好吃！" │ ……       │   │
│  ├────────┼──────┼──────────┼──────────┤   │
│  │ 余     │ 互动 │ "你来啦" │ "看我火" │   │
│  │        │      │ ！"      │ 苗！"    │   │
│  └────────┴──────┴──────────┴──────────┘   │
│                                            │
│              [💾 保存修改]                  │
└──────────────────────────────────────────┘
```

### 技术选型
- 前端：在 chacha9 现有 `templates` 或 `static/` 目录下加一个 HTML 页面
- 复用现有 `admin_key` 鉴权机制
- 页面对桌宠模型列表的获取：复用现有 `/list_characters` 接口

---

## 四、数据库变更

### 仅阶段二需要

```sql
CREATE TABLE IF NOT EXISTS pet_stats (
    id SERIAL PRIMARY KEY,
    character_id VARCHAR(64) NOT NULL,
    affection INTEGER DEFAULT 0,
    energy INTEGER DEFAULT 100,
    daily_streak INTEGER DEFAULT 0,
    last_interaction_date TIMESTAMP,
    last_energy_drain TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);
CREATE UNIQUE INDEX idx_pet_stats_char ON pet_stats(character_id);
```

### 阶段一不需要数据库变更（直接存 JSON 文件即可）

---

## 五、进度 & 里程碑

| 阶段 | 内容 | 预计工作量 |
|------|------|-----------|
| **P0** | 台词管理 API（GET + PUT） | 0.5 天 |
| **P0** | 管理员页面（增删改台词） | 1 天 |
| **P1** | MacArkPet 同步按钮 | 0.5 天 |
| **P2** | 宠物数据云端同步 | 1 天 |
| **P3** | 网页端远程控制（轮询通知） | 2+ 天 |

---

## 六、注意事项

1. **安全**：所有接口仅管理员可用，普通用户不能访问
2. **容错**：MacArkPet 同步失败时使用本地旧数据，不阻塞启动
3. **格式兼容**：台词 JSON 结构保持与当前 `CharacterVoiceLines.json` 一致
4. **离线可用**：桌宠的台词缓存一份本地 JSON，服务器挂掉不影响已有功能
