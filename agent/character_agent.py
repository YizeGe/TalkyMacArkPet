#!/usr/bin/env python3
"""MacArkPet — 角色数据智能体 (模板填充引擎)

给定角色名 → 爬取 prts.wiki → 填入标准 JSON 模板 → 输出 CharacterProfiles + Dialogues
"""

import re, json, os, sys, random as _r
from prts_crawler import crawl_character

# ──────────────────────────────────────────────
# 性格 ↔ 语气风格映射
# ──────────────────────────────────────────────
_STYLE_MAP = {
    "温柔": {"prefix": ["", "嗯…", "呵…"], "end": ["", "呢", "哦", "呀"]},
    "冷漠": {"prefix": ["", "哼", "..."], "end": ["", "啊", "..."]},
    "热情": {"prefix": ["", "哈哈！", "哦！"], "end": ["！", "！", "呢！"]},
    "调皮": {"prefix": ["嘿嘿，", "嘻嘻，", "哦？"], "end": ["呢", "啦", "哦"]},
    "傲慢": {"prefix": ["哼，", "哈，"], "end": ["啊。", "罢了。"]},
    "神秘": {"prefix": ["……", "呵，", "嗯……"], "end": ["……", "吗……"]},
    "忠诚": {"prefix": ["是，", "好的，"], "end": ["！", "！"]},
    "理性": {"prefix": ["嗯，", "看来"], "end": ["吧。", "。"]},
}

_DIALOGUE_KEYS = [
    # ---- 屏幕内容感知 ----
    "coding", "developing", "watching_video", "social", "chatting",
    "reading_news", "shopping", "gaming", "working", "email",
    "designing", "writing", "ai_chat", "studying", "browsing", "devops",
    # ---- 行为感知 ----
    "deep_night", "idle_long", "work_overload", "app_switching",
    # ---- 互动 ----
    "interact", "rest", "sleep", "special", "feed", "low_battery", "long_screen_time",
    "welcome", "farewell", "greeting",
    # ---- 每日 ----
    "daily",
    # ---- 带好感度前缀 ----
    "affection_interact", "affection_rest", "affection_sleep", "affection_special", "affection_feed", "affection_low_battery",
    "affection_coding", "affection_watching_video", "affection_social", "affection_chatting", "affection_gaming", "affection_working"
]

_BRANCH_CLASS = {
    "伏击客":"特种","傀儡师":"特种","处决者":"特种","巡空者":"特种","怪杰":"特种",
    "推击手":"特种","炼金师":"特种","行商":"特种","钩索师":"特种","陷阱师":"特种",
    "冲锋手":"先锋","尖兵":"先锋","情报官":"先锋","战术家":"先锋","执旗手":"先锋","策士":"先锋",
    "佣兵":"近卫","剑豪":"近卫","强攻手":"近卫","撼地者":"近卫","术战者":"近卫",
    "领主":"近卫","无畏者":"近卫","斗士":"近卫","教官":"近卫","收割者":"近卫","解放者":"近卫","重剑手":"近卫",
    "不屈者":"重装","决战者":"重装","哨戒铁卫":"重装","守护者":"重装","铁卫":"重装",
    "回环射手":"狙击","投掷手":"狙击","攻城手":"狙击","炮手":"狙击",
    "速射手":"狙击","重射手":"狙击","神射手":"狙击","散射手":"狙击",
    "中坚术师":"术师","塑灵术师":"术师","扩散术师":"术师","秘术师":"术师",
    "轰击术师":"术师","链术师":"术师","阵法术师":"术师","驭械术师":"术师",
    "医师":"医疗","咒愈师":"医疗","守望者":"医疗","疗养师":"医疗","群愈师":"医疗",
    "凝滞师":"辅助","削弱者":"辅助","召唤师":"辅助","吟游者":"辅助","工匠":"辅助","工笔":"辅助",
}

_GENDER_PRONOUN = {"男": "他", "女": "她"}


