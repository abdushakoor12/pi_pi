import 'dart:io';

/// Utility to extract git information for a given working directory.
class GitInfo {
  /// Returns the current branch name, or `null` if not a git repo or on error.
  static Future<String?> getBranch(String workingDirectory) async {
    try {
      final result = await Process.run(
        'git',
        ['branch', '--show-current'],
        workingDirectory: workingDirectory,
      );
      if (result.exitCode == 0) {
        final branch = (result.stdout as String).trim();
        return branch.isNotEmpty ? branch : null;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Returns `true` if the directory is inside a git repository.
  static Future<bool> isGitRepo(String workingDirectory) async {
    try {
      final result = await Process.run(
        'git',
        ['rev-parse', '--is-inside-work-tree'],
        workingDirectory: workingDirectory,
      );
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }
}
