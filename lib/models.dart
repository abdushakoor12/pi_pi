// Typed models for the pi RPC protocol.
//
// Covers: commands, responses, events, messages, extension UI requests/responses.

// ─── Content blocks ─────────────────────────────────────────────────────────

sealed class ContentBlock {
  Map<String, dynamic> toJson();
}

class TextContent implements ContentBlock {
  final String text;

  const TextContent(this.text);

  factory TextContent.fromJson(Map<String, dynamic> json) {
    return TextContent(json['text'] as String? ?? '');
  }

  @override
  Map<String, dynamic> toJson() => {'type': 'text', 'text': text};
}

class ImageContent implements ContentBlock {
  final String data;
  final String mimeType;

  const ImageContent({required this.data, required this.mimeType});

  factory ImageContent.fromJson(Map<String, dynamic> json) {
    return ImageContent(
      data: json['data'] as String? ?? '',
      mimeType: json['mimeType'] as String? ?? 'image/png',
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'image',
        'data': data,
        'mimeType': mimeType,
      };
}

class ThinkingContent implements ContentBlock {
  final String thinking;

  const ThinkingContent(this.thinking);

  factory ThinkingContent.fromJson(Map<String, dynamic> json) {
    return ThinkingContent(json['thinking'] as String? ?? '');
  }

  @override
  Map<String, dynamic> toJson() => {'type': 'thinking', 'thinking': thinking};
}

class ToolCallContent implements ContentBlock {
  final String id;
  final String name;
  final Map<String, dynamic> arguments;

  const ToolCallContent({
    required this.id,
    required this.name,
    required this.arguments,
  });

  factory ToolCallContent.fromJson(Map<String, dynamic> json) {
    return ToolCallContent(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      arguments: json['arguments'] as Map<String, dynamic>? ?? {},
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'toolCall',
        'id': id,
        'name': name,
        'arguments': arguments,
      };
}

List<ContentBlock> parseContentBlocks(dynamic content) {
  if (content is! List) return [];
  return content.map((block) {
    if (block is! Map) return null;
    final json = block.cast<String, dynamic>();
    final type = json['type'] as String?;
    return switch (type) {
      'text' => TextContent.fromJson(json),
      'image' => ImageContent.fromJson(json),
      'thinking' => ThinkingContent.fromJson(json),
      'toolCall' => ToolCallContent.fromJson(json),
      _ => null,
    };
  }).whereType<ContentBlock>().toList();
}

// ─── Messages ───────────────────────────────────────────────────────────────

sealed class AgentMessage {
  final String role;
  final int? timestamp;

  const AgentMessage({required this.role, this.timestamp});

  factory AgentMessage.fromJson(Map<String, dynamic> json) {
    final role = json['role'] as String?;
    return switch (role) {
      'user' => UserMessage.fromJson(json),
      'assistant' => AssistantMessage.fromJson(json),
      'toolResult' => ToolResultMessage.fromJson(json),
      'bashExecution' => BashExecutionMessage.fromJson(json),
      _ => UserMessage.fromJson(json),
    };
  }

  Map<String, dynamic> toJson();
}

class UserMessage extends AgentMessage {
  final String text;
  final List<Attachment> attachments;

  UserMessage({
    required this.text,
    this.attachments = const [],
    super.timestamp,
  }) : super(role: 'user');

  factory UserMessage.fromJson(Map<String, dynamic> json) {
    final content = json['content'];
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
    return UserMessage(
      text: text,
      timestamp: json['timestamp'] as int?,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'role': role,
        'content': text,
        if (timestamp != null) 'timestamp': timestamp,
        'attachments': attachments.map((a) => a.toJson()).toList(),
      };
}

class AssistantMessage extends AgentMessage {
  final List<ContentBlock> content;
  final String? api;
  final String? provider;
  final String? model;
  final Usage? usage;
  final String? stopReason;

  AssistantMessage({
    required this.content,
    this.api,
    this.provider,
    this.model,
    this.usage,
    this.stopReason,
    super.timestamp,
  }) : super(role: 'assistant');

  factory AssistantMessage.fromJson(Map<String, dynamic> json) {
    return AssistantMessage(
      content: parseContentBlocks(json['content']),
      api: json['api'] as String?,
      provider: json['provider'] as String?,
      model: json['model'] as String?,
      usage: json['usage'] != null ? Usage.fromJson(json['usage']) : null,
      stopReason: json['stopReason'] as String?,
      timestamp: json['timestamp'] as int?,
    );
  }

  String get textContent {
    return content.whereType<TextContent>().map((c) => c.text).join();
  }