# ── 工具函数 ──

def _style_text(text: str, personality: str) -> str:
    """根据性格给台词加上语气风格（仅50%概率，且加得很轻）"""
    if _r.random() < 0.5:
        return text  # 一半概率原文
    # 末尾已有标点或语气词时，不再追加后缀
    _END_PARTICLES = set("呢哦呀啊啦吧嘛哈嗯吗……？！!?。，")
    text_stripped = text.rstrip()
    has_ending = text_stripped and text_stripped[-1] in _END_PARTICLES
    for trait, style in _STYLE_MAP.items():
        if trait in personality:
            choice = _r.random()
            if choice < 0.3 and style["prefix"]:
                prefix = _r.choice(style["prefix"])
                if prefix:
                    return prefix + text[0].lower() + text[1:] if len(text) > 1 else prefix + text
                return text
            elif choice < 0.6 and style["end"] and not has_ending:
                return text + _r.choice(style["end"])
            else:
                return text
    return text

def generate_char_id(name: str, codename: str) -> str:
    return name


# ── 文本合成 ──

def summarize_personality(archive_texts: list, voice_lines: list, gender: str) -> str:
    texts = [a["text"] for a in archive_texts if a["section"] != "临床诊断分析"]
    full = " ".join(texts)
    traits = []
    keywords = {
        "温柔": ["温柔", "体贴", "和善", "善良", "友好"],
        "冷漠": ["冷漠", "冷淡", "疏离", "冰冷", "冷酷"],
        "热情": ["热情", "开朗", "活泼", "大方", "外向"],
        "理性": ["理性", "冷静", "沉着", "谨慎", "理智"],
        "神秘": ["神秘", "莫测", "诡异", "暗"],
        "忠诚": ["忠诚", "忠实", "可靠", "坚定", "执着"],
        "调皮": ["调皮", "捣蛋", "捉弄", "爱玩", "贪玩"],
        "傲慢": ["傲慢", "自负", "自大", "骄傲"],
    }
    for trait, kws in keywords.items():
        for kw in kws:
            if kw in full:
                traits.append(trait)
                break
    if not traits:
        traits = ["神秘"]
    pronoun = _GENDER_PRONOUN.get(gender, "ta")
    desc = f"性格{'、'.join(traits[:3])}。{pronoun}有着独特的处事方式和世界观。"
    if voice_lines:
        lines_text = " ".join(v["text"] for v in voice_lines[:5])
        if any(w in lines_text for w in ["哈哈", "呵", "呢", "哦"]):
            desc += "语气轻松自然。"
        elif any(w in lines_text for w in ["哼", "切", "喂"]):
            desc += "语气中带有疏离或不屑。"
        else:
            desc += "措辞得体、表达清晰。"
    return desc

def summarize_speech_style(voice_lines: list, personality: str) -> str:
    if not voice_lines:
        return "措辞得当，表达清晰。"
    lines_text = " ".join(v["text"] for v in voice_lines)
    style_parts = []
    if any(w in lines_text for w in ["……", "...", "——"]):
        style_parts.append("善用省略和停顿")
    if any(w in lines_text for w in ["！", "!!", "啦"]):
        style_parts.append("语气富有情感")
    if any(w in lines_text for w in ["呢", "吗", "吧", "哦"]):
        style_parts.append("语尾常用语气词")
    base = "、".join(style_parts) if style_parts else "措辞得当，表达清晰"
    if "温柔" in personality:
        return f"{base}，整体语气温和亲切。"
    if "傲慢" in personality:
        return f"{base}，言语中常带自信甚至自负。"
    return f"{base}。"

