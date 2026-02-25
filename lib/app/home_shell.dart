import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mastergo/app/app_i18n.dart';
import 'package:mastergo/features/ai_play/ai_play_page.dart';
import 'package:mastergo/features/photo_judge/photo_judge_page.dart';
import 'package:mastergo/features/record_review/record_review_page.dart';
import 'package:mastergo/infra/engine/katago/katago_adapter.dart';
import 'package:mastergo/infra/sgf_file_opener.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.currentLanguage,
    required this.onLanguageChanged,
  });

  final AppLanguage currentLanguage;
  final ValueChanged<AppLanguage> onLanguageChanged;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  final KatagoAdapter _katagoAdapter = PlatformKatagoAdapter();
  int _selectedIndex = 0;
  String? _pendingOpenSgfContent;
  String? _pendingOpenSgfFileName;
  bool _startupResolved = false;
  bool _enginePackReady = false;
  bool _enginePackPreparing = true;
  double? _enginePackProgress;
  String? _enginePackError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_bootstrapEngineGate());
    _consumePendingOpenedSgf();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_katagoAdapter.shutdown());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _consumePendingOpenedSgf();
    }
  }

  Future<void> _consumePendingOpenedSgf() async {
    final OpenedSgfResult? result = await getInitialOpenedSgf();
    if (result == null || !mounted) {
      return;
    }
    setState(() {
      _pendingOpenSgfContent = result.content;
      _pendingOpenSgfFileName = result.fileName;
      _selectedIndex = 0;
    });
  }

  Future<void> _bootstrapEngineGate() async {
    // Single-bundle: model is in app assets; no download gate.
    if (!mounted) return;
    setState(() {
      _startupResolved = true;
      _enginePackReady = true;
      _enginePackPreparing = false;
      _enginePackProgress = null;
      _enginePackError = null;
    });
  }

  void _clearPendingOpenSgf() {
    if (_pendingOpenSgfContent != null || _pendingOpenSgfFileName != null) {
      setState(() {
        _pendingOpenSgfContent = null;
        _pendingOpenSgfFileName = null;
      });
    }
  }

  Widget _buildPage(int index) {
    switch (index) {
      case 0:
        return RecordReviewPage(
          openWithSgfContent: _pendingOpenSgfContent,
          openWithSgfFileName: _pendingOpenSgfFileName,
          onOpenWithSgfConsumed: _clearPendingOpenSgf,
        );
      case 1:
        return const AIPlayPage();
      case 2:
        return const PhotoJudgePage();
      default:
        return RecordReviewPage(
          openWithSgfContent: _pendingOpenSgfContent,
          openWithSgfFileName: _pendingOpenSgfFileName,
          onOpenWithSgfConsumed: _clearPendingOpenSgf,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = AppStrings(widget.currentLanguage);
    if (_selectedIndex >= 3) {
      _selectedIndex = 2;
    }
    final bool allowNavigation = _startupResolved && _enginePackReady;

    return Scaffold(
      appBar: AppBar(
        title: Text(strings.appTitle),
        actions: <Widget>[
          PopupMenuButton<AppLanguage>(
            tooltip: strings.language,
            icon: const Icon(Icons.language),
            onSelected: widget.onLanguageChanged,
            itemBuilder: (BuildContext context) {
              return AppLanguage.values.map((AppLanguage language) {
                final bool selected = language == widget.currentLanguage;
                return PopupMenuItem<AppLanguage>(
                  value: language,
                  child: Row(
                    children: <Widget>[
                      Expanded(child: Text(strings.labelForLanguage(language))),
                      if (selected) const Icon(Icons.check, size: 18),
                    ],
                  ),
                );
              }).toList();
            },
          ),
        ],
      ),
      body: !_startupResolved
          ? const SizedBox.shrink()
          : _enginePackReady
          ? _buildPage(_selectedIndex)
          : _buildEnginePreparingPage(strings),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: allowNavigation
            ? (int value) {
                setState(() {
                  _selectedIndex = value;
                });
              }
            : null,
        destinations: <NavigationDestination>[
          NavigationDestination(
            icon: Icon(Icons.auto_stories_outlined),
            selectedIcon: Icon(Icons.auto_stories),
            label: strings.tabReview,
          ),
          NavigationDestination(
            icon: Icon(Icons.sports_martial_arts_outlined),
            selectedIcon: Icon(Icons.sports_martial_arts),
            label: strings.tabAiPlay,
          ),
          NavigationDestination(
            icon: Icon(Icons.photo_camera_outlined),
            selectedIcon: Icon(Icons.photo_camera),
            label: strings.tabPhotoJudge,
          ),
        ],
      ),
    );
  }

  Widget _buildEnginePreparingPage(AppStrings strings) {
    final String statusText;
    if (_enginePackError != null) {
      statusText = strings.pick(
        zh: '引擎资源下载失败：$_enginePackError',
        en: 'Engine asset download failed: $_enginePackError',
        ja: 'エンジン資産のダウンロードに失敗しました: $_enginePackError',
        ko: '엔진 리소스 다운로드 실패: $_enginePackError',
      );
    } else if (_enginePackProgress != null) {
      final String pct = (_enginePackProgress! * 100).toStringAsFixed(0);
      statusText = strings.pick(
        zh: '正在下载引擎资源... $pct%',
        en: 'Downloading engine assets... $pct%',
        ja: 'エンジン資産をダウンロード中... $pct%',
        ko: '엔진 리소스 다운로드 중... $pct%',
      );
    } else {
      statusText = strings.pick(
        zh: '正在下载引擎资源...',
        en: 'Downloading engine assets...',
        ja: 'エンジン資産をダウンロード中...',
        ko: '엔진 리소스 다운로드 중...',
      );
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (_enginePackPreparing)
              LinearProgressIndicator(value: _enginePackProgress),
            if (_enginePackPreparing) const SizedBox(height: 12),
            Text(
              statusText,
              textAlign: TextAlign.center,
            ),
            if (_enginePackError != null)
              const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}