  String? get thinkingContent {
    final parts = content.whereType<ThinkingContent>().map((c) => c.thinking).toList();
    return parts.isEmpty ? null : parts.join();
  }

  List<ToolCallContent> get toolCalls {
    return content.whereType<ToolCallContent>().toList();
  }

  @override
  Map<String, dynamic> toJson() => {
        'role': role,
        'content': content.map((c) => c.toJson()).toList(),
        if (api != null) 'api': api,
        if (provider != null) 'provider': provider,
        if (model != null) 'model': model,
        if (usage != null) 'usage': usage!.toJson(),
        if (stopReason != null) 'stopReason': stopReason,
        if (timestamp != null) 'timestamp': timestamp,
      };
}

class ToolResultMessage extends AgentMessage {
  final String toolCallId;
  final String toolName;
  final List<ContentBlock> content;
  final bool isError;

  ToolResultMessage({
    required this.toolCallId,
    required this.toolName,
    required this.content,
    this.isError = false,
    super.timestamp,
  }) : super(role: 'toolResult');

  factory ToolResultMessage.fromJson(Map<String, dynamic> json) {
    return ToolResultMessage(
      toolCallId: json['toolCallId'] as String? ?? '',
      toolName: json['toolName'] as String? ?? '',
      content: parseContentBlocks(json['content']),
      isError: json['isError'] as bool? ?? false,
      timestamp: json['timestamp'] as int?,
    );
  }

  String get textContent {
    return content.whereType<TextContent>().map((c) => c.text).join();
  }

  @override
  Map<String, dynamic> toJson() => {
        'role': role,
        'toolCallId': toolCallId,
        'toolName': toolName,
        'content': content.map((c) => c.toJson()).toList(),
        'isError': isError,
        if (timestamp != null) 'timestamp': timestamp,
      };
}

class BashExecutionMessage extends AgentMessage {
  final String command;
  final String output;
  final int exitCode;
  final bool cancelled;
  final bool truncated;
  final String? fullOutputPath;

  BashExecutionMessage({
    required this.command,
    required this.output,
    this.exitCode = 0,
    this.cancelled = false,
    this.truncated = false,
    this.fullOutputPath,
    super.timestamp,
  }) : super(role: 'bashExecution');

  factory BashExecutionMessage.fromJson(Map<String, dynamic> json) {
    return BashExecutionMessage(
      command: json['command'] as String? ?? '',
      output: json['output'] as String? ?? '',
      exitCode: json['exitCode'] as int? ?? 0,
      cancelled: json['cancelled'] as bool? ?? false,
      truncated: json['truncated'] as bool? ?? false,
      fullOutputPath: json['fullOutputPath'] as String?,
      timestamp: json['timestamp'] as int?,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'role': role,
        'command': command,
        'output': output,
        'exitCode': exitCode,
        'cancelled': cancelled,
        'truncated': truncated,
        if (fullOutputPath != null) 'fullOutputPath': fullOutputPath,
        if (timestamp != null) 'timestamp': timestamp,
      };
}

// ─── Usage / Cost ───────────────────────────────────────────────────────────

class Usage {
  final int input;
  final int output;
  final int cacheRead;
  final int cacheWrite;
  final Cost cost;

  const Usage({
    this.input = 0,
    this.output = 0,
    this.cacheRead = 0,
    this.cacheWrite = 0,
    required this.cost,
  });

  factory Usage.fromJson(Map<String, dynamic> json) {
    return Usage(
      input: json['input'] as int? ?? 0,
      output: json['output'] as int? ?? 0,
      cacheRead: json['cacheRead'] as int? ?? 0,
      cacheWrite: json['cacheWrite'] as int? ?? 0,
      cost: Cost.fromJson(json['cost'] as Map<String, dynamic>? ?? {}),
    );
  }

  Map<String, dynamic> toJson() => {
        'input': input,
        'output': output,
        'cacheRead': cacheRead,
        'cacheWrite': cacheWrite,
        'cost': cost.toJson(),
      };
}

class Cost {
  final double input;
  final double output;
  final double cacheRead;
  final double cacheWrite;
  final double total;

  const Cost({
    this.input = 0,
    this.output = 0,
    this.cacheRead = 0,
    this.cacheWrite = 0,
    this.total = 0,
  });

