import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import 'agent_state_manager.dart';
import 'chat_message.dart';
import 'models.dart';
import 'pi_rpc_client.dart';
import 'session_manager.dart';

/// The main chat content widget — messages list + input bar + queue indicators.
///
/// Designed to be embedded inside a shell layout (ShellScreen) rather than
/// appearing as a standalone Scaffold. Use a GlobalKey of ChatContentState to
/// call [reset] and [loadSession].
class ChatContent extends StatefulWidget {
  final PiRpcClient client;
  final AgentStateManager stateManager;

  const ChatContent({
    super.key,
    required this.client,
    required this.stateManager,
  });

  @override
  State<ChatContent> createState() => ChatContentState();
}

class ChatContentState extends State<ChatContent> {
  final List<ChatMessage> _messages = [];
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  int? _streamingIndex;
  final List<ImageContent> _pendingImages = [];

  /// Whether there are any messages in the current conversation.
  bool get hasMessages => _messages.isNotEmpty;

  @override
  void initState() {
    super.initState();
    widget.client.events.listen(_handleEvent);
    widget.stateManager.addListener(_onStateChange);
  }

  @override
  void dispose() {
    widget.stateManager.removeListener(_onStateChange);
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onStateChange() {
    final req = widget.stateManager.extensionUiRequest;
    if (req != null && mounted) {
      _showExtensionDialog(req);
    }
  }

  /// Clear all messages (start a new conversation).
  void reset() {
    setState(() {
      _messages.clear();
      _streamingIndex = null;
      _pendingImages.clear();
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
      } else if (role == 'bashExecution') {
        String text = 'Ran `${msg['command'] ?? ''}`\n\n'
            '```\n${msg['output'] ?? ''}\n```';
        converted.add(ChatMessage(role: MessageRole.user, text: text));
      }
    }
    setState(() => _messages.addAll(converted));
  }

  // ── Event handling ─────────────────────────────────────────────────────

  void _handleEvent(AgentEvent event) {
    switch (event) {
      case AgentStartEvent _:
        // no-op, state manager tracks this
        break;
      case AgentEndEvent _:
        _finalizeStreaming();
      case TurnStartEvent _:
        // no-op
        break;
      case TurnEndEvent _:
        _finalizeStreaming();
      case MessageStartEvent msg:
        final role =
            (msg.message is AssistantMessage) ? 'assistant' : 'user';
        if (role == 'assistant') {
          setState(() {
            _streamingIndex = _messages.length;
            _messages.add(const ChatMessage(
              role: MessageRole.assistant,
              isStreaming: true,
            ));
          });
        }
      case MessageUpdateEvent msg:
        _handleStreamingDelta(msg.assistantMessageEvent);
      case MessageEndEvent msg:
        if (msg.message is AssistantMessage) {
          final am = msg.message as AssistantMessage;
          if (_streamingIndex != null) {
            setState(() {
              _messages[_streamingIndex!] = _messages[_streamingIndex!]
                  .copyWith(
                    isStreaming: false,
                    text: am.textContent,
                    thinking: am.thinkingContent,
                  );
            });
          }
        }
      case ToolExecutionStartEvent e:
        _handleToolStart(e);
      case ToolExecutionUpdateEvent e:
        _handleToolUpdate(e);
      case ToolExecutionEndEvent e:
        _handleToolEnd(e);
      case QueueUpdateEvent _:
        // UI reacts via state manager
        break;
      case CompactionStartEvent _:
        // UI reacts via state manager
        break;
      case CompactionEndEvent _:
        // no-op
        break;
      case AutoRetryStartEvent _:
        // UI reacts via state manager
        break;
      case AutoRetryEndEvent _:
        // no-op
        break;
      case ExtensionErrorEvent e:
        _addSystemMessage('Extension error: ${e.error}');
      case ExtensionUiRequestEvent _:
        // handled by state manager listener
        break;
      case ProcessExitEvent _:
        _finalizeStreaming();
      case ProcessRestartEvent _:
        reset();
      case UnknownEvent e:
        debugPrint('Unknown event: ${e.type}');
    }
    _scrollToBottom();
  }

  void _handleStreamingDelta(AssistantMessageEvent delta) {
    if (_streamingIndex == null) return;
    switch (delta.type) {
      case 'text_delta':
        final text = delta.delta ?? '';
        setState(() {
          _messages[_streamingIndex!] = _messages[_streamingIndex!].copyWith(
            text: _messages[_streamingIndex!].text + text,
          );
        });
      case 'thinking_delta':
        final thinking = delta.delta ?? '';
        setState(() {
          _messages[_streamingIndex!] = _messages[_streamingIndex!].copyWith(
            thinking:
                (_messages[_streamingIndex!].thinking ?? '') + thinking,
          );
        });
      case 'toolcall_start':
        final toolCall = delta.partial?['toolCall'] as Map<String, dynamic>?;
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
      case 'toolcall_delta':
        // Arguments are streaming in — we could update args here if needed
        break;
      case 'toolcall_end':
        final toolCall = delta.partial?['toolCall'] as Map<String, dynamic>?;
        if (toolCall != null) {
          final id = toolCall['id'] as String? ?? '';
          _updateToolCall(
            id,
            (tc) => tc.copyWith(
              args: jsonEncode(toolCall['arguments'] ?? {}),
            ),
          );
        }
      case 'text_start':
      case 'thinking_start':
      case 'text_end':
      case 'thinking_end':
        // no-op
        break;
      case 'done':
        _finalizeStreaming();
      case 'error':
        if (delta.reason == 'aborted') {
          setState(() {
            if (_streamingIndex != null &&
                _streamingIndex! < _messages.length) {
              _messages[_streamingIndex!] =
                  _messages[_streamingIndex!].copyWith(
                isStreaming: false,
                toolCalls: _messages[_streamingIndex!]
                    .toolCalls
                    .map((tc) =>
                        tc.running ? tc.copyWith(running: false) : tc)
                    .toList(),
              );
            }
          });
        }
      default:
        break;
    }
  }

  void _handleToolStart(ToolExecutionStartEvent event) {
    final id = event.toolCallId;
    if (id.isNotEmpty) {
      _updateToolCall(id, (tc) => tc.copyWith(running: true));
    }
  }

  void _handleToolUpdate(ToolExecutionUpdateEvent event) {
    final id = event.toolCallId;
    final content = event.partialResult?['content'] as List?;
    final text = content?.isNotEmpty == true
        ? (content!.first as Map)['text'] ?? ''
        : '';
    if (id.isNotEmpty) {
      _updateToolCall(
        id,
        (tc) => tc.copyWith(result: text.toString(), running: true),
      );
    }
  }

  void _handleToolEnd(ToolExecutionEndEvent event) {
    final id = event.toolCallId;
    final content = event.result?['content'] as List?;
    final text = content?.isNotEmpty == true
        ? (content!.first as Map)['text'] ?? ''
        : '';
    if (id.isNotEmpty) {
      _updateToolCall(
        id,
        (tc) => tc.copyWith(
          result: text.toString(),
          isError: event.isError,
          running: false,
        ),
      );
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
      setState(() {
        _messages[_streamingIndex!] =
            _messages[_streamingIndex!].copyWith(isStreaming: false);
        _streamingIndex = null;
      });
    }
  }

  void _addSystemMessage(String text) {
    setState(() {
      _messages.add(ChatMessage(role: MessageRole.system, text: text));
    });
  }

  // ── Sending messages ─────────────────────────────────────────────────────

  void _sendMessage(String text) {
    if (text.trim().isEmpty && _pendingImages.isEmpty) return;

    final images = List<ImageContent>.from(_pendingImages);
    setState(() {
      _messages.add(ChatMessage(
        role: MessageRole.user,
        text: text,
        images: images,
      ));
      _pendingImages.clear();
    });

    final isStreaming = widget.stateManager.isStreaming;
    if (isStreaming) {
      // During streaming, send as steer by default
      widget.client.steer(text, images: images.isNotEmpty ? images : null);
    } else {
      widget.client.prompt(text, images: images.isNotEmpty ? images : null);
    }
    _textController.clear();
  }

  void _sendFollowUp(String text) {
    if (text.trim().isEmpty) return;
    widget.client.followUp(text);
    _textController.clear();
  }

  Future<void> _pickImages() async {
    // Simple file picker for images
    // In a real implementation, use file_picker with allowMultiple: true
    // For now, placeholder — images can be added via drag/drop or paste
    // in a more complete implementation.
  }

  // ── Extension UI dialogs ─────────────────────────────────────────────────

  void _showExtensionDialog(ExtensionUiRequest req) {
    switch (req) {
      case SelectRequest s:
        _showSelectDialog(s);
      case ConfirmRequest c:
        _showConfirmDialog(c);
      case InputRequest i:
        _showInputDialog(i);
      case EditorRequest e:
        _showEditorDialog(e);
      default:
        // Unknown — auto-dismiss
        widget.stateManager.dismissUiRequest();
    }
  }

  void _showSelectDialog(SelectRequest req) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(req.title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: req.options.map((opt) {
            return ListTile(
              title: Text(opt),
              onTap: () {
                Navigator.pop(ctx);
                widget.stateManager.respondToUiRequest(
                  ExtensionUiResponse(id: req.id, value: opt),
                );
              },
            );
          }).toList(),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              widget.stateManager.dismissUiRequest();
            },
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  void _showConfirmDialog(ConfirmRequest req) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(req.title),
        content: req.message != null ? Text(req.message!) : null,
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              widget.stateManager.respondToUiRequest(
                ExtensionUiResponse(id: req.id, confirmed: false),
              );
            },
            child: const Text('No'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              widget.stateManager.respondToUiRequest(
                ExtensionUiResponse(id: req.id, confirmed: true),
              );
            },
            child: const Text('Yes'),
          ),
        ],
      ),
    );
  }

  void _showInputDialog(InputRequest req) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(req.title),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            hintText: req.placeholder,
          ),
          autofocus: true,
          onSubmitted: (value) {
            Navigator.pop(ctx);
            widget.stateManager.respondToUiRequest(
              ExtensionUiResponse(id: req.id, value: value),
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              widget.stateManager.dismissUiRequest();
            },
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              widget.stateManager.respondToUiRequest(
                ExtensionUiResponse(id: req.id, value: controller.text),
              );
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showEditorDialog(EditorRequest req) {
    final controller = TextEditingController(text: req.prefill ?? '');
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(req.title),
        content: SizedBox(
          width: 500,
          height: 300,
          child: TextField(
            controller: controller,
            maxLines: null,
            expands: true,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.all(12),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              widget.stateManager.dismissUiRequest();
            },
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              widget.stateManager.respondToUiRequest(
                ExtensionUiResponse(id: req.id, value: controller.text),
              );
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
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

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Column(
      children: [
        // Extension widgets (above editor)
        _buildWidgets('aboveEditor'),

        // Queue indicators
        _buildQueueBar(),

        // Compaction / retry indicators
        _buildActivityBar(),

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

        // Extension widgets (below editor)
        _buildWidgets('belowEditor'),

        const Divider(height: 1),
        _InputBar(
          controller: _textController,
          onSend: _sendMessage,
          onFollowUp: _sendFollowUp,
          enabled: !widget.stateManager.isCompacting &&
              !widget.stateManager.isRetrying,
          isStreaming: widget.stateManager.isStreaming,
          onStop: () => widget.client.abort(),
          pendingImages: _pendingImages,
          onAddImage: _pickImages,
          onRemoveImage: (img) => setState(() => _pendingImages.remove(img)),
        ),
      ],
    );
  }

  Widget _buildQueueBar() {
    final steering = widget.stateManager.steeringQueue;
    final followUp = widget.stateManager.followUpQueue;
    if (steering.isEmpty && followUp.isEmpty) return const SizedBox.shrink();

    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
        border: Border(
          bottom: BorderSide(color: cs.outlineVariant),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (steering.isNotEmpty)
            _QueueChip(
              icon: Icons.navigation,
              label: 'Steering (${steering.length})',
              items: steering,
              color: cs.tertiaryContainer,
              textColor: cs.onTertiaryContainer,
            ),
          if (followUp.isNotEmpty)
            _QueueChip(
              icon: Icons.queue,
              label: 'Follow-up (${followUp.length})',
              items: followUp,
              color: cs.secondaryContainer,
              textColor: cs.onSecondaryContainer,
            ),
        ],
      ),
    );
  }

  Widget _buildActivityBar() {
    final manager = widget.stateManager;
    if (!manager.isCompacting && !manager.isRetrying) {
      return const SizedBox.shrink();
    }

    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: cs.primaryContainer.withValues(alpha: 0.3),
        border: Border(
          bottom: BorderSide(color: cs.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: cs.primary,
            ),
          ),
          const SizedBox(width: 8),
          if (manager.isCompacting)
            Text(
              'Compacting context...',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          if (manager.isRetrying)
            Text(
              'Retrying (${manager.currentRetry?.attempt ?? 1}/${manager.currentRetry?.maxAttempts ?? 3})...',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
        ],
      ),
    );
  }

  Widget _buildWidgets(String placement) {
    final widgets = widget.stateManager.widgets.values.where(
      (w) => w.placement == placement,
    );
    if (widgets.isEmpty) return const SizedBox.shrink();

    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: widgets.map((w) {
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
            border: Border(
              bottom: BorderSide(color: cs.outlineVariant),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: w.lines.map((line) {
              return Text(
                line,
                style: TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  color: cs.onSurfaceVariant,
                ),
              );
            }).toList(),
          ),
        );
      }).toList(),
    );
  }
}

