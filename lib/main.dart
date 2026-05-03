import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pi Pi',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const ChatScreen(),
    );
  }
}

// ─── Message model ───────────────────────────────────────────────────────────

enum MessageRole { user, assistant, system }

class ChatMessage {
  final MessageRole role;
  final String text;
  final String? thinking;
  final List<ToolCall> toolCalls;
  final bool isStreaming;

  const ChatMessage({
    required this.role,
    this.text = '',
    this.thinking,
    this.toolCalls = const [],
    this.isStreaming = false,
  });

  ChatMessage copyWith({
    MessageRole? role,
    String? text,
    String? thinking,
    List<ToolCall>? toolCalls,
    bool? isStreaming,
  }) {
    return ChatMessage(
      role: role ?? this.role,
      text: text ?? this.text,
      thinking: thinking ?? this.thinking,
      toolCalls: toolCalls ?? this.toolCalls,
      isStreaming: isStreaming ?? this.isStreaming,
    );
  }
}

class ToolCall {
  final String id;
  final String name;
  final String args;
  final String? result;
  final bool isError;
  final bool running;

  const ToolCall({
    required this.id,
    required this.name,
    this.args = '',
    this.result,
    this.isError = false,
    this.running = false,
  });

  ToolCall copyWith({
    String? id,
    String? name,
    String? args,
    String? result,
    bool? isError,
    bool? running,
  }) {
    return ToolCall(
      id: id ?? this.id,
      name: name ?? this.name,
      args: args ?? this.args,
      result: result,
      isError: isError ?? this.isError,
      running: running ?? this.running,
    );
  }
}

// ─── RPC Client ──────────────────────────────────────────────────────────────

class PiRpcClient {
  Process? _process;
  int _reqId = 0;
  bool _disposed = false;

  final _eventController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get events => _eventController.stream;

  final _responseController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get responses => _responseController.stream;

  Future<void> start() async {
    _process = await Process.start(
      'pi',
      ['--mode', 'rpc', '--no-session'],
      mode: ProcessStartMode.normal,
    );

    // Read stdout lines (JSONL)
    _process!.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(
      (line) {
        if (_disposed) return;
        try {
          final json = jsonDecode(line) as Map<String, dynamic>;
          if (json['type'] == 'response') {
            _responseController.add(json);
          } else {
            _eventController.add(json);
          }
        } catch (_) {
          // Ignore parse errors
        }
      },
      onError: (_) {},
    );

    // Log stderr
    _process!.stderr.transform(utf8.decoder).listen(
      (data) => debugPrint('[pi stderr] $data'),
    );

    _process!.exitCode.then((_) {
      if (!_disposed) {
        _eventController.add({'type': 'process_exit'});
      }
    });
  }

  void send(Map<String, dynamic> command) {
    if (_process == null || _disposed) return;
    final id = 'req-${_reqId++}';
    command['id'] = id;
    _process!.stdin.write('${jsonEncode(command)}\n');
    _process!.stdin.flush();
  }

  Future<void> dispose() async {
    _disposed = true;
    await _eventController.close();
    await _responseController.close();
    _process?.kill();
  }
}

