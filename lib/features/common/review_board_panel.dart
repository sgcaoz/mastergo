import 'package:flutter/material.dart';
import 'package:mastergo/app/app_i18n.dart';
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
    required     this.onEnterTry,
    required this.onExitTry,
    this.onSaveAsVariation,
    required this.onRequestHint,
    required this.onRequestOwnership,
    this.lastMovePoint,
    this.hintSummary,
    this.onTryPlay,
    this.tentativePoint,
    this.tentativeStone,
    this.title,
    this.turnNavigation,
    this.currentTurn,
    this.maxTurn,
    this.winrates,
    this.winrateSeries,
    this.onTurnSelected,
    this.bottomChild,
    this.hintLoading = false,
    this.ownershipLoading = false,
    this.boardHeight = 320,
    this.landscapeSideWidth = 320,
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
  /// 试下时「保存为变化图」；非 null 且在试下时显示按钮
  final VoidCallback? onSaveAsVariation;
  /// 试下时落子回调；非试下时为 null，棋盘不可点
  final ValueChanged<GoPoint>? onTryPlay;
  /// 试下时待确认的落子点（首次点击显示落子虚影，再次点击同一点确认）
  final GoPoint? tentativePoint;
  /// 试下时待确认落子点的棋子颜色（与 tentativePoint 同时使用）
  final GoStone? tentativeStone;
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
  /// 仅用于复盘场景：胜率数据（单条曲线，与 [winrateSeries] 二选一）
  final Map<int, double>? winrates;
  /// 多条胜率曲线（主战线 + 变化图分支，不同颜色）；非空时优先于 [winrates]
  final List<WinrateSeries>? winrateSeries;
  /// 拖动胜率图竖线时回调，用于快速跳转手数
  final ValueChanged<int>? onTurnSelected;
  /// 可选底部内容（妙手恶手、SGF 等）
  final Widget? bottomChild;
  /// 棋盘区域高度
  final double boardHeight;
  /// 横屏分栏时右侧面板宽度
  final double landscapeSideWidth;

  @override
  Widget build(BuildContext context) {
    final AppStrings s = AppStrings.of(context);
    String t({
      required String zh,
      required String en,
      required String ja,
      required String ko,
    }) => s.pick(zh: zh, en: en, ja: ja, ko: ko);
    final Size screenSize = MediaQuery.sizeOf(context);
    final bool useLandscapeSplit =
        screenSize.width > screenSize.height && screenSize.width >= 700;

    final Widget board = GoBoardWidget(
      boardSize: state.boardSize,
      board: state.board,
      onTapPoint: tryMode ? onTryPlay : null,
      lastMovePoint: lastMovePoint,
      tentativePoint: tryMode ? tentativePoint : null,
      tentativeStone: tryMode ? tentativeStone : null,
      hintPoints: hintPoints,
    );

    final Widget infoPanel = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            OutlinedButton(
              onPressed: tryMode ? onExitTry : onEnterTry,
              child: Text(
                tryMode
                    ? t(zh: '结束试下', en: 'End Try', ja: '試し打ち終了', ko: '시험 종료')
                    : t(zh: '试下', en: 'Try', ja: '試し打ち', ko: '시험 수순'),
              ),
            ),
            if (tryMode && onSaveAsVariation != null)
              OutlinedButton(
                onPressed: onSaveAsVariation,
                child: Text(
                  t(
                    zh: '保存为变化图',
                    en: 'Save as variation',
                    ja: '変化図として保存',
                    ko: '변화도로 저장',
                  ),
                ),
              ),
            OutlinedButton(
              onPressed: hintLoading ? null : onRequestHint,
              child: hintLoading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(t(zh: '提示', en: 'Hint', ja: 'ヒント', ko: '힌트')),
            ),
            OutlinedButton(
              onPressed: ownershipLoading ? null : onRequestOwnership,
              child: ownershipLoading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      t(
                        zh: '局势分析',
                        en: 'Position',
                        ja: '局勢解析',
                        ko: '형세 분석',
                      ),
                    ),
            ),
          ],
        ),
        if (hintSummary != null && hintSummary!.isNotEmpty) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            t(
              zh: '提示胜率: $hintSummary',
              en: 'Hint winrate: $hintSummary',
              ja: '候補手勝率: $hintSummary',
              ko: '추천 수 승률: $hintSummary',
            ),
            style: const TextStyle(fontSize: 12),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        if (maxTurn != null &&
            ((winrateSeries != null && winrateSeries!.isNotEmpty) ||
                (winrates != null && winrates!.isNotEmpty))) ...<Widget>[
          const SizedBox(height: 12),
          SizedBox(
            height: 100,
            child: WinrateChart(
              maxTurn: maxTurn!,
              winrates: winrateSeries != null && winrateSeries!.isNotEmpty
                  ? null
                  : winrates,
              winrateSeries: winrateSeries,
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (title != null) ...<Widget>[
          Text(title!, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
        ],
        if (useLandscapeSplit)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(child: AspectRatio(aspectRatio: 1, child: board)),
              const SizedBox(width: 12),
              SizedBox(
                width: landscapeSideWidth,
                child: SingleChildScrollView(child: infoPanel),
              ),
            ],
          )
        else ...<Widget>[
          SizedBox(height: boardHeight, child: board),
          const SizedBox(height: 8),
          infoPanel,
        ],
      ],
    );
  }
}
