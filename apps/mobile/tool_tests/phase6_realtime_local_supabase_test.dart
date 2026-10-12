import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:university_schedule_mobile/core/sync/remote_schedule_gateway.dart';
import 'package:university_schedule_mobile/core/sync/sync_queue.dart';
import 'package:uuid/uuid.dart';

void main() {
  test(
    'private schedule realtime enforces owner topics and broadcasts invalidation',
    () async {
      final environment = _LocalSupabaseEnvironment.fromProcess();
      final clientA = _newClient(environment);
      final clientB = _newClient(environment);
      RealtimeChannel? channelA;
      RealtimeChannel? channelBOwn;
      RealtimeChannel? channelBForeign;
      final invalidationsA = <Map<String, dynamic>>[];
      final invalidationsB = <Map<String, dynamic>>[];

      try {
        final identity = const Uuid().v4();
        final password = 'Realtime-${const Uuid().v4()}-Aa1!';
        final emailA = 'phase6-realtime-a-$identity@example.test';
        final emailB = 'phase6-realtime-b-$identity@example.test';
        final signUpA = await clientA.auth.signUp(
          email: emailA,
          password: password,
        );
        final userA = signUpA.user?.id;
        if (userA == null || signUpA.session == null) {
          throw StateError(
              'Local Supabase did not create an immediate A session.');
        }
        final signUpB = await clientB.auth.signUp(
          email: emailB,
          password: password,
        );
        final userB = signUpB.user?.id;
        if (userB == null || signUpB.session == null) {
          throw StateError(
              'Local Supabase did not create an immediate B session.');
        }

        channelA = clientA
            .channel(
              'schedule-sync:$userA',
              opts: const RealtimeChannelConfig(
                private: true,
                ack: true,
                self: true,
              ),
            )
            .onBroadcast(
              event: 'invalidate',
              callback: invalidationsA.add,
            );
        channelBOwn = clientB
            .channel(
              'schedule-sync:$userB',
              opts: const RealtimeChannelConfig(private: true, ack: true),
            )
            .onBroadcast(
              event: 'invalidate',
              callback: invalidationsB.add,
            );
        channelBForeign = clientB.channel(
          'schedule-sync:$userA',
          opts: const RealtimeChannelConfig(private: true, ack: true),
        );

        final ownA = await _subscribe(channelA);
        expect(
          ownA.status,
          RealtimeSubscribeStatus.subscribed,
          reason: ownA.safeReason,
        );
        final ownB = await _subscribe(channelBOwn);
        expect(
          ownB.status,
          RealtimeSubscribeStatus.subscribed,
          reason: ownB.safeReason,
        );
        final foreignB = await _subscribe(channelBForeign);
        expect(
          foreignB.status,
          RealtimeSubscribeStatus.channelError,
          reason: foreignB.safeReason,
        );

        // A client-originated invalidation must never be accepted as a server
        // hint. self=true makes a successful forged send observable here.
        await channelA.sendBroadcastMessage(
          event: 'invalidate',
          payload: {'cursor': -1},
        );
        expect(invalidationsA, isEmpty);
        final accessTokenA = clientA.auth.currentSession!.accessToken;
        final httpAtoA = await _httpBroadcast(
          environment: environment,
          topic: 'schedule-sync:$userA',
          accessToken: accessTokenA,
        );
        expect(httpAtoA.statusCode, 403);
        final httpAtoB = await _httpBroadcast(
          environment: environment,
          topic: 'schedule-sync:$userB',
          accessToken: accessTokenA,
        );
        expect(httpAtoB.statusCode, 403);

        final assignmentId = const Uuid().v4();
        final title = 'Realtime private assignment $identity';
        final dueAt = DateTime.now().toUtc().add(const Duration(days: 1));
        final mutation = PendingMutation(
          clientMutationId: const Uuid().v4(),
          ownerUserId: userA,
          entityType: 'assignment',
          entityId: assignmentId,
          operation: SyncOperation.create,
          createdAt: DateTime.now().toUtc(),
          payload: {
            'id': assignmentId,
            'ownerUserId': userA,
            'title': title,
            'dueAt': dueAt.toIso8601String(),
            'submissionUrl': null,
            'memo': 'realtime probe',
            'priority': 'normal',
            'visibilityLevel': 'PRIVATE',
            'version': 1,
          },
        );
        final eventFuture = _waitForInvalidation(invalidationsA);
        final acknowledgement = await SupabaseScheduleGateway(
          client: clientA,
        ).applyMutation(mutation);
        expect(acknowledgement.outcome, ScheduleMutationOutcome.applied);

        final invalidation = await eventFuture;
        final invalidationPayload = Map<String, dynamic>.from(
          invalidation['payload'] as Map,
        );
        expect(
          invalidationPayload.keys.where((key) => key != 'id').toSet(),
          {'cursor'},
        );
        expect(invalidationPayload['cursor'], isA<num>());
        expect(
          invalidationPayload['cursor'],
          acknowledgement.change.changeCursor,
        );
        expect(
          invalidationPayload['id'],
          matches(
            RegExp(
              r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
              caseSensitive: false,
            ),
          ),
        );
        final delta = await SupabaseScheduleGateway(client: clientA).pullDelta(
          ownerUserId: userA,
          afterCursor: 0,
        );
        final changed = delta.changes.singleWhere(
          (change) => change.entityId == assignmentId,
        );
        expect(changed.payload['title'], title);
        expect(changed.payload['ownerUserId'], userA);
        await Future<void>.delayed(const Duration(milliseconds: 500));
        expect(invalidationsB, isEmpty);

        await expectLater(
          SupabaseScheduleGateway(client: clientB).pullDelta(
            ownerUserId: userA,
            afterCursor: 0,
          ),
          throwsA(isA<RemoteScheduleAuthenticationException>()),
        );
      } finally {
        if (channelBForeign != null) {
          await clientB.removeChannel(channelBForeign);
        }
        if (channelBOwn != null) {
          await clientB.removeChannel(channelBOwn);
        }
        if (channelA != null) {
          await clientA.removeChannel(channelA);
        }
        await clientB.dispose();
        await clientA.dispose();
      }
    },
    timeout: const Timeout(Duration(seconds: 35)),
  );
}

