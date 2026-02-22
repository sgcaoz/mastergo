import 'package:flutter/material.dart';
import 'package:mastergo/app/app_i18n.dart';
import 'package:mastergo/features/ai_play/ai_play_page.dart';
import 'package:mastergo/features/photo_judge/photo_judge_page.dart';
import 'package:mastergo/features/record_review/record_review_page.dart';
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
  int _selectedIndex = 0;
  String? _pendingOpenSgfContent;
  String? _pendingOpenSgfFileName;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _consumePendingOpenedSgf();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
      body: _buildPage(_selectedIndex),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (int value) {
          setState(() {
            _selectedIndex = value;
          });
        },
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
}