def summarize_attitude(voice_lines: list, archive_texts: list, gender: str) -> str:
    pronoun = _GENDER_PRONOUN.get(gender, "ta")
    if not voice_lines:
        return f"和博士保持着一定距离，但愿意配合工作。{pronoun}视博士为可靠的指挥官。"
    texts = " ".join(v["text"] for v in voice_lines)
    if "保护" in texts and ("博士" in texts):
        return f"对博士有很强的保护欲，愿意为博士付出。{pronoun}把博士视为重要的人。"
    if any(w in texts for w in ["信任", "喜欢", "在意", "在乎"]):
        return f"对博士抱有信任和好感。{pronoun}相信博士的判断，愿意与博士并肩作战。"
    if any(w in texts for w in ["危险", "小心", "当心"]):
        return f"关心博士的安全，会提醒博士注意危险。{pronoun}将博士视为需要守护的对象。"
    return f"对博士抱有基本的信任和尊重。{pronoun}将博士视为可靠的指挥官，愿意听从调度。"

def summarize_background(archive_texts: list, raw: dict, gender: str) -> str:
    """从档案资料合成背景故事摘要"""
    pronoun = _GENDER_PRONOUN.get(gender, "ta")
    origin = raw.get("origin", "未知")
    race = raw.get("race", "未知")

    story_parts = []
    for a in archive_texts:
        if a["section"].startswith("档案资料"):
            text = re.sub(r'^提升信赖至\d+%以查看', '', a["text"]).strip()
            if text:
                story_parts.append(text)

    res = f"{pronoun}出身于{origin}的{race}族。"
    if story_parts:
        res += "".join(story_parts)
    return res

def pick_signature_lines(voice_lines: list) -> list:
    if not voice_lines:
        return []
    priority = ["交谈1", "交谈2", "交谈3", "信赖提升后交谈1", "信赖提升后交谈2", "任命助理", "晋升后交谈1", "精英化晋升1", "编入队伍", "问候"]
    selected = []
    seen = set()
    for p in priority:
        for vl in voice_lines:
            if vl["situation"] == p and vl["text"] not in seen:
                selected.append(vl["text"])
                seen.add(vl["text"])
                break
    for vl in voice_lines:
        if vl["text"] not in seen and len(selected) < 5:
            selected.append(vl["text"])
            seen.add(vl["text"])
    return selected[:5]



# ── Dialogues 生成 ──

_DIALOGUE_TEMPLATES = {
    "interact": ["（打招呼）你好，有什么我可以帮忙的吗？", "（走近）需要我陪陪你吗？"],
    "rest": ["（找个角落坐下）稍微休息一下吧……", "（闭上眼睛）呼……有点困了。"],
    "sleep": ["（梦呓）嗯……呼……", "（轻声呢喃）好困……晚安……"],
    "special": ["（轻碰）注意休息哦。", "（微笑）一切都会好起来的。"],
    "feed": ["（开心）味道很不错，谢谢你！", "（品尝）哇，很好吃呢。"],
    "welcome": ["欢迎回来！辛苦了！"],
    "farewell": ["路上小心，早点回来哦！"],
    "greeting": ["你好，今天也是新的一天！"],
    
    # 屏幕/行为
    "coding": ["还在写代码吗？加油。", "这是什么程序？"],
    "developing": ["开发辛苦了。", "屏幕上的字好密啊。"],
    "watching_video": ["在看什么视频？", "看起来很有趣。"],
    "social": ["在看大家的动态吗？", "网上很热闹呢。"],
    "chatting": ["和谁聊天这么开心？", "代我向对方问好。"],
    "reading_news": ["有什么新消息吗？", "今天的世界也发生了不少事。"],
    "shopping": ["要买新东西了吗？", "这个看起来不错。"],
    "gaming": ["游戏好玩吗？", "让我看看你的操作！"],
    "working": ["工作辛苦了。", "要不要喝点水？"],
    "email": ["有新邮件哦。", "要处理一下吗？"],
    "designing": ["画得真好。", "很有艺术感呢。"],
    "writing": ["在写什么呢？", "文笔不错。"],
    "ai_chat": ["在和 AI 对话吗？", "人工智会有灵魂吗……"],
    "studying": ["学习很认真呢。", "我也来一起看。"],
    "browsing": ["随便逛逛也不错。", "网上的东西真多。"],
    "devops": ["在部署什么系统吗？", "要注意安全哦。"],
    "deep_night": ["夜深了，该休息了哦。", "怎么还不睡？"],
    "idle_long": ["怎么没动静了……？", "发呆了吗？"],
    "work_overload": ["别太累了，快休息！", "工作是做不完的，身体要紧。"],
    "app_switching": ["找什么东西吗？", "切来切去的。"],
    "low_battery": ["有点没电了……", "该充电了。"],
    "long_screen_time": ["看屏幕太久了，休息一下眼睛吧。"],
    "daily": ["早安博士，今天也要打起精神来哦！", "又是新的一天，有什么计划吗？", "（轻快地）今天天气不错，适合工作呢！"],

    "affection_interact": ["（靠在身边）只要在你身边，就会觉得很安心呢。", "（微笑）能一直这样看着你就好了。"],
    "affection_rest": ["（依偎）稍微借你的肩膀靠一下哦……", "（安心）有你在旁边，感觉特别放松。"],
    "affection_sleep": ["（梦呓）博士……不要走……", "（握住你的手）嗯……安心……"],
    "affection_special": ["我会一直在这里陪着你的，放心吧。", "能遇见你，是我最幸运的事。"],
}

