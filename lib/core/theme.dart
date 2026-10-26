import 'package:flutter/material.dart';

/// Material 3 theme built from a single seed colour (matches the app icon).
abstract final class AppTheme {
  static const Color seed = Color(0xFF4F46E5);

  /// Brand colours used for platform badges.
  static const Color youtubeRed = Color(0xFFFF0000);
  static const Color instagramPink = Color(0xFFE1306C);
  static const Color whatsappGreen = Color(0xFF25D366);

  static ThemeData light() => _build(Brightness.light);

  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    );
    return ThemeData(
      colorScheme: scheme,
      appBarTheme: const AppBarThemeData(centerTitle: false),
      inputDecorationTheme: const InputDecorationThemeData(
        border: OutlineInputBorder(),
        alignLabelWithHint: true,
      ),
      cardTheme: CardThemeData(
        clipBehavior: Clip.antiAlias,
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
