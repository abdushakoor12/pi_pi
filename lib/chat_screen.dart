import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'chat_message.dart';
import 'pi_rpc_client.dart';
import 'session_manager.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late final PiRpcClient _client;
  final List<ChatMessage> _messages = [];
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  bool _ready = false;
  bool _agentRunning = false;
  int? _streamingIndex;

  List<Map<String, dynamic>> _models = [];
  Map<String, dynamic>? _currentModel;
  String _currentThinkingLevel = '';

  @override
  void initState() {
    super.initState();
    _client = PiRpcClient();
    _initClient();
  }

  Future<void> _initClient() async {
    await _client.start();
    _client.events.listen(_handleEvent);
    await _fetchModelsAndState();
    setState(() => _ready = true);
  }

  Future<void> _fetchModelsAndState() async {
    final modelsRes = await _client.request({'type': 'get_available_models'});
    final stateRes = await _client.request({'type': 'get_state'});
    setState(() {
      if (modelsRes?['success'] == true) {
        _models = List<Map<String, dynamic>>.from(
            modelsRes!['data']['models'] ?? []);
      }
      if (stateRes?['success'] == true) {
        _currentModel = stateRes!['data']['model'] as Map<String, dynamic>?;
        _currentThinkingLevel =
            stateRes['data']['thinkingLevel'] as String? ?? '';
      }
    });
  }

  Future<void> _changeDirectory() async {
    final newDir = await showDialog<String>(
      context: context,
      builder: (_) => _DirectoryDialog(initialPath: _client.cwd),
    );

    if (newDir == null || newDir.trim().isEmpty) return;
    final dir = Directory(newDir.trim());
    if (!await dir.exists()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Directory does not exist')),
        );
      }
      return;
    }

    setState(() => _ready = false);
    await _client.restart(dir.path);
    await _fetchModelsAndState();
    setState(() => _ready = true);
  }

  Future<void> _selectModel(Map<String, dynamic> model) async {
    final res = await _client.request({
      'type': 'set_model',
      'provider': model['provider'],
      'modelId': model['id'],
    });
    if (res?['success'] == true && res!['data'] != null) {
      setState(() => _currentModel = res['data'] as Map<String, dynamic>);
    }
  }

  Future<void> _showHistory() async {
    final sessions = await SessionManager.listSessions(_client.cwd);
    if (!mounted) return;

    if (sessions.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No previous sessions in this directory')),
      );
      return;
    }

    final chosen = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => _HistorySheet(sessions: sessions),
    );

    if (chosen != null) {
      await _loadSession(chosen);
    }
  }

  Future<void> _loadSession(String path) async {
    setState(() => _ready = false);
    _messages.clear();

    // 1. Parse the session file locally and display messages
    final raw = await SessionManager.loadMessages(path);
    _convertAndShow(raw);

    // 2. Restart pi attached to this session so future prompts continue from it
    await _client.restart(_client.cwd, sessionPath: path);
    await _fetchModelsAndState();

    setState(() => _ready = true);
  }

  void _convertAndShow(List<Map<String, dynamic>> rawMessages) {
    final converted = <ChatMessage>[];
    for (final entry in rawMessages) {
      final msg = entry['message'] as Map<String, dynamic>?;
      if (msg == null) continue;
      final role = msg['role'] as String?;
      final content = msg['content'];

      if (role == 'user') {
        String text = '';
        if (content is List) {
          for (final block in content) {
            if (block is Map && block['type'] == 'text') {
              text += block['text'] as String? ?? '';
            }
          }
        } else if (content is String) {
          text = content;
        }
        converted.add(ChatMessage(role: MessageRole.user, text: text));
      } else if (role == 'assistant') {
        String text = '';
        String? thinking;
        if (content is List) {
          for (final block in content) {
            if (block is Map) {
              if (block['type'] == 'text') {
                text += block['text'] as String? ?? '';
              } else if (block['type'] == 'thinking') {
                thinking = (thinking ?? '') + (block['thinking'] as String? ?? '');
              }
            }
          }
        }
        converted.add(ChatMessage(
          role: MessageRole.assistant,
          text: text,
          thinking: thinking,
        ));
      } else if (role == 'toolResult') {
        final toolName = msg['toolName'] as String? ?? '';
        final isError = msg['isError'] as bool? ?? false;
        String resultText = '';
        if (content is List && content.isNotEmpty) {
          resultText = (content.first as Map)['text'] as String? ?? '';
        }
        final tc = ToolCall(
          id: msg['toolCallId'] as String? ?? '',
          name: toolName,
          result: resultText,
          isError: isError,
          running: false,
        );
        // Attach to last assistant message
        if (converted.isNotEmpty &&
            converted.last.role == MessageRole.assistant) {
          converted.last = converted.last.copyWith(
            toolCalls: [...converted.last.toolCalls, tc],
          );
        }
      }
    }
    setState(() => _messages.addAll(converted));
  }

  void _handleEvent(Map<String, dynamic> event) {
    final type = event['type'] as String?;

    switch (type) {
      case 'agent_start':
        setState(() => _agentRunning = true);
      case 'agent_end':
        setState(() {
          _agentRunning = false;
          _finalizeStreaming();
        });
      case 'message_start':
        final role = (event['message'] as Map<String, dynamic>?)?['role'] as String?;
        if (role == 'assistant') {
          setState(() {
            _streamingIndex = _messages.length;
            _messages.add(const ChatMessage(
              role: MessageRole.assistant,
              isStreaming: true,
            ));
          });
        }
      case 'message_update':
        _handleStreamingDelta(event['assistantMessageEvent'] as Map<String, dynamic>?);
      case 'tool_execution_start':
        _handleToolStart(event);
      case 'tool_execution_update':
        _handleToolUpdate(event);
      case 'tool_execution_end':
        _handleToolEnd(event);
      case 'turn_end':
        _finalizeStreaming();
      case 'process_exit':
        setState(() => _ready = false);
    }
    _scrollToBottom();
  }

  void _handleStreamingDelta(Map<String, dynamic>? delta) {
    if (_streamingIndex == null || delta == null) return;
    final type = delta['type'] as String?;
    switch (type) {
      case 'text_delta':
        final text = (delta['delta'] as String?) ?? '';
        setState(() {
          _messages[_streamingIndex!] =
              _messages[_streamingIndex!].copyWith(
                  text: _messages[_streamingIndex!].text + text);
        });
      case 'thinking_delta':
        final thinking = (delta['delta'] as String?) ?? '';
        setState(() {
          _messages[_streamingIndex!] = _messages[_streamingIndex!].copyWith(
              thinking: (_messages[_streamingIndex!].thinking ?? '') + thinking);
        });
      case 'toolcall_start':
        final toolCall =
            (delta['partial'] as Map<String, dynamic>?)?['toolCall'] as Map<String, dynamic>?;
        if (toolCall != null) {
          setState(() {
            _messages[_streamingIndex!] = _messages[_streamingIndex!].copyWith(
              toolCalls: [
                ..._messages[_streamingIndex!].toolCalls,
                ToolCall(
                  id: toolCall['id'] ?? '',
                  name: toolCall['name'] ?? '',
                  args: jsonEncode(toolCall['arguments'] ?? {}),
                  running: true,
                ),
              ],
            );
          });
        }
      case 'toolcall_end':
        final toolCall =
            (delta['partial'] as Map<String, dynamic>?)?['toolCall'] as Map<String, dynamic>?;
        if (toolCall != null) {
          final id = toolCall['id'] as String? ?? '';
          _updateToolCall(
              id, (tc) => tc.copyWith(args: jsonEncode(toolCall['arguments'] ?? {})));
        }
    }
  }

  void _handleToolStart(Map<String, dynamic> event) {
    final id = event['toolCallId'] as String?;
    if (id != null) _updateToolCall(id, (tc) => tc.copyWith(running: true));
  }

  void _handleToolUpdate(Map<String, dynamic> event) {
    final id = event['toolCallId'] as String?;
    final content = (event['partialResult'] as Map<String, dynamic>?)?['content'] as List?;
    final text = content?.isNotEmpty == true
        ? (content!.first as Map)['text'] ?? ''
        : '';
    if (id != null) {
      _updateToolCall(id, (tc) => tc.copyWith(result: text, running: true));
    }
  }

  void _handleToolEnd(Map<String, dynamic> event) {
    final id = event['toolCallId'] as String?;
    final content = (event['result'] as Map<String, dynamic>?)?['content'] as List?;
    final text = content?.isNotEmpty == true
        ? (content!.first as Map)['text'] ?? ''
        : '';
    final isError = event['isError'] as bool? ?? false;
    if (id != null) {
      _updateToolCall(
          id, (tc) => tc.copyWith(result: text.toString(), isError: isError, running: false));
    }
  }

  void _updateToolCall(String id, ToolCall Function(ToolCall) fn) {
    if (_streamingIndex == null) return;
    setState(() {
      final updated = _messages[_streamingIndex!].toolCalls.map((tc) {
        return tc.id == id ? fn(tc) : tc;
      }).toList();
      _messages[_streamingIndex!] =
          _messages[_streamingIndex!].copyWith(toolCalls: updated);
    });
  }

  void _finalizeStreaming() {
    if (_streamingIndex != null) {
      _messages[_streamingIndex!] =
          _messages[_streamingIndex!].copyWith(isStreaming: false);
      _streamingIndex = null;
    }
  }

  void _sendMessage(String text) {
    if (text.trim().isEmpty) return;
    setState(() {
      _messages.add(ChatMessage(role: MessageRole.user, text: text));
    });
    _client.send({'type': 'prompt', 'message': text});
    _textController.clear();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _client.dispose();
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final modelLabel = _currentModel != null
        ? '${_currentModel!['name'] ?? _currentModel!['id']}'
            '${_currentThinkingLevel.isNotEmpty ? ' ($_currentThinkingLevel)' : ''}'
        : (_ready ? 'No model' : 'Loading...');

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.folder_open),
          tooltip: _client.cwd,
          onPressed: _changeDirectory,
        ),
        title: const Text('Pi Pi'),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'Session history',
            onPressed: _ready ? _showHistory : null,
          ),
          if (_models.isNotEmpty)
            PopupMenuButton<Map<String, dynamic>>(
              tooltip: 'Select model',
              icon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(modelLabel,
                      style: const TextStyle(fontSize: 12)),
                  const SizedBox(width: 4),
                  const Icon(Icons.arrow_drop_down),
                ],
              ),
              onSelected: _selectModel,
              itemBuilder: (context) => _models.map((m) {
                final isSelected = _currentModel != null &&
                    m['provider'] == _currentModel!['provider'] &&
                    m['id'] == _currentModel!['id'];
                return PopupMenuItem<Map<String, dynamic>>(
                  value: m,
                  child: Row(
                    children: [
                      Icon(
                        isSelected ? Icons.check_circle : Icons.circle_outlined,
                        size: 16,
                        color: isSelected ? Colors.greenAccent : Colors.grey,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          m['name'] as String? ?? m['id'] as String? ?? '',
                          style: TextStyle(
                            fontWeight:
                                isSelected ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                      ),
                      Text(
                        m['provider'] as String? ?? '',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey.shade500,
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          if (_agentRunning)
            const Padding(
              padding: EdgeInsets.only(right: 12),
              child: Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white70,
                  ),
                ),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? const Center(
                    child: Text(
                      'Send a message to start chatting with pi',
                      style: TextStyle(color: Colors.white54),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      return _MessageBubble(
                        message: _messages[index],
                        isLast: index == _messages.length - 1,
                      );
                    },
                  ),
          ),
          const Divider(height: 1),
          _InputBar(
            controller: _textController,
            onSend: _sendMessage,
            enabled: _ready && !_agentRunning,
          ),
        ],
      ),
    );
  }
}

