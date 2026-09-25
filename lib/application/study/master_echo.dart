import 'dart:convert';

import 'package:mastergo/domain/entities/game_record.dart';
import 'package:mastergo/domain/sgf/sgf_parser.dart';
import 'package:mastergo/domain/study/opening_tokens.dart';
import 'package:mastergo/infra/storage/game_record_repository.dart';

class MasterEchoGame {
  const MasterEchoGame({
    required this.id,
    required this.title,
    required this.players,
    required this.year,
    required this.category,
    required this.boardSize,
    required this.tokens,
  });

  final String id;
  final String title;
  final String players;
  final int year;
  final String category;
  final int boardSize;
  final List<String> tokens;
}

class MasterEchoHit {
  const MasterEchoHit({
    required this.game,
    required this.matchedDepth,
    this.nextMoveToken,
  });

  final MasterEchoGame game;
  final int matchedDepth;
  final String? nextMoveToken;

  String get nextMoveLabel {
    final String? token = nextMoveToken;
    if (token == null || token.isEmpty) {
      return '';
    }
    return prettyMoveToken(token);
  }
}

/// In-memory index of built-in master games for same-opening comparison.
class MasterEchoIndex {
  MasterEchoIndex({SgfParser parser = const SgfParser()}) : _parser = parser;

  static final MasterEchoIndex shared = MasterEchoIndex();

  final SgfParser _parser;
  List<MasterEchoGame> _games = const <MasterEchoGame>[];
  bool _loaded = false;

  List<MasterEchoGame> get games => _games;
  bool get isLoaded => _loaded;

  void replaceGames(List<MasterEchoGame> games) {
    _games = List<MasterEchoGame>.unmodifiable(games);
    _loaded = true;
  }

  void loadFromRecords(List<GameRecord> records) {
    final List<MasterEchoGame> built = <MasterEchoGame>[];
    for (final GameRecord record in records) {
      if (record.sgf.trim().isEmpty) {
        continue;
      }
      try {
        final parsed = _parser.parse(record.sgf);
        built.add(
          MasterEchoGame(
            id: record.id,
            title: record.title,
            players: _playersOf(record, parsed),
            year: _yearOf(record),
            category: _categoryOf(record),
            boardSize: parsed.boardSize,
            tokens: openingTokensFromSgf(parsed),
          ),
        );
      } catch (_) {
        continue;
      }
    }
    replaceGames(built);
  }

  Future<void> ensureLoaded(GameRecordRepository repository) async {
    if (_loaded) {
      return;
    }
    final List<GameRecord> records = await repository.listBySource(
      'master',
      limit: 5000,
    );
    loadFromRecords(records);
  }

  /// Longest shared main-line prefix against the library.
  /// [excludeId] skips the game currently being reviewed.
  List<MasterEchoHit> lookup(
    List<String> queryTokens, {
    String? excludeId,
  }) {
    if (queryTokens.isEmpty || _games.isEmpty) {
      return const <MasterEchoHit>[];
    }
    int bestDepth = 0;
    final List<MasterEchoGame> best = <MasterEchoGame>[];
    for (final MasterEchoGame game in _games) {
      if (excludeId != null && game.id == excludeId) {
        continue;
      }
      final int depth = commonPrefixLength(queryTokens, game.tokens);
      if (depth < 1) {
        continue;
      }
      if (depth > bestDepth) {
        bestDepth = depth;
        best
          ..clear()
          ..add(game);
      } else if (depth == bestDepth) {
        best.add(game);
      }
    }
    if (bestDepth < 1) {
      return const <MasterEchoHit>[];
    }
    return best
        .map((MasterEchoGame game) {
          final String? next = bestDepth < game.tokens.length
              ? game.tokens[bestDepth]
              : null;
          return MasterEchoHit(
            game: game,
            matchedDepth: bestDepth,
            nextMoveToken: next,
          );
        })
        .toList(growable: false);
  }

  MasterEchoGame? dailyPick(DateTime day) {
    if (_games.isEmpty) {
      return null;
    }
    final int key = day.toUtc().year * 400 + day.toUtc().month * 32 + day.toUtc().day;
    return _games[key.abs() % _games.length];
  }

  static String _playersOf(GameRecord record, SgfGame parsed) {
    final Map<String, dynamic> session = _session(record);
    final Object? players = session['players'];
    if (players is String && players.trim().isNotEmpty) {
      return players.trim();
    }
    final String black = parsed.blackName?.trim() ?? '';
    final String white = parsed.whiteName?.trim() ?? '';
    if (black.isNotEmpty || white.isNotEmpty) {
      return '$black vs $white'.trim();
    }
    return record.title;
  }

  static int _yearOf(GameRecord record) {
    final Object? year = _session(record)['year'];
    if (year is num) {
      return year.toInt();
    }
    return 0;
  }

  static String _categoryOf(GameRecord record) {
    final Object? raw = _session(record)['category'];
    if (raw is String && raw.trim().isNotEmpty) {
      return raw.trim();
    }
    return '';
  }

  static Map<String, dynamic> _session(GameRecord record) {
    try {
      final Object decoded = jsonDecode(record.sessionJson);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (_) {}
    return const <String, dynamic>{};
  }
}
