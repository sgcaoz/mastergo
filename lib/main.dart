import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:mastergo/app/app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  _initDesktopDatabaseFactory();
  runApp(const MasterGoApp());
}

/// sqflite ships no desktop implementation, so on Linux/Windows/macOS we route
/// the global database factory through the FFI backend. Mobile platforms keep
/// the default sqflite factory untouched.
void _initDesktopDatabaseFactory() {
  if (kIsWeb) {
    return;
  }
  if (defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.macOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
}