// ─── Message Bubble ──────────────────────────────────────────────────────────

class _MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final bool isLast;
  const _MessageBubble({required this.message, required this.isLast});

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == MessageRole.user;
    final alignment = isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final color = isUser
        ? Theme.of(context).colorScheme.primaryContainer
        : Theme.of(context).colorScheme.surfaceContainerHighest;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: alignment,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              isUser ? 'You' : 'pi',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
          if (message.thinking != null && message.thinking!.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.grey.shade900,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey.shade700),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('💭 Thinking',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: Colors.grey)),
                  const SizedBox(height: 4),
                  Text(message.thinking!,
                      style: const TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                          fontStyle: FontStyle.italic)),
                ],
              ),
            ),
          if (message.text.isNotEmpty || message.role == MessageRole.assistant)
            Container(
              constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.85),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(16).copyWith(
                  bottomRight: isUser ? const Radius.circular(4) : null,
                  bottomLeft: isUser ? null : const Radius.circular(4),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  SelectionArea(
                    child: Text(
                      message.text.isEmpty
                          ? (message.isStreaming ? '...' : '')
                          : message.text,
                      style: const TextStyle(fontSize: 14, height: 1.4),
                    ),
                  ),
                  if (message.isStreaming)
                    const Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 1.5)),
                    ),
                ],
              ),
            ),
          if (message.toolCalls.isNotEmpty)
            ...message.toolCalls.map((tc) => _ToolCallWidget(toolCall: tc)),
        ],
      ),
    );
  }
}

