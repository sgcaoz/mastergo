import 'package:flutter/foundation.dart';

/// Debug-only log. No-op in release/profile.
void appLog(String message) {
  if (kDebugMode) {
    debugPrint(message);
  }
}
