import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import 'chat_message.dart';
import 'session_manager.dart';

/// The main chat content widget — messages list + input bar.
///
/// Designed to be embedded inside a shell layout (ShellScreen) rather than
/// appearing as a standalone Scaffold. Use a GlobalKey<ChatContentState> to
/// call [reset] and [loadSession].
class ChatContent extends StatefulWidget {
  /// The RPC client to send/receive messages.
  final dynamic client;

  const ChatContent({super.key, required this.client});

  @override
  State<ChatContent> createState() => ChatContentState();
}

class ChatContentState extends State<ChatContent> {
  final List<ChatMessage> _messages = [];
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  bool _agentRunning = false;
  int? _streamingIndex;

  /// Whether there are any messages in the current conversation.
  bool get hasMessages => _messages.isNotEmpty;

  @override
  void initState() {
    super.initState();
    widget.client.events.listen(_handleEvent);
    // Also listen for restart to clear messages
  }

  /// Clear all messages (start a new conversation).
  void reset() {
    setState(() {
      _messages.clear();
      _streamingIndex = null;
      _agentRunning = false;
    });
  }

  /// Load messages from a session file.
  Future<void> loadSession(String sessionPath) async {
    setState(() => _messages.clear());
    final raw = await SessionManager.loadMessages(sessionPath);
    _convertAndShow(raw);
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
                thinking =
                    (thinking ?? '') + (block['thinking'] as String? ?? '');
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

  // ── Event handling ─────────────────────────────────────────────────────

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
        final role =
            (event['message'] as Map<String, dynamic>?)?['role'] as String?;
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
        _handleStreamingDelta(
            event['assistantMessageEvent'] as Map<String, dynamic>?);
      case 'tool_execution_start':
        _handleToolStart(event);
      case 'tool_execution_update':
        _handleToolUpdate(event);
      case 'tool_execution_end':
        _handleToolEnd(event);
      case 'turn_end':
        _finalizeStreaming();
      case 'process_restart':
        setState(() => _messages.clear());
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
              thinking:
                  (_messages[_streamingIndex!].thinking ?? '') + thinking);
        });
      case 'toolcall_start':
        final toolCall = (delta['partial'] as Map<String, dynamic>?)
                ?['toolCall'] as Map<String, dynamic>?;
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
        final toolCall = (delta['partial'] as Map<String, dynamic>?)
                ?['toolCall'] as Map<String, dynamic>?;
        if (toolCall != null) {
          final id = toolCall['id'] as String? ?? '';
          _updateToolCall(id,
              (tc) => tc.copyWith(args: jsonEncode(toolCall['arguments'] ?? {})));
        }
    }
  }

  void _handleToolStart(Map<String, dynamic> event) {
    final id = event['toolCallId'] as String?;
    if (id != null) _updateToolCall(id, (tc) => tc.copyWith(running: true));
  }

  void _handleToolUpdate(Map<String, dynamic> event) {
    final id = event['toolCallId'] as String?;
    final content =
        (event['partialResult'] as Map<String, dynamic>?)?['content'] as List?;
    final text = content?.isNotEmpty == true
        ? (content!.first as Map)['text'] ?? ''
        : '';
    if (id != null) {
      _updateToolCall(id, (tc) => tc.copyWith(result: text, running: true));
    }
  }

  void _handleToolEnd(Map<String, dynamic> event) {
    final id = event['toolCallId'] as String?;
    final content =
        (event['result'] as Map<String, dynamic>?)?['content'] as List?;
    final text = content?.isNotEmpty == true
        ? (content!.first as Map)['text'] ?? ''
        : '';
    final isError = event['isError'] as bool? ?? false;
    if (id != null) {
      _updateToolCall(id,
          (tc) => tc.copyWith(result: text.toString(), isError: isError, running: false));
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
    widget.client.send({'type': 'prompt', 'message': text});
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
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Column(
      children: [
        Expanded(
          child: _messages.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.chat_bubble_outline,
                          size: 48,
                          color: cs.primary.withValues(alpha: 0.2)),
                      const SizedBox(height: 16),
                      Text(
                        'Send a message to start chatting with pi',
                        style: TextStyle(
                          fontSize: 14,
                          color: cs.onSurface.withValues(alpha: 0.4),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Use the sidebar to switch projects or browse history',
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurface.withValues(alpha: 0.25),
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 24, vertical: 16),
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
          enabled: !_agentRunning,
        ),
      ],
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
                color: Theme.of(context).brightness == Brightness.dark
                    ? Colors.grey.shade900
                    : Colors.grey.shade100,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Theme.of(context).brightness == Brightness.dark
                      ? Colors.grey.shade700
                      : Colors.grey.shade300,
                ),
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
                  maxWidth: MediaQuery.of(context).size.width * 0.8),
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
                    child: message.text.isEmpty
                        ? Text(
                            message.isStreaming ? '...' : '',
                            style: const TextStyle(fontSize: 14, height: 1.4),
                          )
                        : MarkdownBody(
                            data: message.text,
                            styleSheet: MarkdownStyleSheet(
                              p: const TextStyle(fontSize: 14, height: 1.4),
                              h1: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: Theme.of(context).colorScheme.onSurface,
                                height: 1.3,
                              ),
                              h2: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.bold,
                                color: Theme.of(context).colorScheme.onSurface,
                                height: 1.3,
                              ),
                              h3: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                                color: Theme.of(context).colorScheme.onSurface,
                                height: 1.3,
                              ),
                              code: TextStyle(
                                fontSize: 13,
                                fontFamily: 'monospace',
                                color:
                                    Theme.of(context).brightness == Brightness.dark
                                        ? const Color(0xFFE6DB74)
                                        : const Color(0xFF4A4A4A),
                                backgroundColor: Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest,
                              ),
                              codeblockDecoration: BoxDecoration(
                                color:
                                    Theme.of(context).brightness == Brightness.dark
                                        ? Colors.grey.shade900
                                        : Colors.grey.shade100,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: Theme.of(context).brightness == Brightness.dark
                                      ? Colors.grey.shade700
                                      : Colors.grey.shade300,
                                ),
                              ),
                              blockquoteDecoration: BoxDecoration(
                                border: Border(
                                  left: BorderSide(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .primary
                                        .withValues(alpha: 0.4),
                                    width: 3,
                                  ),
                                ),
                              ),
                              blockquote: TextStyle(
                                fontStyle: FontStyle.italic,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurface
                                    .withValues(alpha: 0.7),
                              ),
                              listBullet: TextStyle(
                                fontSize: 14,
                                color: Theme.of(context).colorScheme.onSurface,
                              ),
                              horizontalRuleDecoration: BoxDecoration(
                                border: Border(
                                  top: BorderSide(
                                    width: 1,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .outlineVariant,
                                  ),
                                ),
                              ),
                              strong: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Theme.of(context).colorScheme.onSurface,
                              ),
                              em: const TextStyle(fontStyle: FontStyle.italic),
                              a: TextStyle(
                                color: Theme.of(context).colorScheme.primary,
                                decoration: TextDecoration.underline,
                              ),
                              del: TextStyle(
                                decoration: TextDecoration.lineThrough,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurface
                                    .withValues(alpha: 0.5),
                              ),
                              tableBorder: TableBorder.all(
                                color: Theme.of(context)
                                    .colorScheme
                                    .outlineVariant,
                                width: 1,
                              ),
                              tableHead: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                                color: Theme.of(context).colorScheme.onSurface,
                              ),
                              tableBody: TextStyle(
                                fontSize: 13,
                                color: Theme.of(context).colorScheme.onSurface,
                              ),
                            ),
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
        color: Theme.of(context).brightness == Brightness.dark
            ? Colors.blueGrey.shade900
            : Colors.blueGrey.shade50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: Theme.of(context).brightness == Brightness.dark
              ? Colors.blueGrey.shade700
              : Colors.blueGrey.shade200,
        ),
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
                    color: Theme.of(context).brightness == Brightness.dark
                        ? Colors.grey.shade400
                        : Colors.grey.shade600,
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
                  color: Theme.of(context).brightness == Brightness.dark
                      ? Colors.black54
                      : Colors.grey.shade100,
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
      padding: const EdgeInsets.fromLTRB(24, 12, 16, 16),
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
