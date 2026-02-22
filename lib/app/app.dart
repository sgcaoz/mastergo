import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:mastergo/app/app_i18n.dart';
import 'package:mastergo/app/home_shell.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MasterGoApp extends StatefulWidget {
  const MasterGoApp({super.key});

  @override
  State<MasterGoApp> createState() => _MasterGoAppState();
}

class _MasterGoAppState extends State<MasterGoApp> {
  static const String _languagePreferenceKey = 'app_language';
  late AppLanguage _language;

  @override
  void initState() {
    super.initState();
    _language = AppStrings.resolveFromLocale(
      WidgetsBinding.instance.platformDispatcher.locale,
    );
    _restoreLanguagePreference();
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
    return MaterialApp(
      title: strings.appTitle,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2F5E3C)),
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
    );
  }
}
