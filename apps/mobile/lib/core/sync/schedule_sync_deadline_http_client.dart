import 'package:http/http.dart' as http;

const _scheduleSyncRpcPaths = <String>{
  '/rest/v1/rpc/apply_schedule_mutation',
  '/rest/v1/rpc/apply_event_exception_mutation',
  '/rest/v1/rpc/get_schedule_delta',
};

/// Aborts only schedule-sync RPCs that do not complete promptly.
///
/// The authenticated queue keeps its idempotency key when it retries a
/// mutation, so an aborted request cannot create a second server-side change
/// if the server committed just before the response was interrupted.
class ScheduleSyncDeadlineHttpClient extends http.BaseClient {
  ScheduleSyncDeadlineHttpClient({
    http.Client? inner,
    this.requestTimeout = defaultRequestTimeout,
    this.allowPersistentConnections = true,
  })  : _inner = inner ?? http.Client(),
        assert(!requestTimeout.isNegative);

  static const defaultRequestTimeout = Duration(seconds: 10);

  final http.Client _inner;
  final Duration requestTimeout;
  final bool allowPersistentConnections;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (!allowPersistentConnections) request.persistentConnection = false;
    if (!_requiresScheduleSyncDeadline(request)) return _inner.send(request);

    final deadlineRequest = http.AbortableRequest(
      request.method,
      request.url,
      abortTrigger: Future<void>.delayed(requestTimeout),
    )
      ..followRedirects = request.followRedirects
      ..maxRedirects = request.maxRedirects
      ..persistentConnection = request.persistentConnection
      ..headers.addAll(request.headers)
      ..bodyBytes = await request.finalize().toBytes();
    return _inner.send(deadlineRequest);
  }

  @override
  void close() => _inner.close();

  bool _requiresScheduleSyncDeadline(http.BaseRequest request) {
    return request.method == 'POST' &&
        _scheduleSyncRpcPaths.contains(request.url.path);
  }
}
