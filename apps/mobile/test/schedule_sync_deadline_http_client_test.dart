import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:university_schedule_mobile/core/sync/schedule_sync_deadline_http_client.dart';

void main() {
  test('aborts a schedule RPC request at its configured deadline', () async {
    final inner = _InspectingClient(waitForAbort: true);
    final client = ScheduleSyncDeadlineHttpClient(
      inner: inner,
      requestTimeout: Duration.zero,
    );
    final request = http.Request(
      'POST',
      Uri.parse('https://example.test/rest/v1/rpc/apply_schedule_mutation'),
    )..body = '{}';

    await expectLater(
      client.send(request),
      throwsA(isA<http.RequestAbortedException>()),
    );

    final observed = inner.requests.single;
    expect(observed, isA<http.AbortableRequest>());
    expect((observed as http.Request).body, '{}');
  });

  test('leaves non-schedule requests unmodified', () async {
    final inner = _InspectingClient(waitForAbort: false);
    final client = ScheduleSyncDeadlineHttpClient(
      inner: inner,
      requestTimeout: Duration.zero,
    );

    await client.send(
      http.Request(
        'POST',
        Uri.parse('https://example.test/rest/v1/rpc/submit_university_request'),
      ),
    );

    final observed = inner.requests.single;
    expect(observed, isNot(isA<http.AbortableRequest>()));
    expect(observed.persistentConnection, isTrue);
  });

  test('can disable persistent connections for a controlled outage', () async {
    final inner = _InspectingClient(waitForAbort: false);
    final client = ScheduleSyncDeadlineHttpClient(
      inner: inner,
      allowPersistentConnections: false,
    );

    await client.send(
      http.Request(
        'POST',
        Uri.parse('https://example.test/rest/v1/rpc/apply_schedule_mutation'),
      ),
    );

    expect(inner.requests.single.persistentConnection, isFalse);
  });
}

class _InspectingClient extends http.BaseClient {
  _InspectingClient({required this.waitForAbort});

  final bool waitForAbort;
  final List<http.BaseRequest> requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    if (waitForAbort) {
      final abortable = request as http.AbortableRequest;
      await abortable.abortTrigger!;
      throw http.RequestAbortedException(request.url);
    }
    return http.StreamedResponse(
      Stream<List<int>>.value(const <int>[]),
      204,
      request: request,
    );
  }
}
