import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:mastergo/app/app_i18n.dart';
import 'package:mastergo/app/home_shell.dart';
import 'package:mastergo/infra/config/rule_preset_repository.dart';
import 'package:mastergo/domain/entities/rule_presets.dart';
import 'package:mastergo/infra/engine/katago/katago_adapter.dart';
import 'package:mastergo/infra/engine/katago/katago_engine_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MasterGoApp extends StatefulWidget {
  const MasterGoApp({super.key, this.engineAdapter});

  /// Injected in tests. Production uses [PlatformKatagoAdapter].
  final KatagoAdapter? engineAdapter;

  @override
  State<MasterGoApp> createState() => _MasterGoAppState();
}

class _MasterGoAppState extends State<MasterGoApp> with WidgetsBindingObserver {
  static const String _languagePreferenceKey = 'app_language';
  late AppLanguage _language;
  late final KatagoAdapter _engine;

  @override
  void initState() {
    super.initState();
    _engine = widget.engineAdapter ?? PlatformKatagoAdapter();
    WidgetsBinding.instance.addObserver(this);
    _language = AppStrings.resolveFromLocale(
      WidgetsBinding.instance.platformDispatcher.locale,
    );
    unawaited(_restoreLanguagePreference());
    unawaited(_loadRulePresets());
  }

  Future<void> _loadRulePresets() async {
    try {
      final List<RulePreset> presets = await RulePresetRepository().loadPresets();
      if (presets.isEmpty) {
        return;
      }
      RulePresetCatalog.applyPresets(presets);
    } catch (_) {
      // Keep compiled fallback.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      unawaited(_engine.shutdown());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_engine.shutdown());
    super.dispose();
  }

  Future<void> _restoreLanguagePreference() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? savedCode = prefs.getString(_languagePreferenceKey);
    if (!mounted || savedCode == null || savedCode.isEmpty) {
      return;
    }
    setState(() {
      _language = AppStrings.resolveFromCode(savedCode);
    });
  }

  Future<void> _onLanguageChanged(AppLanguage next) async {
    if (_language == next) {
      return;
    }
    setState(() {
      _language = next;
    });
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_languagePreferenceKey, next.code);
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = AppStrings(_language);
    return KatagoEngineScope(
      adapter: _engine,
      child: MaterialApp(
        title: strings.appTitle,
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF2F5E3C),
            surface: const Color(0xFFF4EBDA),
          ),
          scaffoldBackgroundColor: const Color(0xFFEDE3CF),
          useMaterial3: true,
        ),
        locale: _language.locale,
        supportedLocales: AppStrings.supportedLocales,
        localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: HomeShell(
          currentLanguage: _language,
          onLanguageChanged: _onLanguageChanged,
        ),
      ),
    );
  }
}
