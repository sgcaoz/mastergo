import 'package:flutter/material.dart';
import 'package:mastergo/domain/go/go_game.dart';
import 'package:mastergo/domain/go/go_types.dart';
import 'package:mastergo/features/common/go_board_widget.dart';
import 'package:mastergo/infra/engine/katago/katago_adapter.dart';

/// 复盘/打谱共用：展示局势分析结果（势力图 + 目数估算 + 胜率）。
void showOwnershipResultSheet(
  BuildContext context,
  GoGameState state,
  KatagoAnalyzeResult res, {
  int? boardSize,
}) {
  final int size = boardSize ?? state.boardSize;
  final List<double>? ownership = res.ownership;
  final double scoreLead = res.scoreLead;
  final double blackWr = res.winrate;
  final GoPoint? lastPoint =
      state.moves.isNotEmpty ? state.moves.last.point : null;
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (BuildContext ctx) {
      final String leadText = scoreLead >= 0
          ? '黑领先约 ${scoreLead.toStringAsFixed(1)} 目'
          : '白领先约 ${(-scoreLead).toStringAsFixed(1)} 目';
      return Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(ctx).viewPadding.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text(
                '局势分析（势力与目数估算）',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 16,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '目数估算：$leadText',
              style: const TextStyle(fontSize: 14),
            ),
            Text(
              '胜率：黑 ${(blackWr * 100).toStringAsFixed(1)}%',
              style: const TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 360,
              child: GoBoardWidget(
                boardSize: size,
                board: state.board,
                lastMovePoint: lastPoint,
                ownership: ownership,
              ),
            ),
            if (ownership != null)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  '深黑/浅黑=黑势力  深白/浅白=白势力  黄=不明',
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: OutlinedButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('关闭'),
              ),
            ),
          ],
        ),
      );
    },
  );
}
