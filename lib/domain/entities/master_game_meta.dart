class MasterGameMeta {
  const MasterGameMeta({
    required this.id,
    required this.title,
    required this.players,
    required this.event,
    required this.year,
    required this.boardSize,
    required this.ruleset,
    required this.komi,
    required this.sgfAssetPath,
    this.tags = const <String>[],
  });

  final String id;
  final String title;
  final String players;
  final String event;
  final int year;
  final int boardSize;
  final String ruleset;
  final double komi;
  final String sgfAssetPath;
  final List<String> tags;

  factory MasterGameMeta.fromJson(Map<String, dynamic> json) {
    final List<dynamic> rawTags = json['tags'] as List<dynamic>? ?? <dynamic>[];
    return MasterGameMeta(
      id: json['id'] as String,
      title: json['title'] as String,
      players: json['players'] as String,
      event: json['event'] as String,
      year: json['year'] as int,
      boardSize: json['boardSize'] as int,
      ruleset: json['ruleset'] as String,
      komi: (json['komi'] as num).toDouble(),
      sgfAssetPath: json['sgfAssetPath'] as String,
      tags: rawTags.map((dynamic item) => item as String).toList(),
    );
  }
}
