import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

/// Neutralizes measured CPU-profiler interference with SQLite's native waits.
/// Only the current test VM is affected; the original flag is restored.
/// This does not establish SQLite behavior in a profiled app or on a device.
Future<T> withoutSqliteProfilerInterference<T>(
  Future<T> Function() action,
) async {
  final service = await developer.Service.getInfo();
  // Windows native waits passed without this Linux profiler workaround.
  if (service.serverUri == null && !Platform.isLinux) return action();
  if (service.serverUri == null) {
    throw StateError('Run SQLite timing tests with --enable-vmservice');
  }
  WebSocket? socket;
  String? original;
  Future<Map<String, dynamic>> Function(String, [Map<String, String>?])? rpc;
  Future<String> Function()? profilerValue;
  try {
    final uri = service.serverUri;
    if (uri == null ||
        uri.scheme != 'http' ||
        !const ['127.0.0.1', 'localhost', '::1'].contains(uri.host)) {
      throw StateError('SQLite test requires its own loopback VM service');
    }
    try {
      socket = await WebSocket.connect(
        uri.replace(scheme: 'ws', path: '${uri.path}ws').toString(),
      ).timeout(const Duration(seconds: 5));
    } catch (_) {
      throw StateError('Cannot connect to SQLite test VM service');
    }
    final connection = socket;
    final messages = connection
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .asBroadcastStream();
    var requestId = 0;
    rpc = (String method, [Map<String, String>? params]) async {
      final id = ++requestId;
      final response = messages
          .firstWhere((message) => message['id'] == id)
          .timeout(const Duration(seconds: 5));
      connection.add(jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        if (params != null) 'params': params
      }));
      final Map<String, dynamic> result;
      try {
        result = await response;
      } catch (_) {
        throw StateError('SQLite test VM response unavailable');
      }
      if (result.containsKey('error')) {
        throw StateError('SQLite test VM RPC failed');
      }
      return result['result'] as Map<String, dynamic>;
    };
    final call = rpc;
    profilerValue = () async {
      final flags = (await call('getFlagList'))['flags'] as List<dynamic>;
      return flags.cast<Map<String, dynamic>>().singleWhere(
            (flag) => flag['name'] == 'profiler',
          )['valueAsString'] as String;
    };
    original = await profilerValue();
    if (!const ['true', 'false'].contains(original)) {
      throw StateError('Unsupported test VM profiler value');
    }
    await call('setFlag', {'name': 'profiler', 'value': 'false'});
    if (await profilerValue() != 'false') {
      throw StateError('Test VM profiler was not disabled');
    }
    // Fixed flag values only; never print service URI/auth code or raw replies.
    // ignore: avoid_print
    print(jsonEncode({
      'sqlite_profiler_control': true,
      'before': original,
      'during': 'false'
    }));
    return await action();
  } finally {
    try {
      if (original != null && rpc != null && profilerValue != null) {
        await rpc('setFlag', {'name': 'profiler', 'value': original});
        if (await profilerValue() != original) {
          throw StateError('Test VM profiler was not restored');
        }
      }
    } finally {
      await socket?.close();
    }
  }
}
