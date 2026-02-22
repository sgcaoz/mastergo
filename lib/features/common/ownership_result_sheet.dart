import 'package:flutter/material.dart';
import 'package:mastergo/app/app_i18n.dart';
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
  final AppStrings s = AppStrings.of(context);
  String t({
    required String zh,
    required String en,
    required String ja,
    required String ko,
  }) => s.pick(zh: zh, en: en, ja: ja, ko: ko);
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
          ? t(
              zh: '黑领先约 ${scoreLead.toStringAsFixed(1)} 目',
              en: 'Black leads by ${scoreLead.toStringAsFixed(1)}',
              ja: '黒が約 ${scoreLead.toStringAsFixed(1)} 目リード',
              ko: '흑 약 ${scoreLead.toStringAsFixed(1)}집 우세',
            )
          : t(
              zh: '白领先约 ${(-scoreLead).toStringAsFixed(1)} 目',
              en: 'White leads by ${(-scoreLead).toStringAsFixed(1)}',
              ja: '白が約 ${(-scoreLead).toStringAsFixed(1)} 目リード',
              ko: '백 약 ${(-scoreLead).toStringAsFixed(1)}집 우세',
            );
      return Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(ctx).viewPadding.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text(
                t(
                  zh: '局势分析（势力与目数估算）',
                  en: 'Position Analysis (Ownership & Points)',
                  ja: '局勢解析（勢力と目数推定）',
                  ko: '형세 분석(세력/집 추정)',
                ),
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 16,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              t(
                zh: '目数估算：$leadText',
                en: 'Estimated lead: $leadText',
                ja: '目数推定: $leadText',
                ko: '집 추정: $leadText',
              ),
              style: const TextStyle(fontSize: 14),
            ),
            Text(
              t(
                zh:
                    '黑目：${estimate.blackEstimated.toStringAsFixed(1)}（稳${estimate.blackStable}+潜${estimate.blackPotential}×${estimate.potentialWeight.toStringAsFixed(2)}）',
                en:
                    'Black: ${estimate.blackEstimated.toStringAsFixed(1)} (stable ${estimate.blackStable} + potential ${estimate.blackPotential} x ${estimate.potentialWeight.toStringAsFixed(2)})',
                ja:
                    '黒: ${estimate.blackEstimated.toStringAsFixed(1)}（確定${estimate.blackStable}+潜在${estimate.blackPotential}x${estimate.potentialWeight.toStringAsFixed(2)}）',
                ko:
                    '흑: ${estimate.blackEstimated.toStringAsFixed(1)} (확정 ${estimate.blackStable} + 잠재 ${estimate.blackPotential} x ${estimate.potentialWeight.toStringAsFixed(2)})',
              ),
              style: const TextStyle(fontSize: 13),
            ),
            Text(
              t(
                zh:
                    '白目：${estimate.whiteEstimated.toStringAsFixed(1)}（稳${estimate.whiteStable}+潜${estimate.whitePotential}×${estimate.potentialWeight.toStringAsFixed(2)}）',
                en:
                    'White: ${estimate.whiteEstimated.toStringAsFixed(1)} (stable ${estimate.whiteStable} + potential ${estimate.whitePotential} x ${estimate.potentialWeight.toStringAsFixed(2)})',
                ja:
                    '白: ${estimate.whiteEstimated.toStringAsFixed(1)}（確定${estimate.whiteStable}+潜在${estimate.whitePotential}x${estimate.potentialWeight.toStringAsFixed(2)}）',
                ko:
                    '백: ${estimate.whiteEstimated.toStringAsFixed(1)} (확정 ${estimate.whiteStable} + 잠재 ${estimate.whitePotential} x ${estimate.potentialWeight.toStringAsFixed(2)})',
              ),
              style: const TextStyle(fontSize: 13),
            ),
            Text(
              t(
                zh: '胜率：黑 ${(blackWr * 100).toStringAsFixed(1)}%',
                en: 'Winrate: Black ${(blackWr * 100).toStringAsFixed(1)}%',
                ja: '勝率: 黒 ${(blackWr * 100).toStringAsFixed(1)}%',
                ko: '승률: 흑 ${(blackWr * 100).toStringAsFixed(1)}%',
              ),
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
              Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  t(
                    zh: '深黑/浅黑=黑势力  深白/浅白=白势力  黄=不明',
                    en: 'Dark/Light Black = Black ownership, Dark/Light White = White ownership, Yellow = unsettled',
                    ja: '濃黒/薄黒=黒勢力  濃白/薄白=白勢力  黄=不明',
                    ko: '진한/연한 흑=흑 세력, 진한/연한 백=백 세력, 노랑=불명',
                  ),
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: OutlinedButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text(t(zh: '关闭', en: 'Close', ja: '閉じる', ko: '닫기')),
              ),
            ),
          ],
        ),
      );
    },
  );
}
