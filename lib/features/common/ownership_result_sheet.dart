import 'package:flutter/material.dart';
import 'package:mastergo/domain/go/go_game.dart';
import 'package:mastergo/domain/go/go_types.dart';
import 'package:mastergo/features/common/go_board_widget.dart';
import 'package:mastergo/infra/engine/katago/katago_adapter.dart';

class _OwnershipPointEstimate {
  const _OwnershipPointEstimate({
    required this.blackStable,
    required this.whiteStable,
    required this.blackPotential,
    required this.whitePotential,
    required this.potentialWeight,
  });

  final int blackStable;
  final int whiteStable;
  final int blackPotential;
  final int whitePotential;
  final double potentialWeight;

  double get blackEstimated => blackStable + blackPotential * potentialWeight;
  double get whiteEstimated => whiteStable + whitePotential * potentialWeight;
}

_OwnershipPointEstimate _estimatePointsFromOwnership(List<double>? ownership) {
  // 与当前运行时约定一致：ownership > 0 归黑，< 0 归白
  const double stableThreshold = 0.75;
  const double potentialThreshold = 0.35;
  const double potentialWeight = 0.55;

  if (ownership == null || ownership.isEmpty) {
    return const _OwnershipPointEstimate(
      blackStable: 0,
      whiteStable: 0,
      blackPotential: 0,
      whitePotential: 0,
      potentialWeight: potentialWeight,
    );
  }

  int blackStable = 0;
  int whiteStable = 0;
  int blackPotential = 0;
  int whitePotential = 0;
  for (final double raw in ownership) {
    final double v = raw.clamp(-1.0, 1.0);
    final double av = v.abs();
    if (av >= stableThreshold) {
      if (v > 0) {
        blackStable++;
      } else {
        whiteStable++;
      }
    } else if (av >= potentialThreshold) {
      if (v > 0) {
        blackPotential++;
      } else {
        whitePotential++;
      }
    }
  }
  return _OwnershipPointEstimate(
    blackStable: blackStable,
    whiteStable: whiteStable,
    blackPotential: blackPotential,
    whitePotential: whitePotential,
    potentialWeight: potentialWeight,
  );
}

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
  final _OwnershipPointEstimate estimate = _estimatePointsFromOwnership(
    ownership,
  );
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
              '黑目：${estimate.blackEstimated.toStringAsFixed(1)}'
              '（稳${estimate.blackStable}+潜${estimate.blackPotential}×${estimate.potentialWeight.toStringAsFixed(2)}）',
              style: const TextStyle(fontSize: 13),
            ),
            Text(
              '白目：${estimate.whiteEstimated.toStringAsFixed(1)}'
              '（稳${estimate.whiteStable}+潜${estimate.whitePotential}×${estimate.potentialWeight.toStringAsFixed(2)}）',
              style: const TextStyle(fontSize: 13),
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
