import 'package:flutter/material.dart';

enum AppLanguage { zh, en, ja, ko }

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
        return pick(
          zh: '中国规则',
          en: 'Chinese Rules',
          ja: '中国ルール',
          ko: '중국 규칙',
        );
      case 'japanese':
        return pick(
          zh: '日本规则',
          en: 'Japanese Rules',
          ja: '日本ルール',
          ko: '일본 규칙',
        );
      case 'korean':
        return pick(
          zh: '韩国规则',
          en: 'Korean Rules',
          ja: '韓国ルール',
          ko: '한국 규칙',
        );
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
    switch (id) {
      case 'beginner':
        return pick(zh: '快速', en: 'Fast', ja: '快速', ko: '빠름');
      case 'intermediate':
        return pick(zh: '挑战', en: 'Challenge', ja: 'チャレンジ', ko: '도전');
      case 'professional':
        return pick(zh: '专业', en: 'Pro', ja: 'プロ', ko: '프로');
      case 'master':
        return pick(zh: '大师', en: 'Master', ja: 'マスター', ko: '마스터');
      default:
        return fallback;
    }
  }

  String aiProfileDescription(String id, String fallback) {
    switch (id) {
      case 'beginner':
        return pick(
          zh: '效率优先，业余高段水平',
          en: 'Fast and efficient, strong amateur level',
          ja: '効率優先、アマ高段相当',
          ko: '효율 우선, 아마 고단 수준',
        );
      case 'intermediate':
        return pick(
          zh: '兼顾效率与判断力，职业初阶水平',
          en: 'Balanced speed and judgement, entry pro level',
          ja: '効率と判断力のバランス、プロ初級相当',
          ko: '효율과 판단의 균형, 프로 초급 수준',
        );
      case 'professional':
        return pick(
          zh: '职业对局速度，职业对局能力',
          en: 'Professional game speed and strength',
          ja: 'プロ対局の速度と実力',
          ko: '프로 대국 속도와 실력',
        );
      case 'master':
        return pick(
          zh: '职业高段慢棋水准',
          en: 'Top professional strength (slow game)',
          ja: 'プロ高段の持ち時間対局水準',
          ko: '프로 상위권 장고 수준',
        );
      default:
        return fallback;
    }
  }
}