// ─── Queue Chip ─────────────────────────────────────────────────────────────

class _QueueChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final List<String> items;
  final Color color;
  final Color textColor;

  const _QueueChip({
    required this.icon,
    required this.label,
    required this.items,
    required this.color,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: items.join('\n'),
      child: Container(
        margin: const EdgeInsets.only(bottom: 2),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: textColor),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(fontSize: 11, color: textColor),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Message Bubble ─────────────────────────────────────────────────────────

class _MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final bool isLast;

  const _MessageBubble({required this.message, required this.isLast});

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == MessageRole.user;
    final isSystem = message.role == MessageRole.system;
    final alignment =
        isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final color = isUser
        ? Theme.of(context).colorScheme.primaryContainer
        : isSystem
            ? Theme.of(context).colorScheme.errorContainer
            : Theme.of(context).colorScheme.surfaceContainerHighest;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: alignment,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              isUser
                  ? 'You'
                  : isSystem
                      ? 'System'
                      : 'pi',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: isSystem
                    ? Theme.of(context).colorScheme.error
                    : Theme.of(context).colorScheme.primary,
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
                  const Text('Thinking',
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
          if (message.images.isNotEmpty)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: message.images.map((img) {
                return ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(
                    base64Decode(img.data),
                    width: 200,
                    fit: BoxFit.cover,
                    errorBuilder: (ctx, err, st) => Container(
                      width: 200,
                      height: 120,
                      color: Colors.grey.shade300,
                      child: const Icon(Icons.broken_image),
                    ),
                  ),
                );
              }).toList(),
            ),
          if (message.text.isNotEmpty || message.role == MessageRole.assistant)
            Container(
              constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.8),
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
                            style:
                                const TextStyle(fontSize: 14, height: 1.4),
                          )
                        : MarkdownBody(
                            data: message.text,
                            styleSheet: _buildMarkdownStyle(context),
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

  MarkdownStyleSheet _buildMarkdownStyle(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return MarkdownStyleSheet(
      p: const TextStyle(fontSize: 14, height: 1.4),
      h1: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.bold,
        color: cs.onSurface,
        height: 1.3,
      ),
      h2: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.bold,
        color: cs.onSurface,
        height: 1.3,
      ),
      h3: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.bold,
        color: cs.onSurface,
        height: 1.3,
      ),
      code: TextStyle(
        fontSize: 13,
        fontFamily: 'monospace',
        color: Theme.of(context).brightness == Brightness.dark
            ? const Color(0xFFE6DB74)
            : const Color(0xFF4A4A4A),
        backgroundColor: cs.surfaceContainerHighest,
      ),
      codeblockDecoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
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
            color: cs.primary.withValues(alpha: 0.4),
            width: 3,
          ),
        ),
      ),
      blockquote: TextStyle(
        fontStyle: FontStyle.italic,
        color: cs.onSurface.withValues(alpha: 0.7),
      ),
      listBullet: TextStyle(
        fontSize: 14,
        color: cs.onSurface,
      ),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            width: 1,
            color: cs.outlineVariant,
          ),
        ),
      ),
      strong: TextStyle(
        fontWeight: FontWeight.bold,
        color: cs.onSurface,
      ),
      em: const TextStyle(fontStyle: FontStyle.italic),
      a: TextStyle(
        color: cs.primary,
        decoration: TextDecoration.underline,
      ),
      del: TextStyle(
        decoration: TextDecoration.lineThrough,
        color: cs.onSurface.withValues(alpha: 0.5),
      ),
      tableBorder: TableBorder.all(
        color: cs.outlineVariant,
        width: 1,
      ),
      tableHead: TextStyle(
        fontWeight: FontWeight.bold,
        fontSize: 13,
        color: cs.onSurface,
      ),
      tableBody: TextStyle(
        fontSize: 13,
        color: cs.onSurface,
      ),
    );
  }
}

