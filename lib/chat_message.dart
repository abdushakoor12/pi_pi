import 'models.dart';

enum MessageRole { user, assistant, system }

class ChatMessage {
  final MessageRole role;
  final String text;
  final String? thinking;
  final List<ToolCall> toolCalls;
  final bool isStreaming;
  final List<ImageContent> images;

  const ChatMessage({
    required this.role,
    this.text = '',
    this.thinking,
    this.toolCalls = const [],
    this.isStreaming = false,
    this.images = const [],
  });

  ChatMessage copyWith({
    MessageRole? role,
    String? text,
    String? thinking,
    List<ToolCall>? toolCalls,
    bool? isStreaming,
    List<ImageContent>? images,
  }) {
    return ChatMessage(
      role: role ?? this.role,
      text: text ?? this.text,
      thinking: thinking,
      toolCalls: toolCalls ?? this.toolCalls,
      isStreaming: isStreaming ?? this.isStreaming,
      images: images ?? this.images,
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