// ─── Chat Screen ─────────────────────────────────────────────────────────────

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

  // Track the current streaming assistant message index
  int? _streamingIndex;

  @override
  void initState() {
    super.initState();
    _client = PiRpcClient();
    _initClient();
  }

  Future<void> _initClient() async {
    await _client.start();
    setState(() => _ready = true);

    _client.events.listen(_handleEvent);
    _client.responses.listen((_) {}); // We don't need to handle responses yet
  }

  void _handleEvent(Map<String, dynamic> event) {
    final type = event['type'] as String?;

    switch (type) {
      case 'agent_start':
        setState(() => _agentRunning = true);
        break;

      case 'agent_end':
        setState(() {
          _agentRunning = false;
          if (_streamingIndex != null) {
            _messages[_streamingIndex!] =
                _messages[_streamingIndex!].copyWith(isStreaming: false);
            _streamingIndex = null;
          }
        });
        break;

      case 'message_start':
        final msg = event['message'] as Map<String, dynamic>?;
        final role = msg?['role'] as String?;
        if (role == 'assistant') {
          setState(() {
            _streamingIndex = _messages.length;
            _messages.add(const ChatMessage(
              role: MessageRole.assistant,
              isStreaming: true,
            ));
          });
        }
        break;

      case 'message_update':
        final delta = event['assistantMessageEvent'] as Map<String, dynamic>?;
        final deltaType = delta?['type'] as String?;
        if (_streamingIndex == null) break;

        switch (deltaType) {
          case 'text_delta':
            final text = (delta!['delta'] as String?) ?? '';
            setState(() {
              _messages[_streamingIndex!] = _messages[_streamingIndex!]
                  .copyWith(text: _messages[_streamingIndex!].text + text);
            });
            break;

          case 'thinking_delta':
            final thinking = (delta!['delta'] as String?) ?? '';
            setState(() {
              _messages[_streamingIndex!] = _messages[_streamingIndex!].copyWith(
                thinking:
                    (_messages[_streamingIndex!].thinking ?? '') + thinking,
              );
            });
            break;

          case 'toolcall_start':
            final partial = delta!['partial'] as Map<String, dynamic>?;
            final toolCall = partial?['toolCall'] as Map<String, dynamic>?;
            if (toolCall != null) {
              setState(() {
                final tc = ToolCall(
                  id: toolCall['id'] as String? ?? '',
                  name: toolCall['name'] as String? ?? '',
                  args: jsonEncode(toolCall['arguments'] ?? {}),
                  running: true,
                );
                _messages[_streamingIndex!] = _messages[_streamingIndex!]
                    .copyWith(
                        toolCalls: [
                          ..._messages[_streamingIndex!].toolCalls,
                          tc
                        ]);
              });
            }
            break;

          case 'toolcall_delta':
            // Tool call argument streaming - we can ignore for now
            break;

          case 'toolcall_end':
            final partial = delta!['partial'] as Map<String, dynamic>?;
            final toolCall = partial?['toolCall'] as Map<String, dynamic>?;
            if (toolCall != null) {
              final id = toolCall['id'] as String? ?? '';
              setState(() {
                final updatedTools =
                    _messages[_streamingIndex!].toolCalls.map((tc) {
                  if (tc.id == id) {
                    return tc.copyWith(
                      args: jsonEncode(toolCall['arguments'] ?? {}),
                      running: true, // still running until tool_execution_end
                    );
                  }
                  return tc;
                }).toList();
                _messages[_streamingIndex!] =
                    _messages[_streamingIndex!].copyWith(toolCalls: updatedTools);
              });
            }
            break;
        }
        break;

      case 'message_end':
        // Finalize the message - keep streaming true if agent is still running
        // (there may be more messages in this turn)
        break;

      case 'tool_execution_start':
        final toolCallId = event['toolCallId'] as String?;
        if (_streamingIndex != null && toolCallId != null) {
          setState(() {
            final updatedTools =
                _messages[_streamingIndex!].toolCalls.map((tc) {
              if (tc.id == toolCallId) {
                return tc.copyWith(running: true);
              }
              return tc;
            }).toList();
            _messages[_streamingIndex!] =
                _messages[_streamingIndex!].copyWith(toolCalls: updatedTools);
          });
        }
        break;

      case 'tool_execution_update':
        final toolCallId = event['toolCallId'] as String?;
        final partial = event['partialResult'] as Map<String, dynamic>?;
        final content = partial?['content'] as List?;
        final text =
            content?.isNotEmpty == true ? (content!.first as Map)['text'] ?? '' : '';
        if (_streamingIndex != null && toolCallId != null) {
          setState(() {
            final updatedTools =
                _messages[_streamingIndex!].toolCalls.map((tc) {
              if (tc.id == toolCallId) {
                return tc.copyWith(result: text, running: true);
              }
              return tc;
            }).toList();
            _messages[_streamingIndex!] =
                _messages[_streamingIndex!].copyWith(toolCalls: updatedTools);
          });
        }
        break;

      case 'tool_execution_end':
        final toolCallId = event['toolCallId'] as String?;
        final result = event['result'] as Map<String, dynamic>?;
        final content = result?['content'] as List?;
        final text =
            content?.isNotEmpty == true ? (content!.first as Map)['text'] ?? '' : '';
        final isError = event['isError'] as bool? ?? false;
        if (_streamingIndex != null && toolCallId != null) {
          setState(() {
            final updatedTools =
                _messages[_streamingIndex!].toolCalls.map((tc) {
              if (tc.id == toolCallId) {
                return tc.copyWith(
                  result: text.toString(),
                  isError: isError,
                  running: false,
                );
              }
              return tc;
            }).toList();
            _messages[_streamingIndex!] =
                _messages[_streamingIndex!].copyWith(toolCalls: updatedTools);
          });
        }
        break;

      case 'turn_end':
        // Finalize the assistant message
        if (_streamingIndex != null) {
          setState(() {
            _messages[_streamingIndex!] =
                _messages[_streamingIndex!].copyWith(isStreaming: false);
            _streamingIndex = null;
          });
        }
        break;

      case 'process_exit':
        setState(() => _ready = false);
        break;
    }

    _scrollToBottom();
  }

  void _sendMessage(String text) {
    if (text.trim().isEmpty) return;
    setState(() {
      _messages.add(ChatMessage(
        role: MessageRole.user,
        text: text,
      ));
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pi Pi'),
        actions: [
          if (_agentRunning)
            const Padding(
              padding: EdgeInsets.only(right: 16),
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
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
          // Role label
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
          // Thinking block
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
                  const Text(
                    '💭 Thinking',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    message.thinking!,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.grey,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ),
            ),
          // Text content
          if (message.text.isNotEmpty || message.role == MessageRole.assistant)
            Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.85,
              ),
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
                        child: CircularProgressIndicator(strokeWidth: 1.5),
                      ),
                    ),
                ],
              ),
            ),
          // Tool calls
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
              Icon(
                Icons.terminal,
                size: 14,
                color: toolCall.running ? Colors.orange : Colors.green,
              ),
              const SizedBox(width: 6),
              Text(
                toolCall.name,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'monospace',
                ),
              ),
              if (toolCall.running) ...[
                const SizedBox(width: 6),
                const SizedBox(
                  width: 10,
                  height: 10,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                ),
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
                  fontFamily: 'monospace',
                ),
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
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                toolCall.result!,
                style: TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  color:
                      toolCall.isError ? Colors.red.shade300 : Colors.green.shade300,
                ),
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
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
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