def generate_dialogues(name: str, char_id: str, personality: str, voice_lines: list) -> dict:
    """生成对话 — 优先用语音台词，不足用模板"""
    vl_map = {v["situation"]: v["text"] for v in voice_lines}
    dialogues = {}

    # 从语音台词中获取可用对话
    vl_mapping = {
        "interact": ["任命助理", "交谈1", "交谈2", "交谈3"],
        "rest": ["闲置"],
        "welcome": ["干员报到"],
        "farewell": ["行动出发"],
        "greeting": ["问候"],
        "special": ["戳一下", "信赖触摸"],
    }

    used = set()
    for dk, sit_list in vl_mapping.items():
        entries = []
        for sit in sit_list:
            if sit in vl_map:
                entries.append({
                    "lines": [vl_map[sit]],
                    "minAffection": 40 if dk.startswith("affection_") else 0,
                    "cooldown": 60 if dk.startswith("affection_") else 30,
                })
                used.add(sit)
        if entries:
            dialogues[dk] = entries

    # 补全缺失的情境
    for key in _DIALOGUE_KEYS:
        if key not in dialogues or not dialogues[key]:
            templates = _DIALOGUE_TEMPLATES.get(key, ["在旁边。"])
            dialogues[key] = [
                {"lines": [t.format(name=name) if '{' in t else t],
                 "minAffection": 40 if key.startswith("affection_") else 0,
                 "cooldown": 60 if key.startswith("affection_") else 30}
                for t in templates
            ]
    return dialogues


# ═══════════════════════════════════════════════
# AI 润色（可选）
# 通过环境变量 AI_API_KEY 或 config 文件配置
# ═══════════════════════════════════════════════

_AI_CONFIG = None

def _load_ai_config() -> dict:
    """加载 AI 配置，优先级：环境变量 > config.json"""
    global _AI_CONFIG
    if _AI_CONFIG is not None:
        return _AI_CONFIG

    api_key = os.environ.get("AI_API_KEY", "")
    api_base = os.environ.get("AI_API_BASE", "https://api.deepseek.com")
    model = os.environ.get("AI_MODEL", "deepseek-chat")

    # 尝试从 config 文件读取
    config_paths = [
        os.path.expanduser("~/.config/macarkpet/ai.json"),
        os.path.join(os.path.dirname(__file__), "ai_config.json"),
        os.path.join(os.path.dirname(__file__), "config.json"),
    ]
    for cp in config_paths:
        if os.path.exists(cp):
            try:
                with open(cp, "r", encoding="utf-8") as f:
                    cfg = json.load(f)
                    api_key = cfg.get("api_key", api_key)
                    api_base = cfg.get("api_base", api_base)
                    model = cfg.get("model", model)
            except:
                pass

    _AI_CONFIG = {
        "api_key": api_key,
        "api_base": api_base.rstrip("/"),
        "model": model,
    }
    return _AI_CONFIG


