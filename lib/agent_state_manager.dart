import 'dart:async';

import 'package:flutter/material.dart';

import 'models.dart';
import 'pi_rpc_client.dart';

/// Reactive manager that synchronises the Flutter UI with the pi agent's state.
///
/// Listens to [PiRpcClient.events] and exposes:
/// - [agentState] — last known agent state (model, session, flags)
/// - [isStreaming], [isCompacting], [isRetrying] — activity flags
/// - [steeringQueue], [followUpQueue] — pending queued messages
/// - [sessionStats] — token usage / cost
/// - [extensionUiRequest] — active dialog request from an extension
/// - [statuses] — fire-and-forget status entries from extensions
/// - [widgets] — fire-and-forget widget lines from extensions
class AgentStateManager extends ChangeNotifier {
  final PiRpcClient client;
  late final StreamSubscription<AgentEvent> _eventSub;
  late final StreamSubscription<ExtensionUiRequest> _uiSub;
  late final StreamSubscription<ExtensionUiRequest> _notifySub;

  AgentState? _agentState;
  bool _isStreaming = false;
  bool _isCompacting = false;
  bool _isRetrying = false;
  List<String> _steeringQueue = [];
  List<String> _followUpQueue = [];
  SessionStats? _sessionStats;
  ExtensionUiRequest? _extensionUiRequest;
  final Map<String, String> _statuses = {};
  final Map<String, WidgetEntry> _widgets = {};
  String? _windowTitle;
  String? _editorText;

  // Compaction / retry transient state
  String? _compactionReason;
  AutoRetryStartEvent? _currentRetry;

  AgentStateManager({required this.client}) {
    _eventSub = client.events.listen(_onEvent);
    _uiSub = client.uiRequests.listen(_onUiRequest);
    _notifySub = client.uiNotifications.listen(_onUiNotification);
  }

  // ── Getters ────────────────────────────────────────────────────────────────

  AgentState? get agentState => _agentState;
  bool get isStreaming => _isStreaming;
  bool get isCompacting => _isCompacting;
  bool get isRetrying => _isRetrying;
  List<String> get steeringQueue => List.unmodifiable(_steeringQueue);
  List<String> get followUpQueue => List.unmodifiable(_followUpQueue);
  SessionStats? get sessionStats => _sessionStats;
  ExtensionUiRequest? get extensionUiRequest => _extensionUiRequest;
  Map<String, String> get statuses => Map.unmodifiable(_statuses);
  Map<String, WidgetEntry> get widgets => Map.unmodifiable(_widgets);
  String? get windowTitle => _windowTitle;
  String? get editorText => _editorText;
  String? get compactionReason => _compactionReason;
  AutoRetryStartEvent? get currentRetry => _currentRetry;

  /// Combined busy flag — true while agent is doing anything.
  bool get isBusy => _isStreaming || _isCompacting || _isRetrying;

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Fetch fresh state from the agent.
  Future<void> refreshState() async {
    final res = await client.getState();
    if (res?.success == true && res?.data != null) {
      _agentState = AgentState.fromJson(res!.data!);
      _isStreaming = _agentState?.isStreaming ?? false;
      notifyListeners();
    }
  }

  /// Fetch session stats from the agent.
  Future<void> refreshStats() async {
    final res = await client.getSessionStats();
    if (res?.success == true && res?.data != null) {
      _sessionStats = SessionStats.fromJson(res!.data!);
      notifyListeners();
    }
  }

  /// Respond to the current extension UI request.
  void respondToUiRequest(ExtensionUiResponse response) {
    client.sendUiResponse(response);
    _extensionUiRequest = null;
    notifyListeners();
  }

  /// Dismiss the current extension UI request (cancel).
  void dismissUiRequest() {
    if (_extensionUiRequest == null) return;
    final id = _extensionUiRequest!.id;
    client.sendUiResponse(ExtensionUiResponse(id: id, cancelled: true));
    _extensionUiRequest = null;
    notifyListeners();
  }

  // ── Event handling ─────────────────────────────────────────────────────────

  void _onEvent(AgentEvent event) {
    switch (event) {
      case AgentStartEvent _:
        _isStreaming = true;
        notifyListeners();
      case AgentEndEvent _:
        _isStreaming = false;
        notifyListeners();
      case TurnStartEvent _:
        // no-op
        break;
      case TurnEndEvent _:
        // no-op
        break;
      case MessageStartEvent _:
        _isStreaming = true;
        notifyListeners();
      case MessageUpdateEvent _:
        // no-op
        break;
      case MessageEndEvent msg:
        if (msg.message is AssistantMessage) {
          final am = msg.message as AssistantMessage;
          if (am.stopReason != null &&
              am.stopReason != 'toolUse' &&
              am.stopReason != 'length') {
            _isStreaming = false;
          }
        }
        notifyListeners();
      case ToolExecutionStartEvent _:
        // no-op
        break;
      case ToolExecutionUpdateEvent _:
        // no-op
        break;
      case ToolExecutionEndEvent _:
        // no-op
        break;
      case QueueUpdateEvent q:
        _steeringQueue = q.steering;
        _followUpQueue = q.followUp;
        notifyListeners();
      case CompactionStartEvent c:
        _isCompacting = true;
        _compactionReason = c.reason;
        notifyListeners();
      case CompactionEndEvent c:
        _isCompacting = false;
        _compactionReason = null;
        if (c.willRetry) {
          // Agent will auto-retry after compaction
        }
        notifyListeners();
      case AutoRetryStartEvent r:
        _isRetrying = true;
        _currentRetry = r;
        notifyListeners();
      case AutoRetryEndEvent _:
        _isRetrying = false;
        _currentRetry = null;
        notifyListeners();
      case ExtensionErrorEvent _:
        // Keep in state? For now just let listeners know
        notifyListeners();
      case ExtensionUiRequestEvent _:
        // handled by _uiSub / _notifySub
        break;
      case ProcessExitEvent _:
        _isStreaming = false;
        _isCompacting = false;
        _isRetrying = false;
        notifyListeners();
      case ProcessRestartEvent _:
        _isStreaming = false;
        _isCompacting = false;
        _isRetrying = false;
        _steeringQueue = [];
        _followUpQueue = [];
        notifyListeners();
      case UnknownEvent _:
        // no-op
        break;
    }
  }

  void _onUiRequest(ExtensionUiRequest req) {
    _extensionUiRequest = req;
    notifyListeners();
  }

  void _onUiNotification(ExtensionUiRequest req) {
    switch (req) {
      case SetStatusRequest s:
        if (s.statusText == null || s.statusText!.isEmpty) {
          _statuses.remove(s.statusKey);
        } else {
          _statuses[s.statusKey] = s.statusText!;
        }
        notifyListeners();
      case SetWidgetRequest w:
        if (w.widgetLines == null || w.widgetLines!.isEmpty) {
          _widgets.remove(w.widgetKey);
        } else {
          _widgets[w.widgetKey] = WidgetEntry(
            lines: w.widgetLines!,
            placement: w.widgetPlacement,
          );
        }
        notifyListeners();
      case SetTitleRequest t:
        _windowTitle = t.title;
        notifyListeners();
      case SetEditorTextRequest e:
        _editorText = e.text;
        notifyListeners();
      case NotifyRequest _:
        // Handled by UI layer via uiNotifications stream directly
        break;
      default:
        break;
    }
  }

  @override
  void dispose() {
    _eventSub.cancel();
    _uiSub.cancel();
    _notifySub.cancel();
    super.dispose();
  }
}

class WidgetEntry {
  final List<String> lines;
  final String placement;

  const WidgetEntry({required this.lines, required this.placement});
}
