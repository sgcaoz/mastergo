#!/usr/bin/env bash
# 后台跑名局每步胜率。按每盘自己的规则/贴目，古谱走 classical（贴目 0）。
# 中断后再次执行本脚本即可续跑。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
TEMPDIR="$ROOT/tool/master_winrate_temp"
mkdir -p "$TEMPDIR"
LOG="$TEMPDIR/batch.log"
CONSOLE="$TEMPDIR/console.log"
PIDFILE="$TEMPDIR/batch.pid"

if [[ -f "$PIDFILE" ]]; then
  oldpid="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [[ -n "${oldpid}" ]] && kill -0 "$oldpid" 2>/dev/null; then
    echo "已在跑 PID $oldpid"
    echo "进度: tail -f $LOG"
    echo "状态: cat $TEMPDIR/status.json"
    exit 0
  fi
fi

echo "日志: $LOG"
echo "控制台: $CONSOLE"
echo "进度: $TEMPDIR/progress.json"
echo "启动后台任务..."
# 独立会话，避免 Cursor/agent 退出把批次一起带走。
nohup dart run tool/run_master_winrate_batch.dart >> "$CONSOLE" 2>&1 &
launcher_pid=$!
disown "$launcher_pid" 2>/dev/null || true
echo "PID: $launcher_pid"
echo "查看进度: tail -f $LOG"
echo "当前盘: cat $TEMPDIR/status.json"
