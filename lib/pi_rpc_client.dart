import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'models.dart';

/// Protocol-compliant JSONL reader that splits only on `\n` (LF).
///
/// Per the pi RPC spec, `LineSplitter` is NOT compliant because it also
/// splits on U+2028 and U+2029, which are valid inside JSON strings.
class _JsonlReader {
  final Stream<List<int>> input;
  late final StreamSubscription<List<int>> _subscription;
  final _buffer = StringBuffer();
  final _controller = StreamController<String>.broadcast();

  _JsonlReader(this.input) {
    _subscription = input.listen(
      (chunk) {
        _buffer.write(utf8.decode(chunk, allowMalformed: true));
        _emitLines();
      },
      onError: _controller.addError,
      onDone: () {
        _emitLines();
        final remainder = _buffer.toString();
        if (remainder.isNotEmpty) {
          final line = remainder.endsWith('\r')
              ? remainder.substring(0, remainder.length - 1)
              : remainder;
          if (line.isNotEmpty) _controller.add(line);
        }
        _controller.close();
      },
    );
  }

  void _emitLines() {
    var text = _buffer.toString();
    while (true) {
      final idx = text.indexOf('\n');
      if (idx == -1) break;
      var line = text.substring(0, idx);
      if (line.endsWith('\r')) {
        line = line.substring(0, line.length - 1);
      }
      if (line.isNotEmpty) _controller.add(line);
      text = text.substring(idx + 1);
    }
    _buffer.clear();
    _buffer.write(text);
  }

  Stream<String> get lines => _controller.stream;

  Future<void> dispose() async {
    await _subscription.cancel();
    await _controller.close();
  }
}

/// Client for the pi agent JSON-RPC protocol over stdin/stdout.
///
/// Features:
/// - Protocol-compliant JSONL parsing (only LF delimiters)
/// - Typed events via [events] stream
/// - Request/response correlation with timeouts
/// - Extension UI request handling via [uiRequests] stream
/// - Graceful process lifecycle management
class PiRpcClient {
  Process? _process;
  int _reqId = 0;
  bool _disposed = false;
  String _cwd = Directory.current.path;

  _JsonlReader? _stdoutReader;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;

  String get cwd => _cwd;
  bool get isRunning => _process != null;

  // ── Streams ────────────────────────────────────────────────────────────────

  final _eventController = StreamController<AgentEvent>.broadcast();
  Stream<AgentEvent> get events => _eventController.stream;

  final _responseController = StreamController<RpcResponse>.broadcast();
  Stream<RpcResponse> get responses => _responseController.stream;

  /// Extension UI requests that require user interaction.
  final _uiRequestController = StreamController<ExtensionUiRequest>.broadcast();
  Stream<ExtensionUiRequest> get uiRequests => _uiRequestController.stream;

  /// Fire-and-forget UI notifications (notify, setStatus, setWidget, setTitle).
  final _uiNotifyController = StreamController<ExtensionUiRequest>.broadcast();
  Stream<ExtensionUiRequest> get uiNotifications => _uiNotifyController.stream;

  // ── Lifecycle ────────────────────────────────────────────────────────────

  void updateCwd(String path) {
    _cwd = path;
  }

  Future<void> start({String? workingDirectory}) async {
    _cwd = workingDirectory ?? Directory.current.path;
    await _spawn();
  }

  Future<void> _spawn() async {
    // Per the RPC spec, session management is done via RPC commands
    // (new_session, switch_session), not CLI flags.
    final args = ['--mode', 'rpc', '--no-session'];

    _process = await Process.start(
      'pi',
      args,
      workingDirectory: _cwd,
      mode: ProcessStartMode.normal,
    );

    _stdoutReader = _JsonlReader(_process!.stdout);
    _stdoutSub = _stdoutReader!.lines.listen(
      _onStdoutLine,
      onError: (e) => debugPrint('[pi stdout error] $e'),
    );

    _stderrSub = _process!.stderr
        .transform(utf8.decoder)
        .listen(
          (data) => debugPrint('[pi stderr] $data'),
          onError: (e) => debugPrint('[pi stderr error] $e'),
        );

    _process!.exitCode.then((code) {
      if (!_disposed) {
        _eventController.add(ProcessExitEvent());
      }
    });
  }

  void _onStdoutLine(String line) {
    if (_disposed) return;
    try {
      final json = jsonDecode(line) as Map<String, dynamic>;
      final type = json['type'] as String?;

      if (type == 'response') {
        _responseController.add(RpcResponse.fromJson(json));
      } else if (type == 'extension_ui_request') {
        final req = ExtensionUiRequest.fromJson(json);
        if (req is SelectRequest ||
            req is ConfirmRequest ||
            req is InputRequest ||
            req is EditorRequest) {
          _uiRequestController.add(req);
        } else {
          _uiNotifyController.add(req);
        }
        // Also emit as a regular event for listeners that want everything
        _eventController.add(ExtensionUiRequestEvent(request: req));
      } else {
        _eventController.add(AgentEvent.fromJson(json));
      }
    } catch (e, st) {
      debugPrint('[pi parse error] $e\n$st\nLine: $line');
    }
  }

  /// Restart the pi process with a new working directory.
  Future<void> restart(String workingDirectory) async {
    _cwd = workingDirectory;
    await _cleanupProcess();
    await _spawn();
    _eventController.add(ProcessRestartEvent());
  }

  /// Send a `new_session` command instead of restarting the process.
  /// Prefer this over [restart] when only the session needs to change.
  Future<RpcResponse?> newSession({String? parentSession}) async {
    final cmd = <String, dynamic>{'type': 'new_session'};
    if (parentSession != null) cmd['parentSession'] = parentSession;
    return request(cmd);
  }

