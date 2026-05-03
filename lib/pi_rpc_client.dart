import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

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

    _process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
      (line) {
        if (_disposed) return;
        try {
          final json = jsonDecode(line) as Map<String, dynamic>;
          if (json['type'] == 'response') {
            _responseController.add(json);
          } else {
            _eventController.add(json);
          }
        } catch (_) {}
      },
      onError: (_) {},
    );

    _process!.stderr.transform(utf8.decoder).listen(
          (data) => debugPrint('[pi stderr] $data'),
        );

    _process!.exitCode.then((_) {
      if (!_disposed) {
        _eventController.add({'type': 'process_exit'});
      }
    });
  }

  String send(Map<String, dynamic> command) {
    final id = 'req-${_reqId++}';
    command['id'] = id;
    _process?.stdin.write('${jsonEncode(command)}\n');
    _process?.stdin.flush();
    return id;
  }

  Future<Map<String, dynamic>?> request(Map<String, dynamic> command,
      {Duration timeout = const Duration(seconds: 10)}) async {
    final id = send(command);
    final completer = Completer<Map<String, dynamic>?>();
    late StreamSubscription<Map<String, dynamic>> sub;
    sub = responses.listen((response) {
      if (response['id'] == id) {
        completer.complete(response);
        sub.cancel();
      }
    });
    Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.complete(null);
        sub.cancel();
      }
    });
    return completer.future;
  }

  Future<void> dispose() async {
    _disposed = true;
    await _eventController.close();
    await _responseController.close();
    _process?.kill();
  }
}
