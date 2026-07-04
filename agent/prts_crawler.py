#!/usr/bin/env python3
"""MacArkPet — prts.wiki 角色数据爬虫"""

import re, json
import requests
from bs4 import BeautifulSoup

HEADERS = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
}
WIKI_BASE = "https://prts.wiki/w/"

SITUATION_KNOWN = [
    "任命助理","交谈1","交谈2","交谈3","信赖提升后交谈1","信赖提升后交谈2","信赖提升后交谈3",
    "精英化晋升1","精英化晋升2","晋升后交谈1","晋升后交谈2","编入队伍","任命队长",
    "行动出发","行动开始","选中干员1","选中干员2","选中干员3","部署1","部署2",
    "作战中1","作战中2","作战中3","作战中4","完成高难行动","3星结束","非3星结束",
    "行动失败","进驻设施","戳一下","信赖触摸","标题","问候","周年庆典",
]

BRANCH_CLASS = {
    "伏击客":"特种","傀儡师":"特种","处决者":"特种","巡空者":"特种",
    "怪杰":"特种","推击手":"特种","炼金师":"特种","行商":"特种",
    "钩索师":"特种","陷阱师":"特种",
    "冲锋手":"先锋","尖兵":"先锋","情报官":"先锋","战术家":"先锋",
    "执旗手":"先锋","策士":"先锋",
    "佣兵":"近卫","剑豪":"近卫","强攻手":"近卫","撼地者":"近卫",
    "术战者":"近卫","领主":"近卫","无畏者":"近卫","斗士":"近卫",
    "教官":"近卫","收割者":"近卫","解放者":"近卫","重剑手":"近卫",
    "不屈者":"重装","决战者":"重装","哨戒铁卫":"重装","守护者":"重装","铁卫":"重装",
    "回环射手":"狙击","投掷手":"狙击","攻城手":"狙击","炮手":"狙击",
    "速射手":"狙击","重射手":"狙击","神射手":"狙击","散射手":"狙击",
    "中坚术师":"术师","塑灵术师":"术师","扩散术师":"术师","秘术师":"术师",
    "轰击术师":"术师","链术师":"术师","阵法术师":"术师","驭械术师":"术师",
    "医师":"医疗","咒愈师":"医疗","守望者":"医疗","疗养师":"医疗","群愈师":"医疗",
    "凝滞师":"辅助","削弱者":"辅助","召唤师":"辅助","吟游者":"辅助","工匠":"辅助","工笔":"辅助",
}

def _soup(path: str) -> BeautifulSoup | None:
    try:
        r = requests.get(WIKI_BASE + path, headers=HEADERS, timeout=15)
        r.encoding = "utf-8"
        if r.status_code == 200:
            return BeautifulSoup(r.text, "html.parser"), None
        else:
            return None, f"HTTP {r.status_code}"
    except Exception as e:
        import sys
        print(f"[Error in _soup] {e}", file=sys.stderr)
        with open("/tmp/prts_error.log", "a") as f:
            f.write(f"Error for {path}: {e}\n")
        return None, str(e)

