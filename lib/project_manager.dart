import 'package:shared_preferences/shared_preferences.dart';

/// Persists app-level settings and user projects via SharedPreferences.
class ProjectManager {
  static const _keyLastCwd = 'last_cwd';
  static const _keyProjects = 'projects';
  static const _keyThemeMode = 'theme_mode';

  // ── Last working directory ──────────────────────────────────────────────

  static Future<String?> getLastCwd() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyLastCwd);
  }

  static Future<void> setLastCwd(String cwd) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyLastCwd, cwd);
  }

  // ── Saved projects ──────────────────────────────────────────────────────

  static Future<List<String>> getProjects() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_keyProjects) ?? [];
  }

  static Future<void> addProject(String path) async {
    final prefs = await SharedPreferences.getInstance();
    final projects = prefs.getStringList(_keyProjects) ?? [];
    if (!projects.contains(path)) {
      projects.add(path);
      await prefs.setStringList(_keyProjects, projects);
    }
  }

  static Future<void> removeProject(String path) async {
    final prefs = await SharedPreferences.getInstance();
    final projects = prefs.getStringList(_keyProjects) ?? [];
    projects.remove(path);
    await prefs.setStringList(_keyProjects, projects);
  }

  // ── Theme mode ──────────────────────────────────────────────────────────

  /// Returns one of `'system'`, `'light'`, `'dark'`.
  static Future<String> getThemeMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyThemeMode) ?? 'system';
  }

  static Future<void> setThemeMode(String mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyThemeMode, mode);
  }
}
