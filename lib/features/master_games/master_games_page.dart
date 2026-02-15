import 'package:flutter/material.dart';
import 'package:mastergo/domain/entities/master_game_meta.dart';
import 'package:mastergo/infra/config/master_game_repository.dart';

class MasterGamesPage extends StatelessWidget {
  const MasterGamesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final MasterGameRepository repository = MasterGameRepository();

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
                      if (!context.mounted) {
                        return;
                      }
                      await showModalBottomSheet<void>(
                        context: context,
                        isScrollControlled: true,
                        builder: (BuildContext context) {
                          return DraggableScrollableSheet(
                            expand: false,
                            builder:
                                (
                                  BuildContext context,
                                  ScrollController controller,
                                ) {
                                  return Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: <Widget>[
                                        Text(
                                          item.title,
                                          style: Theme.of(
                                            context,
                                          ).textTheme.titleLarge,
                                        ),
                                        const SizedBox(height: 8),
                                        const Text('SGF 预览（后续接入完整复盘页）'),
                                        const SizedBox(height: 8),
                                        Expanded(
                                          child: SingleChildScrollView(
                                            controller: controller,
                                            child: SelectableText(sgf),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                          );
                        },
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
