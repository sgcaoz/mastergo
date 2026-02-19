import 'package:flutter/material.dart';
import 'package:mastergo/domain/go/go_game.dart';
import 'package:mastergo/domain/go/go_types.dart';
import 'package:mastergo/features/common/go_board_widget.dart';
import 'package:mastergo/features/common/winrate_chart.dart';

/// 复盘与打谱共用的棋盘操作区：棋盘 + 试下/结束试下/提示/局势分析 + 可选手数导航与底部内容。
/// 通过参数区分场景，避免两处重复实现。
class ReviewBoardPanel extends StatelessWidget {
  const ReviewBoardPanel({
    super.key,
    required this.state,
    required this.tryMode,
    required this.hintPoints,
    required this.onEnterTry,
    required this.onExitTry,
    required this.onRequestHint,
    required this.onRequestOwnership,
    this.lastMovePoint,
    this.hintSummary,
    this.onTryPlay,
    this.title,
    this.turnNavigation,
    this.currentTurn,
    this.maxTurn,
    this.winrates,
    this.onTurnSelected,
    this.bottomChild,
    this.hintLoading = false,
    this.ownershipLoading = false,
    this.boardHeight = 320,
  });

  /// 当前展示的局面（含试下时的临时状态）
  final GoGameState state;
  /// 上一手落子点，用于高亮
  final GoPoint? lastMovePoint;
  /// 是否处于试下模式
  final bool tryMode;
  /// 提示点列表
  final List<GoPoint> hintPoints;
  /// 提示结果摘要（如 "D4:65%  E5:62%"）
  final String? hintSummary;
  /// 进入试下
  final VoidCallback onEnterTry;
  /// 结束试下
  final VoidCallback onExitTry;
  /// 试下时落子回调；非试下时为 null，棋盘不可点
  final ValueChanged<GoPoint>? onTryPlay;
  /// 请求提示（父层异步请求后更新 hintPoints/hintSummary 并重建）
  final VoidCallback onRequestHint;
  /// 请求局势分析（父层异步请求后弹层展示）
  final VoidCallback onRequestOwnership;
  /// 是否正在请求提示
  final bool hintLoading;
  /// 是否正在请求局势分析
  final bool ownershipLoading;
  /// 可选标题
  final String? title;
  /// 可选手数/步数导航行（如「上一手 / 当前手数 / 下一手」或带变着下拉）
  final Widget? turnNavigation;
  /// 仅用于复盘场景：当前手数（用于胜率图高亮）
  final int? currentTurn;
  /// 仅用于复盘场景：最大手数（用于胜率图 X 轴范围）
  final int? maxTurn;
  /// 仅用于复盘场景：胜率数据
  final Map<int, double>? winrates;
  /// 拖动胜率图竖线时回调，用于快速跳转手数
  final ValueChanged<int>? onTurnSelected;
  /// 可选底部内容（妙手恶手、SGF 等）
  final Widget? bottomChild;
  /// 棋盘区域高度
  final double boardHeight;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (title != null) ...<Widget>[
          Text(title!, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
        ],
        SizedBox(
          height: boardHeight,
          child: GoBoardWidget(
            boardSize: state.boardSize,
            board: state.board,
            onTapPoint: tryMode ? onTryPlay : null,
            lastMovePoint: lastMovePoint,
            hintPoints: hintPoints,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            OutlinedButton(
              onPressed: tryMode ? onExitTry : onEnterTry,
              child: Text(tryMode ? '结束试下' : '试下'),
            ),
            OutlinedButton(
              onPressed: hintLoading ? null : onRequestHint,
              child: hintLoading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('提示'),
            ),
            OutlinedButton(
              onPressed: ownershipLoading ? null : onRequestOwnership,
              child: ownershipLoading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('局势分析'),
            ),
          ],
        ),
        if (hintSummary != null && hintSummary!.isNotEmpty) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            '提示胜率: $hintSummary',
            style: const TextStyle(fontSize: 12),
          ),
        ],
        if (winrates != null && maxTurn != null) ...<Widget>[
          const SizedBox(height: 12),
          SizedBox(
            height: 100,
            child: WinrateChart(
              winrates: winrates!,
              maxTurn: maxTurn!,
              highlightTurn: currentTurn,
              onTurnSelected: onTurnSelected,
            ),
          ),
        ],
        if (turnNavigation != null) ...<Widget>[
          const SizedBox(height: 8),
          turnNavigation!,
        ],
        if (bottomChild != null) ...<Widget>[
          const SizedBox(height: 8),
          bottomChild!,
        ],
      ],
    );
  }
}
