import 'package:flutter/material.dart';

import 'chat_screen.dart';
import 'project_manager.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final savedTheme = await ProjectManager.getThemeMode();
  final savedCwd = await ProjectManager.getLastCwd();

  runApp(MyApp(
    initialThemeMode: _parseThemeMode(savedTheme),
    initialCwd: savedCwd,
  ));
}

ThemeMode _parseThemeMode(String value) {
  switch (value) {
    case 'light':
      return ThemeMode.light;
    case 'dark':
      return ThemeMode.dark;
    default:
      return ThemeMode.system;
  }
}

class MyApp extends StatefulWidget {
  final ThemeMode initialThemeMode;
  final String? initialCwd;

  const MyApp({
    super.key,
    required this.initialThemeMode,
    this.initialCwd,
  });

  @override
  State<MyApp> createState() => MyAppState();
}

class MyAppState extends State<MyApp> {
  late ThemeMode _themeMode;

  ThemeMode get themeMode => _themeMode;

  @override
  void initState() {
    super.initState();
    _themeMode = widget.initialThemeMode;
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    setState(() => _themeMode = mode);
    String value;
    switch (mode) {
      case ThemeMode.light:
        value = 'light';
        break;
      case ThemeMode.dark:
        value = 'dark';
        break;
      default:
        value = 'system';
    }
    await ProjectManager.setThemeMode(value);
  }

  ThemeData _buildLightTheme() {
    const cs = ColorScheme(
      brightness: Brightness.light,
      primary: Color(0xFF0550AE),
      onPrimary: Color(0xFFFFFFFF),
      primaryContainer: Color(0xFFD7E7FF),
      onPrimaryContainer: Color(0xFF001B3D),
      secondary: Color(0xFF6E3CB5),
      onSecondary: Color(0xFFFFFFFF),
      secondaryContainer: Color(0xFFF0E4FF),
      onSecondaryContainer: Color(0xFF250059),
      tertiary: Color(0xFF1A7F37),
      onTertiary: Color(0xFFFFFFFF),
      tertiaryContainer: Color(0xFFA7F5B9),
      onTertiaryContainer: Color(0xFF00210A),
      error: Color(0xFFBA1A1A),
      onError: Color(0xFFFFFFFF),
      errorContainer: Color(0xFFFFDAD6),
      onErrorContainer: Color(0xFF410002),
      surface: Color(0xFFF6F8FA),
      onSurface: Color(0xFF191C20),
      surfaceContainerHighest: Color(0xFFE1E4E8),
      onSurfaceVariant: Color(0xFF44484E),
      outline: Color(0xFF73777F),
      outlineVariant: Color(0xFFC3C7CE),
      shadow: Color(0xFF000000),
      scrim: Color(0xFF000000),
      inverseSurface: Color(0xFF2E3135),
      onInverseSurface: Color(0xFFF0F0F4),
      inversePrimary: Color(0xFFAAC7FF),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: cs,
      scaffoldBackgroundColor: cs.surface,
      fontFamily: 'monospace',
      appBarTheme: AppBarTheme(
        backgroundColor: cs.surface,
        foregroundColor: cs.onSurface,
        elevation: 0,
        scrolledUnderElevation: 1,
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: CardThemeData(
        color: cs.surfaceContainerHighest,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: cs.outlineVariant),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: cs.surfaceContainerHighest,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: cs.outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: cs.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: cs.primary, width: 2),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: cs.outlineVariant,
        thickness: 1,
        space: 1,
      ),
    );
  }

  ThemeData _buildDarkTheme() {
    const cs = ColorScheme(
      brightness: Brightness.dark,
      primary: Color(0xFF6CB6FF),
      onPrimary: Color(0xFF002D5E),
      primaryContainer: Color(0xFF0C4180),
      onPrimaryContainer: Color(0xFFD7E7FF),
      secondary: Color(0xFFD2A8FF),
      onSecondary: Color(0xFF380077),
      secondaryContainer: Color(0xFF4F1A9C),
      onSecondaryContainer: Color(0xFFF0E4FF),
      tertiary: Color(0xFF7EE787),
      onTertiary: Color(0xFF002D0C),
      tertiaryContainer: Color(0xFF0C4E24),
      onTertiaryContainer: Color(0xFFA7F5B9),
      error: Color(0xFFFF6B6B),
      onError: Color(0xFF690005),
      errorContainer: Color(0xFF93000A),
      onErrorContainer: Color(0xFFFFDAD6),
      surface: Color(0xFF0D1117),
      onSurface: Color(0xFFE6EDF3),
      surfaceContainerHighest: Color(0xFF161B22),
      onSurfaceVariant: Color(0xFF8B949E),
      outline: Color(0xFF30363D),
      outlineVariant: Color(0xFF21262D),
      shadow: Color(0xFF000000),
      scrim: Color(0xFF000000),
      inverseSurface: Color(0xFFE6EDF3),
      onInverseSurface: Color(0xFF0D1117),
      inversePrimary: Color(0xFF0550AE),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: cs,
      scaffoldBackgroundColor: cs.surface,
      fontFamily: 'monospace',
      appBarTheme: AppBarTheme(
        backgroundColor: cs.surface,
        foregroundColor: cs.onSurface,
        elevation: 0,
        scrolledUnderElevation: 1,
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: CardThemeData(
        color: cs.surfaceContainerHighest,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: cs.outline),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: cs.surfaceContainerHighest,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: cs.outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: cs.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: cs.primary, width: 2),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: cs.outline,
        thickness: 1,
        space: 1,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pi Pi',
      themeMode: _themeMode,
      theme: _buildLightTheme(),
      darkTheme: _buildDarkTheme(),
      home: ChatScreen(
        initialCwd: widget.initialCwd,
        appThemeState: this,
      ),
    );
  }
}