def _call_llm(system_prompt: str, user_prompt: str) -> str | None:
    """调用 LLM API，返回文本或 None"""
    cfg = _load_ai_config()
    if not cfg["api_key"]:
        return None

    try:
        import urllib.request
        import json as _json

        url = cfg["api_base"] + "/chat/completions"
        payload = _json.dumps({
            "model": cfg["model"],
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_prompt},
            ],
            "temperature": 0.7,
            "max_tokens": 4096,
            "response_format": {"type": "json_object"},
        }).encode("utf-8")

        req = urllib.request.Request(
            url, data=payload,
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Bearer {cfg['api_key']}",
            },
            method="POST",
        )

        with urllib.request.urlopen(req, timeout=60) as resp:
            result = _json.loads(resp.read().decode("utf-8"))
            return result["choices"][0]["message"]["content"]
    except Exception as e:
        print(f"[AI] LLM 调用失败: {e}", file=sys.stderr)
        return None


def ai_refine_character(raw: dict, profile: dict, dialogues: dict) -> tuple[dict, dict]:
    """
    用 AI 润色角色设定和台词。
    如果未配置 API key，直接返回原数据。
    """
    cfg = _load_ai_config()
    if not cfg["api_key"]:
        print("[AI] 未配置 AI_API_KEY，跳过 AI 润色", file=sys.stderr)
        return profile, dialogues

    name = profile.get("name", "?")
    print(f"[AI] 正在用 {cfg['model']} 润色角色「{name}」...", file=sys.stderr)

    # ── 构造爬虫原始数据摘要 ──
    codename = raw.get("codename", name)
    origin = raw.get("origin", "未知")
    race = raw.get("race", "未知")
    gender = raw.get("gender", "未知")
    class_label = raw.get("classLabel", "未知")
    faction = raw.get("faction", "")

    archive_summary = ""
    for a in raw.get("archive_texts", []):
        if a["section"].startswith("档案资料"):
            text = re.sub(r'^提升信赖至\d+%以查看', '', a["text"]).strip()
            archive_summary += text[:500] + "\n\n"

    voice_summary = ""
    for v in raw.get("voice_lines", [])[:15]:
        voice_summary += f"[{v['situation']}] {v['text']}\n"

    # ── 系统提示词 ──
    system_prompt = """你是 MacArkPet（macOS 桌面宠物应用）的 AI 角色编剧助手。
你的任务是根据《明日方舟》角色的原始档案和语音台词，生成高质量的角色设定数据。

请严格按照 JSON 格式输出，只输出 JSON，不要包含其他文字。
JSON 结构如下：
{
  "personality": "性格描述，150-250字",
  "speechStyle": "语言风格描述，50-150字",
  "attitudeTowardsDoctor": "对博士的态度，100-200字",
  "backgroundSummary": "背景故事摘要，200-300字",
  "signatureLines": ["经典台词1", "经典台词2", ...],  // 3-5条，直接用游戏原文
  "dialogues": {
    // ---- 屏幕内容感知（每组2-3行台词） ----
    "coding": [{"lines": ["博士写代码好专注啊...", "要不要我帮你盯着终端输出？"], "minAffection": 0, "cooldown": 60}],
    "developing": [{"lines": ["这是IDE界面吧？", "看起来是个大工程呢。"], "minAffection": 0, "cooldown": 60}],
    "watching_video": [{"lines": ["屏幕里的画面很有趣呢。", "让我也看看嘛。"], "minAffection": 0, "cooldown": 60}],
    "social": [{"lines": ["网络上很热闹呢。", "博士也在冲浪吗？"], "minAffection": 0, "cooldown": 60}],
    "chatting": [{"lines": ["在和谁聊天呀？", "看起来聊得很开心呢。"], "minAffection": 0, "cooldown": 60}],
    "reading_news": [{"lines": ["今天有什么大新闻吗？", "给我也讲讲嘛。"], "minAffection": 0, "cooldown": 60}],
    "shopping": [{"lines": ["又要买东西了？", "这次买了什么呢？"], "minAffection": 0, "cooldown": 60}],
    "gaming": [{"lines": ["让我看看博士怎么玩的。", "操作不错嘛！"], "minAffection": 0, "cooldown": 60}],
    "working": [{"lines": ["别太累了，注意休息。", "我去给你倒杯水。"], "minAffection": 0, "cooldown": 60}],
    "email": [{"lines": ["有新邮件哦。", "看看谁发来的？"], "minAffection": 0, "cooldown": 60}],
    "designing": [{"lines": ["画得真好。", "很有艺术感呢。"], "minAffection": 0, "cooldown": 60}],
    "writing": [{"lines": ["在写什么长篇大论吗？", "让我也拜读一下。"], "minAffection": 0, "cooldown": 60}],
    "ai_chat": [{"lines": ["你在和人工智能对话？", "它和我谁更懂你呢？"], "minAffection": 0, "cooldown": 60}],
    "studying": [{"lines": ["好认真啊，我也来陪你。", "我们一起学习进步。"], "minAffection": 0, "cooldown": 60}],
    "browsing": [{"lines": ["在网上随便逛逛？", "看到什么有趣的了？"], "minAffection": 0, "cooldown": 60}],
    "devops": [{"lines": ["在部署服务吗？小心操作哦。", "我会替你加油的！"], "minAffection": 0, "cooldown": 60}],
    
    // ---- 行为感知（每组2-3行台词） ----
    "deep_night": [{"lines": ["夜深了，博士，该休息了。", "熬夜对身体不好的。"], "minAffection": 0, "cooldown": 120}],
    "idle_long": [{"lines": ["博士？睡着了吗...？", "那我就这样安静地陪着你吧。"], "minAffection": 0, "cooldown": 120}],
    "work_overload": [{"lines": ["你工作太久了，快停下！", "我来监督你休息！"], "minAffection": 0, "cooldown": 120}],
    "app_switching": [{"lines": ["切来切去的，找不到东西了吗？", "需要我帮忙吗？"], "minAffection": 0, "cooldown": 60}],

    // ---- 互动（每组2-3行台词） ----
    "interact": [{"lines": ["你好！", "今天有什么想和我聊的吗？"], "minAffection": 0, "cooldown": 30}],
    "rest": [{"lines": ["休息一下吧。", "我陪你一起歇会儿。"], "minAffection": 0, "cooldown": 60}],
    "sleep": [{"lines": ["晚安...", "做个好梦。"], "minAffection": 0, "cooldown": 60}],
    "special": [{"lines": ["嗯？怎么了？", "有什么事吗？"], "minAffection": 0, "cooldown": 60}],
    "feed": [{"lines": ["好吃的！", "谢谢博士投喂！"], "minAffection": 0, "cooldown": 60}],
    "low_battery": [{"lines": ["该充电了。"], "minAffection": 0, "cooldown": 60}],
    "long_screen_time": [{"lines": ["盯着屏幕太久了。"], "minAffection": 0, "cooldown": 60}],
    "welcome": [{"lines": ["欢迎回来！"], "minAffection": 0, "cooldown": 30}],
    "farewell": [{"lines": ["路上小心！"], "minAffection": 0, "cooldown": 30}],
    "greeting": [{"lines": ["今天也是新的一天。"], "minAffection": 0, "cooldown": 30}],

    // ---- 对应的高好感度变体 (minAffection 设为 60) ----
    "affection_interact": [{"lines": ["只要在你身边，就会觉得很安心呢。"], "minAffection": 60, "cooldown": 60}],
    "affection_rest": [{"lines": ["稍微借你的肩膀靠一下哦……"], "minAffection": 60, "cooldown": 60}],
    "affection_sleep": [{"lines": ["博士……不要走……"], "minAffection": 60, "cooldown": 60}],
    "affection_special": [{"lines": ["我会一直在这里陪着你的，放心吧。"], "minAffection": 60, "cooldown": 60}],
    "affection_feed": [{"lines": ["只要是你给的，我都喜欢。"], "minAffection": 60, "cooldown": 60}],
    "affection_low_battery": [{"lines": ["我有点困了……可以靠着你充电吗？"], "minAffection": 60, "cooldown": 60}],
    "affection_coding": [{"lines": ["写代码的样子也很迷人呢。"], "minAffection": 60, "cooldown": 60}],
    "affection_watching_video": [{"lines": ["可以和你一起看吗？靠得再近一点……"], "minAffection": 60, "cooldown": 60}],
    "affection_social": [{"lines": ["我的眼里只有你，你也在看着我吗？"], "minAffection": 60, "cooldown": 60}],
    "affection_chatting": [{"lines": ["不要和其他人聊太久啦，多陪陪我嘛。"], "minAffection": 60, "cooldown": 60}],
    "affection_gaming": [{"lines": ["无论输赢，我都在你身边。"], "minAffection": 60, "cooldown": 60}],
    "affection_working": [{"lines": ["辛苦了，等下奖励你一个拥抱哦。"], "minAffection": 60, "cooldown": 60}]
  }
}

要求：
- 【严格禁止】以上 JSON 示例中的台词（如“只要在你身边，就会觉得很安心呢。”等）仅作结构参考，绝不允许直接原样复制！你必须为你正在处理的特定角色重新创作所有台词！
- personality 要能体现角色的性格关键词（温柔/冷漠/热情/理性/神秘等）
- dialogues 必须是角色实际“说出口的话”，绝不能只有动作描写（如“信任地依偎着你”是绝对禁止的）。如果是动作，必须配合角色的特定口语台词，例如“（轻轻靠在你肩上）博士，稍微休息一下吧……”。
- dialogues 优先使用游戏原文语音台词（特别是信赖提升后的交谈1、2、3等）进行改写，每条 10-40 字，必须高度贴合角色性格。
- 对于 `affection_*` 开头的高好感度台词，必须结合该角色对博士的深层态度（如傲娇、崇拜、平起平坐、默默守护等）来设计，绝不要使用千篇一律的废话。
- 保持角色原有的语气特点和口语习惯
- 用中文输出"""

    # ── 用户提示词：角色数据 ──
    user_prompt = f"""请为以下《明日方舟》角色生成完整的角色设定：

角色名: {name}
代号: {codename}
性别: {gender}
种族: {race}
出身地: {origin}
职业: {class_label}
阵营: {faction}

=== 档案资料摘要 ===
{archive_summary[:2000]}

=== 语音台词 (部分) ===
{voice_summary[:2000]}

=== 当前(粗糙)角色设定供参考 ===
性格: {profile.get('personality', '')[:200]}
语言风格: {profile.get('speechStyle', '')[:200]}
对博士态度: {profile.get('attitudeTowardsDoctor', '')[:200]}
背景: {profile.get('backgroundSummary', '')[:200]}
"""

    result = _call_llm(system_prompt, user_prompt)
    if not result:
        print("[AI] LLM 返回为空，使用原始数据", file=sys.stderr)
        return profile, dialogues

    # 解析 JSON
    try:
        # 尝试直接提取 JSON 对象
        start = result.find('{')
        end = result.rfind('}') + 1
        if start >= 0 and end > start:
            json_str = result[start:end]
        else:
            print("[AI] 输出中未找到 JSON，使用原始数据", file=sys.stderr)
            return profile, dialogues

        refined = json.loads(json_str)
    except Exception as e:
        print(f"[AI] JSON 解析失败: {e}", file=sys.stderr)
        print(f"[AI] 原始输出:\n{result[:500]}", file=sys.stderr)
        return profile, dialogues

    # 合并回 profile
    for key in ["personality", "speechStyle", "attitudeTowardsDoctor", "backgroundSummary"]:
        if key in refined and refined[key]:
            profile[key] = refined[key]

    if "signatureLines" in refined and refined["signatureLines"]:
        profile["signatureLines"] = refined["signatureLines"]



    if "dialogues" in refined and refined["dialogues"]:
        # 合并 AI 生成的对话到现有对话中
        for sit, entries in refined["dialogues"].items():
            if entries:
                dialogues[sit] = entries

    print(f"[AI] ✅ 角色「{name}」润色完成", file=sys.stderr)
    return profile, dialogues