  factory Cost.fromJson(Map<String, dynamic> json) {
    return Cost(
      input: (json['input'] as num?)?.toDouble() ?? 0,
      output: (json['output'] as num?)?.toDouble() ?? 0,
      cacheRead: (json['cacheRead'] as num?)?.toDouble() ?? 0,
      cacheWrite: (json['cacheWrite'] as num?)?.toDouble() ?? 0,
      total: (json['total'] as num?)?.toDouble() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'input': input,
        'output': output,
        'cacheRead': cacheRead,
        'cacheWrite': cacheWrite,
        'total': total,
      };
}

// ─── Attachment ───────────────────────────────────────────────────────────────

class Attachment {
  final String id;
  final String type;
  final String fileName;
  final String mimeType;
  final int size;
  final String content;
  final String? extractedText;
  final String? preview;

  const Attachment({
    required this.id,
    required this.type,
    required this.fileName,
    required this.mimeType,
    required this.size,
    required this.content,
    this.extractedText,
    this.preview,
  });

  factory Attachment.fromJson(Map<String, dynamic> json) {
    return Attachment(
      id: json['id'] as String? ?? '',
      type: json['type'] as String? ?? 'image',
      fileName: json['fileName'] as String? ?? '',
      mimeType: json['mimeType'] as String? ?? '',
      size: json['size'] as int? ?? 0,
      content: json['content'] as String? ?? '',
      extractedText: json['extractedText'] as String?,
      preview: json['preview'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'fileName': fileName,
        'mimeType': mimeType,
        'size': size,
        'content': content,
        if (extractedText != null) 'extractedText': extractedText,
        if (preview != null) 'preview': preview,
      };
}

// ─── Model ──────────────────────────────────────────────────────────────────

class Model {
  final String id;
  final String name;
  final String api;
  final String provider;
  final String? baseUrl;
  final bool reasoning;
  final List<String> input;
  final int? contextWindow;
  final int? maxTokens;
  final ModelCost? cost;

  const Model({
    required this.id,
    required this.name,
    required this.api,
    required this.provider,
    this.baseUrl,
    this.reasoning = false,
    this.input = const ['text'],
    this.contextWindow,
    this.maxTokens,
    this.cost,
  });

  factory Model.fromJson(Map<String, dynamic> json) {
    return Model(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? json['id'] ?? '',
      api: json['api'] as String? ?? '',
      provider: json['provider'] as String? ?? '',
      baseUrl: json['baseUrl'] as String?,
      reasoning: json['reasoning'] as bool? ?? false,
      input: (json['input'] as List<dynamic>?)?.cast<String>() ?? const ['text'],
      contextWindow: json['contextWindow'] as int?,
      maxTokens: json['maxTokens'] as int?,
      cost: json['cost'] != null ? ModelCost.fromJson(json['cost']) : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'api': api,
        'provider': provider,
        if (baseUrl != null) 'baseUrl': baseUrl,
        'reasoning': reasoning,
        'input': input,
        if (contextWindow != null) 'contextWindow': contextWindow,
        if (maxTokens != null) 'maxTokens': maxTokens,
        if (cost != null) 'cost': cost!.toJson(),
      };
}

class ModelCost {
  final double input;
  final double output;
  final double? cacheRead;
  final double? cacheWrite;

  const ModelCost({
    required this.input,
    required this.output,
    this.cacheRead,
    this.cacheWrite,
  });

  factory ModelCost.fromJson(Map<String, dynamic> json) {
    return ModelCost(
      input: (json['input'] as num?)?.toDouble() ?? 0,
      output: (json['output'] as num?)?.toDouble() ?? 0,
      cacheRead: (json['cacheRead'] as num?)?.toDouble(),
      cacheWrite: (json['cacheWrite'] as num?)?.toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {
        'input': input,
        'output': output,
        if (cacheRead != null) 'cacheRead': cacheRead,
        if (cacheWrite != null) 'cacheWrite': cacheWrite,
      };
}

// ─── Agent State ────────────────────────────────────────────────────────────

class AgentState {
  final Model? model;
  final String? thinkingLevel;
  final bool isStreaming;
  final bool isCompacting;
  final String? steeringMode;
  final String? followUpMode;
  final String? sessionFile;
  final String? sessionId;
  final String? sessionName;
  final bool? autoCompactionEnabled;
  final int? messageCount;
  final int? pendingMessageCount;

  const AgentState({
    this.model,
    this.thinkingLevel,
    this.isStreaming = false,
    this.isCompacting = false,
    this.steeringMode,
    this.followUpMode,
    this.sessionFile,
    this.sessionId,
    this.sessionName,
    this.autoCompactionEnabled,
    this.messageCount,
    this.pendingMessageCount,
  });

  factory AgentState.fromJson(Map<String, dynamic> json) {
    return AgentState(
      model: json['model'] != null ? Model.fromJson(json['model']) : null,
      thinkingLevel: json['thinkingLevel'] as String?,
      isStreaming: json['isStreaming'] as bool? ?? false,
      isCompacting: json['isCompacting'] as bool? ?? false,
      steeringMode: json['steeringMode'] as String?,
      followUpMode: json['followUpMode'] as String?,
      sessionFile: json['sessionFile'] as String?,
      sessionId: json['sessionId'] as String?,
      sessionName: json['sessionName'] as String?,
      autoCompactionEnabled: json['autoCompactionEnabled'] as bool?,
      messageCount: json['messageCount'] as int?,
      pendingMessageCount: json['pendingMessageCount'] as int?,
    );
  }
}

// ─── Session Stats ──────────────────────────────────────────────────────────

class SessionStats {
  final String? sessionFile;
  final String? sessionId;
  final int userMessages;
  final int assistantMessages;
  final int toolCalls;
  final int toolResults;
  final int totalMessages;
  final TokenStats tokens;
  final double? cost;
  final ContextUsage? contextUsage;

  const SessionStats({
    this.sessionFile,
    this.sessionId,
    this.userMessages = 0,
    this.assistantMessages = 0,
    this.toolCalls = 0,
    this.toolResults = 0,
    this.totalMessages = 0,
    required this.tokens,
    this.cost,
    this.contextUsage,
  });

  factory SessionStats.fromJson(Map<String, dynamic> json) {
    return SessionStats(
      sessionFile: json['sessionFile'] as String?,
      sessionId: json['sessionId'] as String?,
      userMessages: json['userMessages'] as int? ?? 0,
      assistantMessages: json['assistantMessages'] as int? ?? 0,
      toolCalls: json['toolCalls'] as int? ?? 0,
      toolResults: json['toolResults'] as int? ?? 0,
      totalMessages: json['totalMessages'] as int? ?? 0,
      tokens: TokenStats.fromJson(json['tokens'] as Map<String, dynamic>? ?? {}),
      cost: (json['cost'] as num?)?.toDouble(),
      contextUsage: json['contextUsage'] != null
          ? ContextUsage.fromJson(json['contextUsage'])
          : null,
    );
  }
}

class TokenStats {
  final int input;
  final int output;
  final int cacheRead;
  final int cacheWrite;
  final int total;

  const TokenStats({
    this.input = 0,
    this.output = 0,
    this.cacheRead = 0,
    this.cacheWrite = 0,
    this.total = 0,
  });

  factory TokenStats.fromJson(Map<String, dynamic> json) {
    return TokenStats(
      input: json['input'] as int? ?? 0,
      output: json['output'] as int? ?? 0,
      cacheRead: json['cacheRead'] as int? ?? 0,
      cacheWrite: json['cacheWrite'] as int? ?? 0,
      total: json['total'] as int? ?? 0,
    );
  }
}

class ContextUsage {
  final int? tokens;
  final int? contextWindow;
  final int? percent;

  const ContextUsage({this.tokens, this.contextWindow, this.percent});

  factory ContextUsage.fromJson(Map<String, dynamic> json) {
    return ContextUsage(
      tokens: json['tokens'] as int?,
      contextWindow: json['contextWindow'] as int?,
      percent: json['percent'] as int?,
    );
  }
}

// ─── Compaction Result ──────────────────────────────────────────────────────

class CompactionResult {
  final String summary;
  final String? firstKeptEntryId;
  final int? tokensBefore;
  final Map<String, dynamic> details;

  const CompactionResult({
    required this.summary,
    this.firstKeptEntryId,
    this.tokensBefore,
    this.details = const {},
  });

  factory CompactionResult.fromJson(Map<String, dynamic> json) {
    return CompactionResult(
      summary: json['summary'] as String? ?? '',
      firstKeptEntryId: json['firstKeptEntryId'] as String?,
      tokensBefore: json['tokensBefore'] as int?,
      details: json['details'] as Map<String, dynamic>? ?? {},
    );
  }
}

// ─── Command Info ───────────────────────────────────────────────────────────

class CommandInfo {
  final String name;
  final String? description;
  final String source;
  final String? location;
  final String? path;

  const CommandInfo({
    required this.name,
    this.description,
    required this.source,
    this.location,
    this.path,
  });

  factory CommandInfo.fromJson(Map<String, dynamic> json) {
    return CommandInfo(
      name: json['name'] as String? ?? '',
      description: json['description'] as String?,
      source: json['source'] as String? ?? '',
      location: json['location'] as String?,
      path: json['path'] as String?,
    );
  }
}

// ─── Fork Message ───────────────────────────────────────────────────────────

class ForkMessage {
  final String entryId;
  final String text;

  const ForkMessage({required this.entryId, required this.text});

  factory ForkMessage.fromJson(Map<String, dynamic> json) {
    return ForkMessage(
      entryId: json['entryId'] as String? ?? '',
      text: json['text'] as String? ?? '',
    );
  }
}

// ─── Extension UI Requests ──────────────────────────────────────────────────

sealed class ExtensionUiRequest {
  final String id;
  final String method;

  const ExtensionUiRequest({required this.id, required this.method});

  factory ExtensionUiRequest.fromJson(Map<String, dynamic> json) {
    final method = json['method'] as String?;
    return switch (method) {
      'select' => SelectRequest.fromJson(json),
      'confirm' => ConfirmRequest.fromJson(json),
      'input' => InputRequest.fromJson(json),
      'editor' => EditorRequest.fromJson(json),
      'notify' => NotifyRequest.fromJson(json),
      'setStatus' => SetStatusRequest.fromJson(json),
      'setWidget' => SetWidgetRequest.fromJson(json),
      'setTitle' => SetTitleRequest.fromJson(json),
      'set_editor_text' => SetEditorTextRequest.fromJson(json),
      _ => UnknownUiRequest(id: json['id'] as String? ?? '', method: method ?? 'unknown'),
    };
  }
}

class UnknownUiRequest extends ExtensionUiRequest {
  const UnknownUiRequest({required super.id, required super.method});
}

class SelectRequest extends ExtensionUiRequest {
  final String title;
  final List<String> options;
  final int? timeout;

  const SelectRequest({
    required super.id,
    required this.title,
    required this.options,
    this.timeout,
  }) : super(method: 'select');

  factory SelectRequest.fromJson(Map<String, dynamic> json) {
    return SelectRequest(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      options: (json['options'] as List<dynamic>?)?.cast<String>() ?? [],
      timeout: json['timeout'] as int?,
    );
  }
}

class ConfirmRequest extends ExtensionUiRequest {
  final String title;
  final String? message;
  final int? timeout;

  const ConfirmRequest({
    required super.id,
    required this.title,
    this.message,
    this.timeout,
  }) : super(method: 'confirm');

  factory ConfirmRequest.fromJson(Map<String, dynamic> json) {
    return ConfirmRequest(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      message: json['message'] as String?,
      timeout: json['timeout'] as int?,
    );
  }
}

class InputRequest extends ExtensionUiRequest {
  final String title;
  final String? placeholder;
  final int? timeout;

  const InputRequest({
    required super.id,
    required this.title,
    this.placeholder,
    this.timeout,
  }) : super(method: 'input');

  factory InputRequest.fromJson(Map<String, dynamic> json) {
    return InputRequest(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      placeholder: json['placeholder'] as String?,
      timeout: json['timeout'] as int?,
    );
  }
}

class EditorRequest extends ExtensionUiRequest {
  final String title;
  final String? prefill;
  final int? timeout;

  const EditorRequest({
    required super.id,
    required this.title,
    this.prefill,
    this.timeout,
  }) : super(method: 'editor');

  factory EditorRequest.fromJson(Map<String, dynamic> json) {
    return EditorRequest(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      prefill: json['prefill'] as String?,
      timeout: json['timeout'] as int?,
    );
  }
}

class NotifyRequest extends ExtensionUiRequest {
  final String message;
  final String notifyType;

  const NotifyRequest({
    required super.id,
    required this.message,
    this.notifyType = 'info',
  }) : super(method: 'notify');

  factory NotifyRequest.fromJson(Map<String, dynamic> json) {
    return NotifyRequest(
      id: json['id'] as String? ?? '',
      message: json['message'] as String? ?? '',
      notifyType: json['notifyType'] as String? ?? 'info',
    );
  }
}

class SetStatusRequest extends ExtensionUiRequest {
  final String statusKey;
  final String? statusText;

  const SetStatusRequest({
    required super.id,
    required this.statusKey,
    this.statusText,
  }) : super(method: 'setStatus');

  factory SetStatusRequest.fromJson(Map<String, dynamic> json) {
    return SetStatusRequest(
      id: json['id'] as String? ?? '',
      statusKey: json['statusKey'] as String? ?? '',
      statusText: json['statusText'] as String?,
    );
  }
}

class SetWidgetRequest extends ExtensionUiRequest {
  final String widgetKey;
  final List<String>? widgetLines;
  final String widgetPlacement;

  const SetWidgetRequest({
    required super.id,
    required this.widgetKey,
    this.widgetLines,
    this.widgetPlacement = 'aboveEditor',
  }) : super(method: 'setWidget');

  factory SetWidgetRequest.fromJson(Map<String, dynamic> json) {
    return SetWidgetRequest(
      id: json['id'] as String? ?? '',
      widgetKey: json['widgetKey'] as String? ?? '',
      widgetLines: (json['widgetLines'] as List<dynamic>?)?.cast<String>(),
      widgetPlacement: json['widgetPlacement'] as String? ?? 'aboveEditor',
    );
  }
}

class SetTitleRequest extends ExtensionUiRequest {
  final String title;

  const SetTitleRequest({
    required super.id,
    required this.title,
  }) : super(method: 'setTitle');

  factory SetTitleRequest.fromJson(Map<String, dynamic> json) {
    return SetTitleRequest(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
    );
  }
}

class SetEditorTextRequest extends ExtensionUiRequest {
  final String text;

  const SetEditorTextRequest({
    required super.id,
    required this.text,
  }) : super(method: 'set_editor_text');

  factory SetEditorTextRequest.fromJson(Map<String, dynamic> json) {
    return SetEditorTextRequest(
      id: json['id'] as String? ?? '',
      text: json['text'] as String? ?? '',
    );
  }
}

// ─── Extension UI Response ──────────────────────────────────────────────────

class ExtensionUiResponse {
  final String id;
  final String? value;
  final bool? confirmed;
  final bool? cancelled;

  const ExtensionUiResponse({
    required this.id,
    this.value,
    this.confirmed,
    this.cancelled,
  });

  Map<String, dynamic> toJson() => {
        'type': 'extension_ui_response',
        'id': id,
        if (value != null) 'value': value,
        if (confirmed != null) 'confirmed': confirmed,
        if (cancelled != null) 'cancelled': cancelled,
      };
}

// ─── Events ─────────────────────────────────────────────────────────────────

sealed class AgentEvent {
  final String type;

  const AgentEvent(this.type);

  factory AgentEvent.fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String?;
    return switch (type) {
      'agent_start' => AgentStartEvent(),
      'agent_end' => AgentEndEvent.fromJson(json),
      'turn_start' => TurnStartEvent(),
      'turn_end' => TurnEndEvent.fromJson(json),
      'message_start' => MessageStartEvent.fromJson(json),
      'message_update' => MessageUpdateEvent.fromJson(json),
      'message_end' => MessageEndEvent.fromJson(json),
      'tool_execution_start' => ToolExecutionStartEvent.fromJson(json),
      'tool_execution_update' => ToolExecutionUpdateEvent.fromJson(json),
      'tool_execution_end' => ToolExecutionEndEvent.fromJson(json),
      'queue_update' => QueueUpdateEvent.fromJson(json),
      'compaction_start' => CompactionStartEvent.fromJson(json),
      'compaction_end' => CompactionEndEvent.fromJson(json),
      'auto_retry_start' => AutoRetryStartEvent.fromJson(json),
      'auto_retry_end' => AutoRetryEndEvent.fromJson(json),
      'extension_error' => ExtensionErrorEvent.fromJson(json),
      'extension_ui_request' => ExtensionUiRequestEvent.fromJson(json),
      'process_exit' => ProcessExitEvent(),
      'process_restart' => ProcessRestartEvent(),
      _ => UnknownEvent(type: type ?? 'unknown', raw: json),
    };
  }
}

class UnknownEvent extends AgentEvent {
  final Map<String, dynamic> raw;
  const UnknownEvent({required String type, required this.raw}) : super(type);
}

class AgentStartEvent extends AgentEvent {
  AgentStartEvent() : super('agent_start');
}

class AgentEndEvent extends AgentEvent {
  final List<AgentMessage> messages;

  AgentEndEvent({this.messages = const []}) : super('agent_end');

  factory AgentEndEvent.fromJson(Map<String, dynamic> json) {
    final msgs = json['messages'] as List<dynamic>?;
    return AgentEndEvent(
      messages: msgs?.map((m) => AgentMessage.fromJson(m)).toList() ?? [],
    );
  }
}

class TurnStartEvent extends AgentEvent {
  TurnStartEvent() : super('turn_start');
}

class TurnEndEvent extends AgentEvent {
  final AssistantMessage? message;
  final List<ToolResultMessage> toolResults;

  TurnEndEvent({this.message, this.toolResults = const []}) : super('turn_end');

  factory TurnEndEvent.fromJson(Map<String, dynamic> json) {
    final msg = json['message'] as Map<String, dynamic>?;
    final results = json['toolResults'] as List<dynamic>?;
    return TurnEndEvent(
      message: msg != null ? AssistantMessage.fromJson(msg) : null,
      toolResults: results
              ?.map((r) => ToolResultMessage.fromJson(r))
              .toList() ??
          [],
    );
  }
}

class MessageStartEvent extends AgentEvent {
  final AgentMessage message;

  MessageStartEvent({required this.message}) : super('message_start');

  factory MessageStartEvent.fromJson(Map<String, dynamic> json) {
    final msg = json['message'] as Map<String, dynamic>?;
    return MessageStartEvent(
      message: msg != null ? AgentMessage.fromJson(msg) : UserMessage(text: ''),
    );
  }
}

class MessageEndEvent extends AgentEvent {
  final AgentMessage message;

  MessageEndEvent({required this.message}) : super('message_end');

  factory MessageEndEvent.fromJson(Map<String, dynamic> json) {
    final msg = json['message'] as Map<String, dynamic>?;
    return MessageEndEvent(
      message: msg != null ? AgentMessage.fromJson(msg) : UserMessage(text: ''),
    );
  }
}

class AssistantMessageEvent {
  final String type;
  final int? contentIndex;
  final String? delta;
  final Map<String, dynamic>? partial;
  final String? reason;

  const AssistantMessageEvent({
    required this.type,
    this.contentIndex,
    this.delta,
    this.partial,
    this.reason,
  });

  factory AssistantMessageEvent.fromJson(Map<String, dynamic> json) {
    return AssistantMessageEvent(
      type: json['type'] as String? ?? '',
      contentIndex: json['contentIndex'] as int?,
      delta: json['delta'] as String?,
      partial: json['partial'] as Map<String, dynamic>?,
      reason: json['reason'] as String?,
    );
  }
}

class MessageUpdateEvent extends AgentEvent {
  final AgentMessage message;
  final AssistantMessageEvent assistantMessageEvent;

  MessageUpdateEvent({
    required this.message,
    required this.assistantMessageEvent,
  }) : super('message_update');

  factory MessageUpdateEvent.fromJson(Map<String, dynamic> json) {
    final msg = json['message'] as Map<String, dynamic>?;
    final event = json['assistantMessageEvent'] as Map<String, dynamic>?;
    return MessageUpdateEvent(
      message: msg != null ? AgentMessage.fromJson(msg) : UserMessage(text: ''),
      assistantMessageEvent: event != null
          ? AssistantMessageEvent.fromJson(event)
          : const AssistantMessageEvent(type: 'unknown'),
    );
  }
}

class ToolExecutionStartEvent extends AgentEvent {
  final String toolCallId;
  final String toolName;
  final Map<String, dynamic> args;

  ToolExecutionStartEvent({
    required this.toolCallId,
    required this.toolName,
    required this.args,
  }) : super('tool_execution_start');

  factory ToolExecutionStartEvent.fromJson(Map<String, dynamic> json) {
    return ToolExecutionStartEvent(
      toolCallId: json['toolCallId'] as String? ?? '',
      toolName: json['toolName'] as String? ?? '',
      args: json['args'] as Map<String, dynamic>? ?? {},
    );
  }
}

class ToolExecutionUpdateEvent extends AgentEvent {
  final String toolCallId;
  final String toolName;
  final Map<String, dynamic> args;
  final Map<String, dynamic>? partialResult;

  ToolExecutionUpdateEvent({
    required this.toolCallId,
    required this.toolName,
    required this.args,
    this.partialResult,
  }) : super('tool_execution_update');

  factory ToolExecutionUpdateEvent.fromJson(Map<String, dynamic> json) {
    return ToolExecutionUpdateEvent(
      toolCallId: json['toolCallId'] as String? ?? '',
      toolName: json['toolName'] as String? ?? '',
      args: json['args'] as Map<String, dynamic>? ?? {},
      partialResult: json['partialResult'] as Map<String, dynamic>?,
    );
  }
}

class ToolExecutionEndEvent extends AgentEvent {
  final String toolCallId;
  final String toolName;
  final Map<String, dynamic>? result;
  final bool isError;

  ToolExecutionEndEvent({
    required this.toolCallId,
    required this.toolName,
    this.result,
    this.isError = false,
  }) : super('tool_execution_end');

  factory ToolExecutionEndEvent.fromJson(Map<String, dynamic> json) {
    return ToolExecutionEndEvent(
      toolCallId: json['toolCallId'] as String? ?? '',
      toolName: json['toolName'] as String? ?? '',
      result: json['result'] as Map<String, dynamic>?,
      isError: json['isError'] as bool? ?? false,
    );
  }
}

class QueueUpdateEvent extends AgentEvent {
  final List<String> steering;
  final List<String> followUp;

  QueueUpdateEvent({
    this.steering = const [],
    this.followUp = const [],
  }) : super('queue_update');

  factory QueueUpdateEvent.fromJson(Map<String, dynamic> json) {
    return QueueUpdateEvent(
      steering: (json['steering'] as List<dynamic>?)?.cast<String>() ?? [],
      followUp: (json['followUp'] as List<dynamic>?)?.cast<String>() ?? [],
    );
  }
}

class CompactionStartEvent extends AgentEvent {
  final String reason;

  CompactionStartEvent({required this.reason}) : super('compaction_start');

  factory CompactionStartEvent.fromJson(Map<String, dynamic> json) {
    return CompactionStartEvent(
      reason: json['reason'] as String? ?? 'manual',
    );
  }
}

class CompactionEndEvent extends AgentEvent {
  final String reason;
  final CompactionResult? result;
  final bool aborted;
  final bool willRetry;
  final String? errorMessage;

  CompactionEndEvent({
    required this.reason,
    this.result,
    this.aborted = false,
    this.willRetry = false,
    this.errorMessage,
  }) : super('compaction_end');

  factory CompactionEndEvent.fromJson(Map<String, dynamic> json) {
    final result = json['result'] as Map<String, dynamic>?;
    return CompactionEndEvent(
      reason: json['reason'] as String? ?? 'manual',
      result: result != null ? CompactionResult.fromJson(result) : null,
      aborted: json['aborted'] as bool? ?? false,
      willRetry: json['willRetry'] as bool? ?? false,
      errorMessage: json['errorMessage'] as String?,
    );
  }
}

class AutoRetryStartEvent extends AgentEvent {
  final int attempt;
  final int maxAttempts;
  final int delayMs;
  final String errorMessage;

  AutoRetryStartEvent({
    required this.attempt,
    required this.maxAttempts,
    required this.delayMs,
    required this.errorMessage,
  }) : super('auto_retry_start');

  factory AutoRetryStartEvent.fromJson(Map<String, dynamic> json) {
    return AutoRetryStartEvent(
      attempt: json['attempt'] as int? ?? 1,
      maxAttempts: json['maxAttempts'] as int? ?? 3,
      delayMs: json['delayMs'] as int? ?? 2000,
      errorMessage: json['errorMessage'] as String? ?? '',
    );
  }
}

class AutoRetryEndEvent extends AgentEvent {
  final bool success;
  final int attempt;
  final String? finalError;

  AutoRetryEndEvent({
    required this.success,
    required this.attempt,
    this.finalError,
  }) : super('auto_retry_end');

  factory AutoRetryEndEvent.fromJson(Map<String, dynamic> json) {
    return AutoRetryEndEvent(
      success: json['success'] as bool? ?? false,
      attempt: json['attempt'] as int? ?? 1,
      finalError: json['finalError'] as String?,
    );
  }
}

class ExtensionErrorEvent extends AgentEvent {
  final String extensionPath;
  final String event;
  final String error;

  ExtensionErrorEvent({
    required this.extensionPath,
    required this.event,
    required this.error,
  }) : super('extension_error');

  factory ExtensionErrorEvent.fromJson(Map<String, dynamic> json) {
    return ExtensionErrorEvent(
      extensionPath: json['extensionPath'] as String? ?? '',
      event: json['event'] as String? ?? '',
      error: json['error'] as String? ?? '',
    );
  }
}

class ExtensionUiRequestEvent extends AgentEvent {
  final ExtensionUiRequest request;

  ExtensionUiRequestEvent({required this.request}) : super('extension_ui_request');

  factory ExtensionUiRequestEvent.fromJson(Map<String, dynamic> json) {
    return ExtensionUiRequestEvent(
      request: ExtensionUiRequest.fromJson(json),
    );
  }
}

class ProcessExitEvent extends AgentEvent {
  ProcessExitEvent() : super('process_exit');
}

class ProcessRestartEvent extends AgentEvent {
  ProcessRestartEvent() : super('process_restart');
}

// ─── RPC Response ───────────────────────────────────────────────────────────

class RpcResponse {
  final String? id;
  final String type;
  final String command;
  final bool success;
  final Map<String, dynamic>? data;
  final String? error;

  const RpcResponse({
    this.id,
    required this.type,
    required this.command,
    required this.success,
    this.data,
    this.error,
  });

  factory RpcResponse.fromJson(Map<String, dynamic> json) {
    return RpcResponse(
      id: json['id'] as String?,
      type: json['type'] as String? ?? 'response',
      command: json['command'] as String? ?? '',
      success: json['success'] as bool? ?? false,
      data: json['data'] as Map<String, dynamic>?,
      error: json['error'] as String?,
    );
  }
}
