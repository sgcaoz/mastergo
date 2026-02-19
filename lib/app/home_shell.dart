import 'package:flutter/material.dart';
import 'package:mastergo/features/ai_play/ai_play_page.dart';
import 'package:mastergo/features/photo_judge/photo_judge_page.dart';
import 'package:mastergo/features/record_review/record_review_page.dart';
import 'package:mastergo/infra/sgf_file_opener.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _selectedIndex = 0;
  String? _pendingOpenSgfContent;
  String? _pendingOpenSgfFileName;

  @override
  void initState() {
    super.initState();
    getInitialOpenedSgf().then((OpenedSgfResult? result) {
      if (result != null && mounted) {
        setState(() {
          _pendingOpenSgfContent = result.content;
          _pendingOpenSgfFileName = result.fileName;
          _selectedIndex = 0;
        });
      }
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
    if (_selectedIndex >= 3) {
      _selectedIndex = 2;
    }
    return Scaffold(
      appBar: AppBar(title: const Text('MasterGo')),
      body: _buildPage(_selectedIndex),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (int value) {
          setState(() {
            _selectedIndex = value;
          });
        },
        destinations: const <NavigationDestination>[
          NavigationDestination(
            icon: Icon(Icons.auto_stories_outlined),
            selectedIcon: Icon(Icons.auto_stories),
            label: '打谱',
          ),
          NavigationDestination(
            icon: Icon(Icons.sports_martial_arts_outlined),
            selectedIcon: Icon(Icons.sports_martial_arts),
            label: 'AI 对弈',
          ),
          NavigationDestination(
            icon: Icon(Icons.photo_camera_outlined),
            selectedIcon: Icon(Icons.photo_camera),
            label: '拍照判断',
          ),
        ],
      ),
    );
  }
}
