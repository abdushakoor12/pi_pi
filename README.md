# Pi Pi

A Flutter desktop GUI frontend for the [`pi`](https://github.com/badlogic/pi-mono/tree/main/packages/coding-agent) AI coding agent.

Pi Pi provides a chat-based interface to interact with `pi`, supporting streaming responses, tool call visualization, session history, project management, and more.

## Architecture

Pi Pi communicates with the `pi` CLI agent through a JSON-RPC protocol over stdin/stdout:

- [`PiRpcClient`](lib/pi_rpc_client.dart) spawns `pi --mode rpc` and sends/receives JSON messages line-by-line
- The chat UI listens for streaming events (`message_start`, `message_update`, `tool_execution_start/end`, etc.)

## Getting Started

### Prerequisites

- [Flutter SDK](https://flutter.dev/docs/get-started/install) (3.x or later)
- The `pi` CLI agent installed and available on your PATH

### Run

```bash
flutter run -d macos
```