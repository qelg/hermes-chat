import 'package:flutter/material.dart';

const _background = Color(0xFF08090A);
const _panel = Color(0xFF0F1011);
const _surface = Color(0xFF191A1B);
const _accent = Color(0xFF7170FF);

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: _accent,
    brightness: Brightness.dark,
    surface: _surface,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: _background,
    canvasColor: _panel,
    dividerColor: Colors.white.withValues(alpha: 0.06),
    fontFamily: 'sans-serif',
    textTheme: const TextTheme(
      headlineSmall: TextStyle(
        fontWeight: FontWeight.w500,
        letterSpacing: -0.5,
      ),
      titleMedium: TextStyle(fontWeight: FontWeight.w500),
      bodyMedium: TextStyle(height: 1.5, color: Color(0xFFD0D6E0)),
      labelMedium: TextStyle(color: Color(0xFF8A8F98)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white.withValues(alpha: 0.025),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
      ),
    ),
  );
}