  Future<void> _cleanupProcess() async {
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    await _stdoutReader?.dispose();
    _stdoutSub = null;
    _stderrSub = null;
    _stdoutReader = null;
    _process?.kill();
    _process = null;
  }

  // ── Commands ───────────────────────────────────────────────────────────────

  /// Fire-and-forget command. Returns the generated request id.
  String send(Map<String, dynamic> command) {
    final id = 'req-${_reqId++}';
    command['id'] = id;
    final line = '${jsonEncode(command)}\n';
    _process?.stdin.write(line);
    _process?.stdin.flush();
    return id;
  }

  /// Send a command and wait for the matching response.
  Future<RpcResponse?> request(
    Map<String, dynamic> command, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final id = send(command);
    final completer = Completer<RpcResponse?>();
    late StreamSubscription<RpcResponse> sub;
    sub = responses.listen((response) {
      if (response.id == id) {
        completer.complete(response);
        sub.cancel();
      }
    });
    Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.complete(null);
        sub.cancel();
      }
    });
    return completer.future;
  }

  /// Respond to an extension UI request.
  void sendUiResponse(ExtensionUiResponse response) {
    final line = '${jsonEncode(response.toJson())}\n';
    _process?.stdin.write(line);
    _process?.stdin.flush();
  }

  // ── Convenience commands ───────────────────────────────────────────────────

  void abort() => send({'type': 'abort'});
  void abortBash() => send({'type': 'abort_bash'});
  void abortRetry() => send({'type': 'abort_retry'});

  Future<RpcResponse?> setModel(String provider, String modelId) =>
      request({'type': 'set_model', 'provider': provider, 'modelId': modelId});

  Future<RpcResponse?> cycleModel() => request({'type': 'cycle_model'});

  Future<RpcResponse?> getAvailableModels() =>
      request({'type': 'get_available_models'});

  Future<RpcResponse?> getState() => request({'type': 'get_state'});

  Future<RpcResponse?> getMessages() => request({'type': 'get_messages'});

  Future<RpcResponse?> setThinkingLevel(String level) =>
      request({'type': 'set_thinking_level', 'level': level});

  Future<RpcResponse?> cycleThinkingLevel() =>
      request({'type': 'cycle_thinking_level'});

  Future<RpcResponse?> setSteeringMode(String mode) =>
      request({'type': 'set_steering_mode', 'mode': mode});

  Future<RpcResponse?> setFollowUpMode(String mode) =>
      request({'type': 'set_follow_up_mode', 'mode': mode});

  Future<RpcResponse?> compact({String? customInstructions}) {
    final cmd = <String, dynamic>{'type': 'compact'};
    if (customInstructions != null) {
      cmd['customInstructions'] = customInstructions;
    }
    return request(cmd);
  }

  Future<RpcResponse?> setAutoCompaction(bool enabled) =>
      request({'type': 'set_auto_compaction', 'enabled': enabled});

  Future<RpcResponse?> setAutoRetry(bool enabled) =>
      request({'type': 'set_auto_retry', 'enabled': enabled});

  Future<RpcResponse?> bash(String command) =>
      request({'type': 'bash', 'command': command});

  Future<RpcResponse?> getSessionStats() =>
      request({'type': 'get_session_stats'});

  Future<RpcResponse?> exportHtml({String? outputPath}) {
    final cmd = <String, dynamic>{'type': 'export_html'};
    if (outputPath != null) cmd['outputPath'] = outputPath;
    return request(cmd);
  }

  Future<RpcResponse?> switchSession(String sessionPath) =>
      request({'type': 'switch_session', 'sessionPath': sessionPath});

  Future<RpcResponse?> fork(String entryId) =>
      request({'type': 'fork', 'entryId': entryId});

  Future<RpcResponse?> clone() => request({'type': 'clone'});

  Future<RpcResponse?> getForkMessages() =>
      request({'type': 'get_fork_messages'});

  Future<RpcResponse?> getLastAssistantText() =>
      request({'type': 'get_last_assistant_text'});

  Future<RpcResponse?> setSessionName(String name) =>
      request({'type': 'set_session_name', 'name': name});

  Future<RpcResponse?> getCommands() => request({'type': 'get_commands'});

  /// Send a prompt with optional images.
  void prompt(
    String message, {
    List<ImageContent>? images,
    String? streamingBehavior,
  }) {
    final cmd = <String, dynamic>{
      'type': 'prompt',
      'message': message,
    };
    if (images != null && images.isNotEmpty) {
      cmd['images'] = images.map((i) => i.toJson()).toList();
    }
    if (streamingBehavior != null) {
      cmd['streamingBehavior'] = streamingBehavior;
    }
    send(cmd);
  }

  /// Send a steering message.
  void steer(String message, {List<ImageContent>? images}) {
    final cmd = <String, dynamic>{'type': 'steer', 'message': message};
    if (images != null && images.isNotEmpty) {
      cmd['images'] = images.map((i) => i.toJson()).toList();
    }
    send(cmd);
  }

  /// Send a follow-up message.
  void followUp(String message, {List<ImageContent>? images}) {
    final cmd = <String, dynamic>{'type': 'follow_up', 'message': message};
    if (images != null && images.isNotEmpty) {
      cmd['images'] = images.map((i) => i.toJson()).toList();
    }
    send(cmd);
  }

  // ── Dispose ──────────────────────────────────────────────────────────────

  Future<void> dispose() async {
    _disposed = true;
    await _cleanupProcess();
    await _eventController.close();
    await _responseController.close();
    await _uiRequestController.close();
    await _uiNotifyController.close();
  }
}
