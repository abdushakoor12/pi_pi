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

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pi Pi',
      themeMode: _themeMode,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: ChatScreen(
        initialCwd: widget.initialCwd,
        appThemeState: this,
      ),
    );
  }
}
