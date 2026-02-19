import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:mastergo/domain/entities/game_record.dart';
import 'package:mastergo/features/record_review/record_review_page.dart';
import 'package:mastergo/infra/storage/game_record_repository.dart';

class MasterGamesPage extends StatelessWidget {
  const MasterGamesPage({super.key});

  static String _masterRecordSubtitle(GameRecord record) {
    try {
      final Map<String, dynamic>? m =
          jsonDecode(record.sessionJson) as Map<String, dynamic>?;
      if (m == null) return record.title;
      final String? players = m['players'] as String?;
      final String? event = m['event'] as String?;
      final Object? year = m['year'];
      if (players != null && event != null && year != null) {
        return '$players · $event · $year';
      }
    } catch (_) {}
    return record.title;
  }

  Future<List<GameRecord>> _loadMasterGames(
    GameRecordRepository recordRepository,
  ) async {
    return recordRepository.listBySource('master');
  }

  @override
  Widget build(BuildContext context) {
    final GameRecordRepository recordRepository = GameRecordRepository();
    final Future<List<GameRecord>> future = _loadMasterGames(recordRepository);

    return FutureBuilder<List<GameRecord>>(
      future: future,
      builder:
          (BuildContext context, AsyncSnapshot<List<GameRecord>> snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(child: Text('加载名局列表失败: ${snapshot.error}'));
            }

            final List<GameRecord> games = snapshot.data ?? <GameRecord>[];
            if (games.isEmpty) {
              return const Center(child: Text('暂无内置名局'));
            }

            return ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: games.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (BuildContext context, int index) {
                final GameRecord record = games[index];
                return Card(
                  child: ListTile(
                    title: Text(record.title),
                    subtitle: Text(
                      '${_masterRecordSubtitle(record)}\n'
                      '${record.boardSize}路 · ${record.ruleset} · komi ${record.komi}',
                    ),
                    isThreeLine: true,
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async {
                      if (!context.mounted) return;
                      await Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => RecordReviewPage(
                            initialSgfContent: record.sgf,
                            initialTitle: record.title,
                            initialRecordId: record.id,
                            initialSource: record.source,
                          ),
                        ),
                      );
                    },
                  ),
                );
              },
            );
          },
    );
  }
}
