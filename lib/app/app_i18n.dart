import 'package:flutter/material.dart';

enum AppLanguage { zh, en, ja, ko }

enum _AiProfileTier { beginner, intermediate, professional, master, unknown }

_AiProfileTier _resolveAiProfileTier(String id, String fallback) {
  final String normalizedId = id.trim().toLowerCase();
  switch (normalizedId) {
    case 'beginner':
    case 'fast':
      return _AiProfileTier.beginner;
    case 'intermediate':
    case 'challenge':
      return _AiProfileTier.intermediate;
    case 'professional':
    case 'pro':
    case 'advanced':
      return _AiProfileTier.professional;
    case 'master':
      return _AiProfileTier.master;
  }
  final String normalizedName = fallback.trim().toLowerCase();
  if (normalizedName.contains('快速') || normalizedName.contains('fast')) {
    return _AiProfileTier.beginner;
  }
  if (normalizedName.contains('挑战') ||
      normalizedName.contains('进阶') ||
      normalizedName.contains('challenge')) {
    return _AiProfileTier.intermediate;
  }
  if (normalizedName.contains('专业') ||
      normalizedName.contains('职业') ||
      normalizedName.contains('pro')) {
    return _AiProfileTier.professional;
  }
  if (normalizedName.contains('大师') || normalizedName.contains('master')) {
    return _AiProfileTier.master;
  }
  return _AiProfileTier.unknown;
}

extension AppLanguageX on AppLanguage {
  Locale get locale => switch (this) {
    AppLanguage.zh => const Locale('zh'),
    AppLanguage.en => const Locale('en'),
    AppLanguage.ja => const Locale('ja'),
    AppLanguage.ko => const Locale('ko'),
  };

  String get code => locale.languageCode;
}

class AppStrings {
  AppStrings(this.current);

  final AppLanguage current;

  static const List<Locale> supportedLocales = <Locale>[
    Locale('zh'),
    Locale('en'),
    Locale('ja'),
    Locale('ko'),
  ];

  static AppLanguage resolveFromLocale(Locale locale) {
    final String lang = locale.languageCode.toLowerCase();
    return switch (lang) {
      'zh' => AppLanguage.zh,
      'ja' => AppLanguage.ja,
      'ko' => AppLanguage.ko,
      _ => AppLanguage.en,
    };
  }

  static AppLanguage resolveFromCode(String? code) {
    if (code == null || code.isEmpty) {
      return AppLanguage.en;
    }
    return resolveFromLocale(Locale(code));
  }

  static AppStrings of(BuildContext context) {
    return AppStrings(resolveFromLocale(Localizations.localeOf(context)));
  }

  String pick({
    required String zh,
    required String en,
    required String ja,
    required String ko,
  }) {
    return switch (current) {
      AppLanguage.zh => zh,
      AppLanguage.en => en,
      AppLanguage.ja => ja,
      AppLanguage.ko => ko,
    };
  }

  String get appTitle => switch (current) {
    AppLanguage.zh => '围棋大师',
    AppLanguage.en => 'mastergo',
    AppLanguage.ja => '囲碁マスター',
    AppLanguage.ko => '바둑 마스터',
  };

  String get tabReview => switch (current) {
    AppLanguage.zh => '打谱',
    AppLanguage.en => 'Review',
    AppLanguage.ja => '棋譜',
    AppLanguage.ko => '복기',
  };

  String get tabAiPlay => switch (current) {
    AppLanguage.zh => 'AI 对弈',
    AppLanguage.en => 'AI Play',
    AppLanguage.ja => 'AI対局',
    AppLanguage.ko => 'AI 대국',
  };

  String get tabPhotoJudge => switch (current) {
    AppLanguage.zh => '拍照判断',
    AppLanguage.en => 'Photo Judge',
    AppLanguage.ja => '写真判定',
    AppLanguage.ko => '사진 판단',
  };

  String get language => switch (current) {
    AppLanguage.zh => '语言',
    AppLanguage.en => 'Language',
    AppLanguage.ja => '言語',
    AppLanguage.ko => '언어',
  };

  String labelForLanguage(AppLanguage target) {
    return switch (target) {
      AppLanguage.zh => '中文',
      AppLanguage.en => 'English',
      AppLanguage.ja => '日本語',
      AppLanguage.ko => '한국어',
    };
  }

  String ruleLabel(String ruleId) {
    switch (ruleId) {
      case 'chinese':
        return pick(zh: '中国规则', en: 'Chinese Rules', ja: '中国ルール', ko: '중국 규칙');
      case 'japanese':
        return pick(zh: '日本规则', en: 'Japanese Rules', ja: '日本ルール', ko: '일본 규칙');
      case 'korean':
        return pick(zh: '韩国规则', en: 'Korean Rules', ja: '韓国ルール', ko: '한국 규칙');
      case 'classical':
        return pick(
          zh: '古谱规则（不贴目）',
          en: 'Classical Rules (No Komi)',
          ja: '古譜ルール（コミなし）',
          ko: '고보 규칙(덤 없음)',
        );
      default:
        return ruleId;
    }
  }

  String aiProfileName(String id, String fallback) {
    final _AiProfileTier tier = _resolveAiProfileTier(id, fallback);
    switch (tier) {
      case _AiProfileTier.beginner:
        return pick(zh: '快速', en: 'Fast', ja: '快速', ko: '빠름');
      case _AiProfileTier.intermediate:
        return pick(zh: '挑战', en: 'Challenge', ja: 'チャレンジ', ko: '도전');
      case _AiProfileTier.professional:
        return pick(zh: '进阶', en: 'Advanced', ja: '上級', ko: '고급');
      case _AiProfileTier.master:
        return pick(zh: '大师', en: 'Master', ja: 'マスター', ko: '마스터');
      case _AiProfileTier.unknown:
        final String normalized = fallback.trim();
        if (normalized.isNotEmpty) {
          return normalized;
        }
        return id;
    }
  }

  String aiProfileDescription(String id, String fallback) {
    final _AiProfileTier tier = _resolveAiProfileTier(id, fallback);
    switch (tier) {
      case _AiProfileTier.beginner:
        return pick(
          zh: '效率优先，适合快速对弈',
          en: 'Speed-first profile for quick games',
          ja: '速度重視、短時間対局向け',
          ko: '속도 우선, 빠른 대국에 적합',
        );
      case _AiProfileTier.intermediate:
        return pick(
          zh: '效率与判断平衡，适合日常训练',
          en: 'Balanced speed and judgement for practice',
          ja: '速度と判断のバランス、日常練習向け',
          ko: '속도와 판단의 균형, 일상 훈련용',
        );
      case _AiProfileTier.professional:
        return pick(
          zh: '更强判断与更深搜索，适合进阶训练',
          en: 'Stronger judgement with deeper search',
          ja: 'より深い探索と強い判断、上級練習向け',
          ko: '더 깊은 탐색과 강한 판단, 고급 훈련용',
        );
      case _AiProfileTier.master:
        return pick(
          zh: '高强度慢思考，对局时间更长',
          en: 'Top strength with longer thinking time',
          ja: '高強度の長考設定',
          ko: '최상위 강도, 더 긴 사고 시간',
        );
      case _AiProfileTier.unknown:
        final String normalized = fallback.trim();
        if (normalized.isNotEmpty) {
          return normalized;
        }
        return id;
    }
  }
}
