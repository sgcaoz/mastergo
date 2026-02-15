import 'package:flutter/material.dart';
import 'package:mastergo/domain/entities/master_game_meta.dart';
import 'package:mastergo/features/record_review/record_review_page.dart';
import 'package:mastergo/infra/config/master_game_repository.dart';
import 'package:mastergo/infra/storage/game_record_repository.dart';

class MasterGamesPage extends StatelessWidget {
  const MasterGamesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final MasterGameRepository repository = MasterGameRepository();
    final GameRecordRepository recordRepository = GameRecordRepository();

    return FutureBuilder<List<MasterGameMeta>>(
      future: repository.loadIndex(),
      builder:
          (BuildContext context, AsyncSnapshot<List<MasterGameMeta>> snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(child: Text('加载名局列表失败: ${snapshot.error}'));
            }

            final List<MasterGameMeta> games =
                snapshot.data ?? <MasterGameMeta>[];
            if (games.isEmpty) {
              return const Center(child: Text('暂无内置名局'));
            }

            return ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: games.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (BuildContext context, int index) {
                final MasterGameMeta item = games[index];
                return Card(
                  child: ListTile(
                    title: Text(item.title),
                    subtitle: Text(
                      '${item.players} · ${item.event} · ${item.year}\n'
                      '${item.boardSize}路 · ${item.ruleset} · komi ${item.komi}',
                    ),
                    isThreeLine: true,
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async {
                      final String sgf = await repository.loadSgfContent(
                        item.sgfAssetPath,
                      );
                      await recordRepository.saveMasterGame(
                        id: 'master-${item.id}',
                        title: item.title,
                        boardSize: item.boardSize,
                        ruleset: item.ruleset,
                        komi: item.komi,
                        sgf: sgf,
                      );
                      if (!context.mounted) {
                        return;
                      }
                      await Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => RecordReviewPage(
                            initialSgfContent: sgf,
                            initialTitle: item.title,
                            initialRecordId: 'master-${item.id}',
                            initialSource: 'master',
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