Future<http.Response> _httpBroadcast({
  required _LocalSupabaseEnvironment environment,
  required String topic,
  required String accessToken,
}) {
  return http.post(
    Uri.parse(
      '${environment.url}/realtime/v1/api/broadcast/'
      '${Uri.encodeComponent(topic)}/events/client-http-probe?private=true',
    ),
    headers: {
      'apikey': environment.publishableKey,
      'Authorization': 'Bearer $accessToken',
      'Content-Type': 'application/json',
    },
    body: jsonEncode(const {'source': 'client'}),
  );
}

Future<Map<String, dynamic>> _waitForInvalidation(
  List<Map<String, dynamic>> events,
) async {
  return _pollForInvalidation(events).timeout(
    const Duration(seconds: 8),
    onTimeout: () => throw StateError('invalidation event timed out'),
  );
}

Future<Map<String, dynamic>> _pollForInvalidation(
  List<Map<String, dynamic>> events,
) async {
  while (true) {
    if (events.isNotEmpty) {
      return events.last;
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

Future<_SubscriptionResult> _subscribe(RealtimeChannel channel) async {
  final completer = Completer<_SubscriptionResult>();
  channel.subscribe((status, error) {
    if (completer.isCompleted) return;
    if (status == RealtimeSubscribeStatus.subscribed ||
        status == RealtimeSubscribeStatus.channelError ||
        status == RealtimeSubscribeStatus.closed ||
        status == RealtimeSubscribeStatus.timedOut) {
      completer.complete(_SubscriptionResult(status, error));
    }
  });
  return completer.future.timeout(
    const Duration(seconds: 8),
    onTimeout: () =>
        const _SubscriptionResult(RealtimeSubscribeStatus.timedOut),
  );
}

class _SubscriptionResult {
  const _SubscriptionResult(this.status, [this.error]);

  final RealtimeSubscribeStatus status;
  final Object? error;

  String get safeReason =>
      'subscription status=${status.name}; callbackError=${error?.runtimeType}';
}

class _LocalSupabaseEnvironment {
  const _LocalSupabaseEnvironment({
    required this.url,
    required this.publishableKey,
  });

  factory _LocalSupabaseEnvironment.fromProcess() {
    if (Platform.environment['UNIVERSITY_SCHEDULE_LOCAL_SYNC_TEST'] != '1') {
      throw StateError(
        'Set UNIVERSITY_SCHEDULE_LOCAL_SYNC_TEST=1 through the safe runner.',
      );
    }
    final rawUrl = Platform.environment['LOCAL_SUPABASE_URL']?.trim() ?? '';
    final publishableKey =
        Platform.environment['LOCAL_SUPABASE_PUBLISHABLE_KEY']?.trim() ?? '';
    final uri = Uri.tryParse(rawUrl);
    final isLoopback = uri != null &&
        uri.hasAuthority &&
        uri.scheme == 'http' &&
        (uri.host == '127.0.0.1' ||
            uri.host == 'localhost' ||
            uri.host == '::1');
    if (!isLoopback) {
      throw StateError('The realtime harness only accepts loopback HTTP.');
    }
    if (publishableKey.isEmpty) {
      throw StateError('A local public Supabase client key is required.');
    }
    return _LocalSupabaseEnvironment(
      url: rawUrl.replaceFirst(RegExp(r'/$'), ''),
      publishableKey: publishableKey,
    );
  }

  final String url;
  final String publishableKey;
}

SupabaseClient _newClient(_LocalSupabaseEnvironment environment) {
  return SupabaseClient(
    environment.url,
    environment.publishableKey,
    authOptions: const AuthClientOptions(
      autoRefreshToken: false,
      authFlowType: AuthFlowType.implicit,
    ),
  );
}
