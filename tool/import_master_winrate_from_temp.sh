#!/usr/bin/env bash
# 将 tool/master_winrate_temp/ 下已跑过的名局胜率 JSON 写回 seed 库。
# 运行：bash tool/import_master_winrate_from_temp.sh（项目根目录）
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$ROOT/tool/master_winrate_temp"
SEED="$ROOT/assets/master_games/mastergo_seed.db"
UPDATED=0
NOW=$(($(date +%s) * 1000))

if [ ! -d "$TEMP" ]; then
  echo "ERROR: temp dir not found: $TEMP"
  exit 1
fi
if [ ! -f "$SEED" ]; then
  echo "ERROR: seed DB not found: $SEED"
  exit 1
fi

for f in "$TEMP"/master-*.json; do
  [ -f "$f" ] || continue
  id=$(basename "$f" .json)
  # 跳过空或无效 JSON（用 python3 校验并输出紧凑 JSON，避免 shell 转义）
  json=$(python3 -c "
import json, sys
try:
    with open('$f') as fp:
        d = json.load(fp)
    if not d:
        sys.exit(1)
    print(json.dumps(d, separators=(',', ':')))
except Exception:
    sys.exit(1)
" 2>/dev/null) || continue
  # sqlite3 用单引号包裹时，需把字符串内单引号写成 ''
  escaped=$(echo "$json" | sed "s/'/''/g")
  sqlite3 "$SEED" "UPDATE game_records SET winrateJson = '$escaped', updatedAtMs = $NOW WHERE id = '$id';"
  if [ $? -eq 0 ]; then
    echo "OK $id"
    ((UPDATED++)) || true
  fi
done

echo ""
echo "Done: $UPDATED updated. Seed: $SEED"
