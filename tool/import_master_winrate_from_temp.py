#!/usr/bin/env python3
# 将 tool/master_winrate_temp/ 下已跑过的名局胜率 JSON 写回 seed 库。
# 运行：python3 tool/import_master_winrate_from_temp.py（项目根目录）
import json
import os
import sqlite3
import sys

def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    temp_dir = os.path.join(root, "tool", "master_winrate_temp")
    seed_path = os.path.join(root, "assets", "master_games", "mastergo_seed.db")

    if not os.path.isdir(temp_dir):
        print(f"ERROR: temp dir not found: {temp_dir}")
        sys.exit(1)
    if not os.path.isfile(seed_path):
        print(f"ERROR: seed DB not found: {seed_path}")
        sys.exit(1)

    conn = sqlite3.connect(seed_path)
    now_ms = int(__import__("time").time() * 1000)
    updated = 0

    for name in sorted(os.listdir(temp_dir)):
        if not name.startswith("master-") or not name.endswith(".json"):
            continue
        game_id = name[:-5]
        path = os.path.join(temp_dir, name)
        try:
            with open(path) as f:
                data = json.load(f)
        except Exception as e:
            print(f"Skip {game_id}: {e}")
            continue
        if not data:
            print(f"Skip {game_id}: empty")
            continue
        winrate_json = json.dumps(data, separators=(",", ":"))
        try:
            cur = conn.execute(
                "UPDATE game_records SET winrateJson = ?, updatedAtMs = ? WHERE id = ?",
                (winrate_json, now_ms, game_id),
            )
            if cur.rowcount > 0:
                print(f"OK {game_id} ({len(data)} turns)")
                updated += 1
        except Exception as e:
            print(f"Skip {game_id}: {e}")

    conn.commit()
    conn.close()
    print("")
    print(f"Done: {updated} updated. Seed: {seed_path}")

if __name__ == "__main__":
    main()