// ─── Tool Call Widget ────────────────────────────────────────────────────────

class _ToolCallWidget extends StatelessWidget {
  final ToolCall toolCall;
  const _ToolCallWidget({required this.toolCall});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.blueGrey.shade900,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.blueGrey.shade700),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.terminal,
                  size: 14,
                  color: toolCall.running ? Colors.orange : Colors.green),
              const SizedBox(width: 6),
              Text(toolCall.name,
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      fontFamily: 'monospace')),
              if (toolCall.running) ...[
                const SizedBox(width: 6),
                const SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(strokeWidth: 1.5)),
              ],
            ],
          ),
          if (toolCall.args.isNotEmpty && toolCall.args != '{}')
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                toolCall.args,
                style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey.shade400,
                    fontFamily: 'monospace'),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          if (toolCall.result != null)
            Container(
              margin: const EdgeInsets.only(top: 6),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(6)),
              child: Text(
                toolCall.result!,
                style: TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: toolCall.isError
                        ? Colors.red.shade300
                        : Colors.green.shade300),
                maxLines: 10,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }
}

// ─── Input Bar ───────────────────────────────────────────────────────────────

class _InputBar extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onSend;
  final bool enabled;

  const _InputBar({
    required this.controller,
    required this.onSend,
    required this.enabled,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 12),
      color: Theme.of(context).colorScheme.surface,
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              enabled: enabled,
              onSubmitted: onSend,
              style: const TextStyle(fontSize: 14),
              decoration: InputDecoration(
                hintText: enabled ? 'Ask pi something...' : 'Please wait...',
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                filled: true,
                fillColor:
                    Theme.of(context).colorScheme.surfaceContainerHighest,
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            onPressed: enabled ? () => onSend(controller.text) : null,
            icon: const Icon(Icons.send),
          ),
        ],
      ),
    );
  }
}

