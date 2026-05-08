import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pi/models.dart';

void main() {
  group('Model parsing', () {
    test('parses model from JSON', () {
      final json = {
        'id': 'claude-sonnet-4',
        'name': 'Claude Sonnet 4',
        'api': 'anthropic-messages',
        'provider': 'anthropic',
        'reasoning': true,
        'contextWindow': 200000,
      };
      final model = Model.fromJson(json);
      expect(model.id, 'claude-sonnet-4');
      expect(model.name, 'Claude Sonnet 4');
      expect(model.provider, 'anthropic');
      expect(model.reasoning, true);
    });
  });

  group('AgentEvent parsing', () {
    test('parses agent_start event', () {
      final event = AgentEvent.fromJson({'type': 'agent_start'});
      expect(event, isA<AgentStartEvent>());
    });

    test('parses queue_update event', () {
      final event = AgentEvent.fromJson({
        'type': 'queue_update',
        'steering': ['Focus on error handling'],
        'followUp': ['After that, summarize'],
      });
      expect(event, isA<QueueUpdateEvent>());
      final q = event as QueueUpdateEvent;
      expect(q.steering.length, 1);
      expect(q.followUp.length, 1);
    });

    test('parses extension_ui_request select', () {
      final event = AgentEvent.fromJson({
        'type': 'extension_ui_request',
        'id': 'uuid-1',
        'method': 'select',
        'title': 'Allow?',
        'options': ['Yes', 'No'],
      });
      expect(event, isA<ExtensionUiRequestEvent>());
      final req = (event as ExtensionUiRequestEvent).request;
      expect(req, isA<SelectRequest>());
      expect((req as SelectRequest).options.length, 2);
    });
  });

  group('ContentBlock parsing', () {
    test('parses text and thinking blocks', () {
      final blocks = parseContentBlocks([
        {'type': 'text', 'text': 'Hello'},
        {'type': 'thinking', 'thinking': 'Hmm'},
      ]);
      expect(blocks.length, 2);
      expect(blocks[0], isA<TextContent>());
      expect(blocks[1], isA<ThinkingContent>());
    });
  });
}