// ─── Tool Call Widget ───────────────────────────────────────────────────────

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

// ─── Input Bar ──────────────────────────────────────────────────────────────

class _InputBar extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onSend;
  final ValueChanged<String> onFollowUp;
  final bool enabled;
  final bool isStreaming;
  final VoidCallback? onStop;
  final List<ImageContent> pendingImages;
  final VoidCallback onAddImage;
  final ValueChanged<ImageContent> onRemoveImage;

  const _InputBar({
    required this.controller,
    required this.onSend,
    required this.onFollowUp,
    required this.enabled,
    required this.isStreaming,
    this.onStop,
    required this.pendingImages,
    required this.onAddImage,
    required this.onRemoveImage,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.fromLTRB(24, 12, 16, 16),
      color: cs.surface,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (pendingImages.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Wrap(
                spacing: 8,
                children: pendingImages.map((img) {
                  return Chip(
                    label: Text(img.mimeType,
                        style: const TextStyle(fontSize: 11)),
                    deleteIcon: const Icon(Icons.close, size: 14),
                    onDeleted: () => onRemoveImage(img),
                    visualDensity: VisualDensity.compact,
                  );
                }).toList(),
              ),
            ),
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.image, size: 20),
                tooltip: 'Attach image',
                onPressed: enabled ? onAddImage : null,
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: TextField(
                  controller: controller,
                  enabled: enabled,
                  onSubmitted: enabled
                      ? (text) {
                          if (isStreaming) {
                            onFollowUp(text);
                          } else {
                            onSend(text);
                          }
                        }
                      : null,
                  style: const TextStyle(fontSize: 14),
                  decoration: InputDecoration(
                    hintText: isStreaming
                        ? 'Send steering message...'
                        : enabled
                            ? 'Ask pi something...'
                            : 'Busy...',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (isStreaming)
                IconButton.filled(
                  onPressed: () => onFollowUp(controller.text),
                  icon: const Icon(Icons.navigation),
                  tooltip: 'Steer',
                )
              else if (enabled)
                IconButton.filled(
                  onPressed: () => onSend(controller.text),
                  icon: const Icon(Icons.send),
                )
              else
                const SizedBox(
                  width: 40,
                  height: 40,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              if (isStreaming) ...[
                const SizedBox(width: 4),
                IconButton.filled(
                  onPressed: onStop,
                  icon: const Icon(Icons.stop),
                  style: IconButton.styleFrom(
                    backgroundColor: cs.error,
                    foregroundColor: cs.onError,
                  ),
                  tooltip: 'Stop',
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
