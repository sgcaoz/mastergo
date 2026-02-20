#!/usr/bin/env bash
# 后台跑名局胜率，日志与临时文件在 tool/master_winrate_temp/
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
TEMPDIR="$ROOT/tool/master_winrate_temp"
mkdir -p "$TEMPDIR"
LOG="$TEMPDIR/batch.log"
CONSOLE="$TEMPDIR/console.log"
echo "日志文件（每步一条）: $LOG"
echo "控制台输出: $CONSOLE"
echo "临时目录（每局一个 {gameId}.json）: $TEMPDIR"
echo "启动后台任务..."
nohup dart run tool/run_master_winrate_batch.dart >> "$CONSOLE" 2>&1 &
echo "PID: $!"
echo "查看进度: tail -f $LOG"