# ── 主入口 ──

def generate_character(name: str, use_ai: bool = True) -> dict:
    raw = crawl_character(name)
    if "error" in raw:
        return {"error": raw["error"]}

    codename = raw.get("codename", name)
    gender = raw.get("gender", "未知")
    char_id = generate_char_id(name, codename)
    personality = summarize_personality(raw.get("archive_texts", []), raw.get("voice_lines", []), gender)
    speech_style = summarize_speech_style(raw.get("voice_lines", []), personality)
    attitude = summarize_attitude(raw.get("voice_lines", []), raw.get("archive_texts", []), gender)
    background = summarize_background(raw.get("archive_texts", []), raw, gender)
    sig_lines = pick_signature_lines(raw.get("voice_lines", []))

    profile = {
        "id": char_id, "name": codename, "subtitle": name,
        "race": raw.get("race", ""), "origin": raw.get("origin", ""),
        "classLabel": raw.get("classLabel", ""), "faction": raw.get("faction", ""),
        "personality": personality,
        "speechStyle": speech_style,
        "attitudeTowardsDoctor": attitude,
        "backgroundSummary": background,
        "signatureLines": sig_lines,
        "birthday": raw.get("birthday", ""),
        "height": raw.get("height", ""),
        "infected": raw.get("infected", False),
    }

    dialogues = generate_dialogues(codename, char_id, personality, raw.get("voice_lines", []))

    # AI 润色
    if use_ai:
        profile, dialogues = ai_refine_character(raw, profile, dialogues)

    return {"profile": profile, "dialogues": dialogues}


