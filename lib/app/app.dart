import 'package:flutter/material.dart';
import 'package:mastergo/app/home_shell.dart';

class MasterGoApp extends StatelessWidget {
  const MasterGoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MasterGo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2F5E3C)),
        useMaterial3: true,
      ),
      home: const HomeShell(),
    );
  }
}
