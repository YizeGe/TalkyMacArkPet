#!/usr/view/env python3
import requests
import json
import os

HEADERS = {"User-Agent": "Mozilla/5.0"}

def fetch_all_operators():
    url = "https://prts.wiki/api.php"
    params = {
        "action": "query",
        "list": "categorymembers",
        "cmtitle": "Category:干员",
        "cmlimit": "500",
        "format": "json"
    }
    
    operators = []
    while True:
        r = requests.get(url, params=params, headers=HEADERS)
        data = r.json()
        
        for member in data.get("query", {}).get("categorymembers", []):
            title = member.get("title", "")
            # Filter out subcategories or non-operator pages
            if not ":" in title and not "干员" in title and not "页面" in title:
                operators.append(title)
                
        if "continue" in data:
            params["cmcontinue"] = data["continue"]["cmcontinue"]
        else:
            break
            
    # Filter known non-characters like "阿米娅(近卫)", we usually just use base name
    # PRTS sometimes uses "阿米娅(近卫)" as a separate page, we can exclude or include them
    final_ops = []
    for op in operators:
        # Ignore class specific versions or npc
        if "(" in op:
            continue
        final_ops.append(op)
        
    return final_ops

if __name__ == "__main__":
    ops = fetch_all_operators()
    print(f"Fetched {len(ops)} operators")
    out_path = os.path.join(os.path.dirname(__file__), "../Resources/AllOperatorsList.json")
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(ops, f, ensure_ascii=False, indent=2)
    print(f"Saved to {out_path}")
