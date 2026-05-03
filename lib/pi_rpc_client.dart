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
