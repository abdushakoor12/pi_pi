import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pi/extension_ui_dialogs.dart';
import 'package:pi_pi/models.dart';
import 'package:pi_pi/pi_rpc_client.dart';

/// Minimal PiRpcClient subclass for testing.
class _MockRpcClient extends PiRpcClient {
  final List<ExtensionUiResponse> sentResponses = [];

  @override
  void sendUiResponse(ExtensionUiResponse response) {
    sentResponses.add(response);
  }

  // Override dispose to prevent actual process cleanup
  @override
  Future<void> dispose() async {
    // no-op
  }
}

void main() {
  group('ExtensionUiDialogs', () {
    testWidgets('show dispatches SelectRequest to select dialog',
        (tester) async {
      final client = _MockRpcClient();
      final req = SelectRequest(
        id: 'sel-1',
        title: 'Choose option',
        options: ['Alpha', 'Beta'],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              Future.microtask(() {
                ExtensionUiDialogs.show(context, req, client);
              });
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Choose option'), findsOneWidget);
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Beta'), findsOneWidget);

      await tester.tap(find.text('Alpha'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(client.sentResponses.length, 1);
      expect(client.sentResponses.first.value, 'Alpha');
    });

    testWidgets('show dispatches ConfirmRequest to confirm dialog',
        (tester) async {
      final client = _MockRpcClient();
      final req = ConfirmRequest(
        id: 'cf-1',
        title: 'Proceed?',
        message: 'Are you sure?',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              Future.microtask(() {
                ExtensionUiDialogs.show(context, req, client);
              });
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Proceed?'), findsOneWidget);
      expect(find.text('Are you sure?'), findsOneWidget);

      await tester.tap(find.text('Yes'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(client.sentResponses.length, 1);
      expect(client.sentResponses.first.confirmed, true);
    });

    testWidgets('show dispatches InputRequest to input dialog',
        (tester) async {
      final client = _MockRpcClient();
      final req = InputRequest(
        id: 'in-1',
        title: 'Enter name',
        placeholder: 'your name',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              Future.microtask(() {
                ExtensionUiDialogs.show(context, req, client);
              });
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Enter name'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Alice');
      await tester.tap(find.text('OK'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(client.sentResponses.length, 1);
      expect(client.sentResponses.first.value, 'Alice');
    });

    testWidgets('show dispatches EditorRequest to editor dialog',
        (tester) async {
      final client = _MockRpcClient();
      final req = EditorRequest(
        id: 'ed-1',
        title: 'Edit text',
        prefill: 'Hello\nWorld',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              Future.microtask(() {
                ExtensionUiDialogs.show(context, req, client);
              });
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Edit text'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'New text');
      await tester.tap(find.text('OK'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(client.sentResponses.length, 1);
      expect(client.sentResponses.first.value, 'New text');
    });

    testWidgets('cancelling select sends cancelled response', (tester) async {
      final client = _MockRpcClient();
      final req = SelectRequest(
        id: 'sel-2',
        title: 'Cancel test',
        options: ['X', 'Y'],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              Future.microtask(() {
                ExtensionUiDialogs.show(context, req, client);
              });
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(client.sentResponses.length, 1);
      expect(client.sentResponses.first.cancelled, true);
    });

    testWidgets('unknown request type auto-dismisses', (tester) async {
      final client = _MockRpcClient();
      final req = UnknownUiRequest(id: 'unk-1', method: 'unknown');

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              Future.microtask(() {
                ExtensionUiDialogs.show(context, req, client);
              });
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(client.sentResponses.length, 1);
      expect(client.sentResponses.first.cancelled, true);
    });
  });
}
