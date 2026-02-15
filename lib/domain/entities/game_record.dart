class GameRecord {
  const GameRecord({
    required this.id,
    required this.source,
    required this.title,
    required this.boardSize,
    required this.ruleset,
    required this.komi,
    required this.sgf,
    required this.status,
    required this.sessionJson,
    required this.winrateJson,
    required this.createdAtMs,
    required this.updatedAtMs,
  });

  final String id;
  final String source;
  final String title;
  final int boardSize;
  final String ruleset;
  final double komi;
  final String sgf;
  final String status;
  final String sessionJson;
  final String winrateJson;
  final int createdAtMs;
  final int updatedAtMs;

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'id': id,
      'source': source,
      'title': title,
      'boardSize': boardSize,
      'ruleset': ruleset,
      'komi': komi,
      'sgf': sgf,
      'status': status,
      'sessionJson': sessionJson,
      'winrateJson': winrateJson,
      'createdAtMs': createdAtMs,
      'updatedAtMs': updatedAtMs,
    };
  }

  factory GameRecord.fromMap(Map<String, Object?> map) {
    return GameRecord(
      id: map['id'] as String,
      source: map['source'] as String,
      title: map['title'] as String,
      boardSize: map['boardSize'] as int,
      ruleset: map['ruleset'] as String,
      komi: (map['komi'] as num).toDouble(),
      sgf: map['sgf'] as String,
      status: map['status'] as String,
      sessionJson: map['sessionJson'] as String? ?? '{}',
      winrateJson: map['winrateJson'] as String? ?? '{}',
      createdAtMs: map['createdAtMs'] as int,
      updatedAtMs: map['updatedAtMs'] as int,
    );
  }
}