def save_character(data: dict, profiles_path: str, dialogues_path: str) -> dict:
    char_id = data["profile"]["id"]
    profiles = {}
    if os.path.exists(profiles_path):
        with open(profiles_path, 'r', encoding='utf-8') as f:
            try: profiles = json.load(f)
            except: pass
    existing_dialogues = {}
    if os.path.exists(dialogues_path):
        with open(dialogues_path, 'r', encoding='utf-8') as f:
            try: existing_dialogues = json.load(f)
            except: pass
    profiles[char_id] = data["profile"]
    existing_dialogues[char_id] = data["dialogues"]
    with open(profiles_path, 'w', encoding='utf-8') as f:
        json.dump(profiles, f, ensure_ascii=False, indent=2)
    with open(dialogues_path, 'w', encoding='utf-8') as f:
        json.dump(existing_dialogues, f, ensure_ascii=False, indent=2)
    return {"success": True, "char_id": char_id, "name": data["profile"]["name"]}


if __name__ == "__main__":
    import sys
    args = sys.argv[1:]
    name = "水月"
    use_ai = True
    skip_ai_flag = "--no-ai"
    if skip_ai_flag in args:
        use_ai = False
        args.remove(skip_ai_flag)
    if args:
        name = args[0]
    data = generate_character(name, use_ai=use_ai)
    print(json.dumps(data, ensure_ascii=False, indent=2, default=str))
    if "profile" in data and "dialogues" in data:
        print(f"\n--- Dialogues: {len(data['dialogues'])} categories ({'AI refined' if use_ai else 'rule-based'}) ---", file=sys.stderr)
