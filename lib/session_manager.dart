import 'dart:convert';
import 'dart:io';

class SessionSummary {
  final String path;
  final String id;
  final String timestamp;
  final String title;

  const SessionSummary({
    required this.path,
    required this.id,
    required this.timestamp,
    required this.title,
  });
}

class SessionManager {
  static String get _agentDir {
    final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.';
    return '$home/.pi/agent';
  }

  /// Encode a cwd path to the session directory name pi uses.
  /// e.g. /Users/abd/codes/pi_pi → --Users-abd-codes-pi_pi--
  static String _encodeCwd(String cwd) {
    var s = cwd;
    if (s.startsWith('/')) s = s.substring(1);
    s = s.replaceAll('/', '-');
    return '--$s--';
  }

  /// List all session summaries for a given working directory.
  static Future<List<SessionSummary>> listSessions(String cwd) async {
    final dir = Directory('$_agentDir/sessions/${_encodeCwd(cwd)}');
    if (!await dir.exists()) return [];

    final results = <SessionSummary>[];
    await for (final entity in dir.list()) {
      if (entity is File && entity.path.endsWith('.jsonl')) {
        final summary = await _parseSummary(entity.path);
        if (summary != null) results.add(summary);
      }
    }

    // Sort newest first
    results.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return results;
  }

  /// Parse just enough of a session file to get a title preview.
  static Future<SessionSummary?> _parseSummary(String path) async {
    try {
      final lines = await File(path).readAsLines();
      if (lines.isEmpty) return null;

      final sessionEntry = jsonDecode(lines.first) as Map<String, dynamic>;
      if (sessionEntry['type'] != 'session') return null;

      final id = sessionEntry['id'] as String? ?? '';
      final timestamp = sessionEntry['timestamp'] as String? ?? '';

      // Find first user message as title
      String title = '';
      for (final line in lines.skip(1)) {
        try {
          final entry = jsonDecode(line) as Map<String, dynamic>;
          if (entry['type'] == 'message') {
            final msg = entry['message'] as Map<String, dynamic>?;
            if (msg?['role'] == 'user') {
              final content = msg!['content'];
              if (content is List && content.isNotEmpty) {
                title = (content.first as Map)['text'] as String? ?? '';
              } else if (content is String) {
                title = content;
              }
              if (title.length > 80) title = '${title.substring(0, 80)}…';
              break;
            }
          }
        } catch (_) {}
      }

      return SessionSummary(
        path: path,
        id: id,
        timestamp: timestamp,
        title: title.isNotEmpty ? title : 'Empty session',
      );
    } catch (_) {
      return null;
    }
  }

  /// Parse all messages from a session file and return as raw JSON maps.
  static Future<List<Map<String, dynamic>>> loadMessages(String path) async {
    final lines = await File(path).readAsLines();
    final messages = <Map<String, dynamic>>[];
    for (final line in lines) {
      try {
        final entry = jsonDecode(line) as Map<String, dynamic>;
        if (entry['type'] == 'message') {
          messages.add(entry);
        }
      } catch (_) {}
    }
    return messages;
  }
}
