import 'package:flutter/material.dart';

import 'models.dart';
import 'pi_rpc_client.dart';

/// Static helpers for showing extension UI dialogs.
///
/// These dialogs are triggered by [AgentStateManager.extensionUiRequest]
/// and handle the request/response protocol with the pi agent.
///
/// Extracted into its own file to reduce [ChatContent]'s responsibilities.
///
/// The [client] parameter is used to send the response back to the agent.
/// A [onDismissed] callback can be provided to notify the caller when
/// the dialog has been dismissed (useful for the state manager to clear
/// its internal state).
class ExtensionUiDialogs {
  /// Show the appropriate dialog for an extension UI request.
  static void show(
    BuildContext context,
    ExtensionUiRequest req,
    PiRpcClient client, {
    VoidCallback? onDismissed,
  }) {
    switch (req) {
      case SelectRequest s:
        _showSelectDialog(context, s, client, onDismissed: onDismissed);
      case ConfirmRequest c:
        _showConfirmDialog(context, c, client, onDismissed: onDismissed);
      case InputRequest i:
        _showInputDialog(context, i, client, onDismissed: onDismissed);
      case EditorRequest e:
        _showEditorDialog(context, e, client, onDismissed: onDismissed);
      default:
        // Unknown — auto-dismiss by sending cancelled response
        client.sendUiResponse(
          ExtensionUiResponse(id: req.id, cancelled: true),
        );
        onDismissed?.call();
    }
  }

  static void _respond(
    PiRpcClient client,
    ExtensionUiResponse response, {
    VoidCallback? onDismissed,
  }) {
    client.sendUiResponse(response);
    onDismissed?.call();
  }

  static void _dismiss(
    PiRpcClient client,
    String id, {
    VoidCallback? onDismissed,
  }) {
    client.sendUiResponse(ExtensionUiResponse(id: id, cancelled: true));
    onDismissed?.call();
  }

  static void _showSelectDialog(
    BuildContext context,
    SelectRequest req,
    PiRpcClient client, {
    VoidCallback? onDismissed,
  }) {
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
                _respond(
                  client,
                  ExtensionUiResponse(id: req.id, value: opt),
                  onDismissed: onDismissed,
                );
              },
            );
          }).toList(),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _dismiss(client, req.id, onDismissed: onDismissed);
            },
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  static void _showConfirmDialog(
    BuildContext context,
    ConfirmRequest req,
    PiRpcClient client, {
    VoidCallback? onDismissed,
  }) {
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
              _respond(
                client,
                ExtensionUiResponse(id: req.id, confirmed: false),
                onDismissed: onDismissed,
              );
            },
            child: const Text('No'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _respond(
                client,
                ExtensionUiResponse(id: req.id, confirmed: true),
                onDismissed: onDismissed,
              );
            },
            child: const Text('Yes'),
          ),
        ],
      ),
    );
  }

  static void _showInputDialog(
    BuildContext context,
    InputRequest req,
    PiRpcClient client, {
    VoidCallback? onDismissed,
  }) {
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
            _respond(
              client,
              ExtensionUiResponse(id: req.id, value: value),
              onDismissed: onDismissed,
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _dismiss(client, req.id, onDismissed: onDismissed);
            },
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _respond(
                client,
                ExtensionUiResponse(id: req.id, value: controller.text),
                onDismissed: onDismissed,
              );
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  static void _showEditorDialog(
    BuildContext context,
    EditorRequest req,
    PiRpcClient client, {
    VoidCallback? onDismissed,
  }) {
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
              _dismiss(client, req.id, onDismissed: onDismissed);
            },
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _respond(
                client,
                ExtensionUiResponse(id: req.id, value: controller.text),
                onDismissed: onDismissed,
              );
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
}
