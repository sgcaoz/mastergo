import 'package:flutter/material.dart';
import 'package:mastergo/features/ai_play/ai_play_page.dart';
import 'package:mastergo/features/photo_judge/photo_judge_page.dart';
import 'package:mastergo/features/record_review/record_review_page.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _selectedIndex = 0;

  static const List<Widget> _pages = <Widget>[
    RecordReviewPage(),
    AIPlayPage(),
    PhotoJudgePage(),
  ];

  @override
  Widget build(BuildContext context) {
    if (_selectedIndex >= _pages.length) {
      _selectedIndex = _pages.length - 1;
    }
    return Scaffold(
      appBar: AppBar(title: const Text('MasterGo')),
      body: _pages[_selectedIndex],
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