// ─── Directory Dialog ────────────────────────────────────────────────────────

class _DirectoryDialog extends StatefulWidget {
  final String initialPath;
  const _DirectoryDialog({required this.initialPath});

  @override
  State<_DirectoryDialog> createState() => _DirectoryDialogState();
}

class _DirectoryDialogState extends State<_DirectoryDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialPath);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Working Directory'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(
          hintText: '/path/to/project',
          border: OutlineInputBorder(),
        ),
        onSubmitted: (v) => Navigator.of(context).pop(v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('Restart'),
        ),
      ],
    );
  }
}

// ─── History Sheet ───────────────────────────────────────────────────────────

class _HistorySheet extends StatelessWidget {
  final List<SessionSummary> sessions;
  const _HistorySheet({required this.sessions});

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade600,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                const Text('Session History',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const Spacer(),
                Text('${sessions.length} sessions',
                    style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
              ],
            ),
          ),
          const Divider(),
          Expanded(
            child: ListView.separated(
              controller: scrollController,
              itemCount: sessions.length,
              separatorBuilder: (context, index) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final s = sessions[index];
                final date = _formatDate(s.timestamp);
                return ListTile(
                  leading: const Icon(Icons.chat_bubble_outline, size: 20),
                  title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(date, style: const TextStyle(fontSize: 12)),
                  onTap: () => Navigator.of(context).pop(s.path),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(String iso) {
    try {
      final dt = DateTime.parse(iso).toLocal();
      final now = DateTime.now();
      if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
        return 'Today ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
      }
      return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
          '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return iso;
    }
  }
}