def crawl_character(name: str) -> dict:
    encoded = requests.utils.quote(name)
    soup, err_msg = _soup(encoded)
    if not soup:
        return {"error": f"无法访问 prts.wiki: {name} (原因: {err_msg})"}

    result = {
        "name": name,
        "codename": "", "gender": "", "origin": "", "birthday": "",
        "race": "", "height": "", "infected": False, "classLabel": "",
        "branch": "", "faction": "",
        "archive_texts": [], "voice_lines": [],
    }

    # ── 干员档案 section ──
    for table in soup.find_all("table", class_="wikitable"):
        text = table.get_text("\n", strip=True)
        if "人员档案" not in text:
            continue
        body = table.find("div", class_="mw-collapsible-content") or table
        full = body.get_text("\n", strip=True)

        for pat, key in [
            (r"【代号】(.+?)(?:\n|$)", "codename"),
            (r"【性别】(.+?)(?:\n|$)", "gender"),
            (r"【出身地】(.+?)(?:\n|$)", "origin"),
            (r"【生日】(.+?)(?:\n|$)", "birthday"),
            (r"【种族】(.+?)(?:\n|$)", "race"),
            (r"【身高】(.+?)(?:\n|$)", "height"),
            (r"【矿石病感染情况】\s*(.+?)(?:\n|$)", "_infected_raw"),
        ]:
            m = re.search(pat, full)
            if m:
                result[key] = m.group(1).strip()
        _ir = result.pop("_infected_raw", "")
        result["infected"] = bool(_ir and "非感染" not in _ir and "未感染" not in _ir)

        # 档案资料段落
        lines = full.split("\n")
        cur_sec, cur_txt = None, []
        for line in lines:
            line = line.strip()
            if not line: continue
            if re.match(r"^(档案资料|晋升记录|临床诊断分析)", line):
                if cur_sec:
                    result["archive_texts"].append({"section": cur_sec, "text": "".join(cur_txt)})
                cur_sec, cur_txt = line, []
            elif cur_sec:
                cur_txt.append(line)
        if cur_sec and cur_txt:
            result["archive_texts"].append({"section": cur_sec, "text": "".join(cur_txt)})
        break

    # ── 职业分支（表格含"分支"二字） ──
    branch_table = soup.find(lambda t: t.name == "table" and "分支" in (t.get_text()[:50] or ""))
    if branch_table:
        for row in branch_table.find_all("tr"):
            cells = row.find_all(["td", "th"])
            if len(cells) >= 2:
                v = cells[0].get_text(strip=True)
                if v and v not in ("分支", "描述") and len(v) < 10:
                    result["branch"] = v
                    break

    # 分支 → 职业大类
    if result["branch"]:
        result["classLabel"] = BRANCH_CLASS.get(result["branch"], "")

    # ── 阵营（从属性表） ──
    for tbl in soup.find_all("table", class_="wikitable"):
        txt = tbl.get_text()
        if "所属势力" not in txt:
            continue
        lines = txt.split("\n")
        # 找到"所属势力" → 取它后面的非空行（排"东"这个显示名）
        for i, l in enumerate(lines):
            if l.strip() == "所属势力":
                for j in range(i+1, min(i+8, len(lines))):
                    c = lines[j].strip()
                    if c and c != "所属势力" and len(c) < 15:
                        # 跳过"东"（仅显示名），跳过"隐藏势力..."
                        if c in ("东", ""):
                            continue
                        if "隐藏" in c or "仅在战斗" in c:
                            continue
                        result["faction"] = c
                        break
                # 如果还没找到，可能就是"东"后面那个
                if not result["faction"]:
                    for j in range(i+1, min(i+8, len(lines))):
                        c = lines[j].strip()
                        if c and c != "所属势力" and len(c) < 15 and "隐藏" not in c and "仅在战斗" not in c:
                            result["faction"] = c
                            break
                break
        break

    # ── 语音台词 ──
    vr_soup, _ = _soup(f"{encoded}/语音记录")
    if vr_soup:
        for vdiv in vr_soup.find_all("div", class_="voice-data-item"):
            sit = vdiv.get("data-title", "").strip()
            if not sit:
                continue
            # 精确选择 data-kind-name="中文" 的子 div，不再用 regex 切分多语言
            cn_div = vdiv.find("div", {"data-kind-name": "中文"})
            if not cn_div:
                continue
            
            # 🐛 修复语言截断问题：移除 PRTS Wiki 可能含有的外语注音 <rt>, <rp> 以及外语 <span>
            for tag in cn_div.find_all(["rt", "rp"]):
                tag.decompose()
            for span in cn_div.find_all("span", class_=lambda c: c and "exlang" in c):
                span.decompose()

            cn = cn_div.get_text(strip=True)
            if cn and len(cn) > 1:
                result["voice_lines"].append({"situation": sit, "text": cn})

    return result

if __name__ == "__main__":
    import sys
    name = sys.argv[1] if len(sys.argv) > 1 else "水月"
    data = crawl_character(name)
    print(json.dumps(data, ensure_ascii=False, indent=2, default=str))
