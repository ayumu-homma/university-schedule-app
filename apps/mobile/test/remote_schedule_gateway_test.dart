import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:university_schedule_mobile/core/sync/remote_schedule_gateway.dart';
import 'package:university_schedule_mobile/core/sync/sync_queue.dart';

void main() {
  test('template publish mutations use the owner-scoped RPC envelope',
      () async {
    String? functionName;
    Map<String, Object?>? parameters;
    final gateway = SupabaseScheduleGateway(
      rpcOverride: (name, params) async {
        functionName = name;
        parameters = params;
        return {
          'personal_course_id': 'course-1',
          'template_id': 'template-1',
          'status': 'published',
          'course_version': 2,
        };
      },
    );
    final mutation = PendingMutation(
      clientMutationId: 'mutation-1',
      ownerUserId: 'user-1',
      entityType: 'course_template_publish',
      entityId: 'course-1',
      operation: SyncOperation.submit,
      payload: {
        'id': 'course-1',
        'ownerUserId': 'user-1',
        'version': 1,
      },
      createdAt: DateTime.utc(2026, 7, 10),
    );
    final acknowledgement = await gateway.applyMutation(mutation);
    expect(functionName, 'publish_course_template');
    expect(parameters, {
      'p_user_course_id': 'course-1',
      'p_operation_id': 'mutation-1',
    });
    expect(acknowledgement.entityType, 'course_template_publish');
    expect(acknowledgement.change.serverVersion, 2);
  });

  test('Supabase gateway sends the unified JSON-safe mutation RPC', () async {
    String? functionName;
    Map<String, Object?>? parameters;
    final gateway = SupabaseScheduleGateway(
      rpcOverride: (capturedFunction, capturedParameters) async {
        functionName = capturedFunction;
        parameters = capturedParameters;
        return [
          {
            'outcome': 'applied',
            'entity_type': 'assignment',
            'entity_id': 'assignment-1',
            'operation': 'create',
            'replayed': false,
            'change': {
              'changeCursor': 7,
              'entityType': 'assignment',
              'entityId': 'assignment-1',
              'operation': 'upsert',
              'serverVersion': 1,
              'deletedAt': null,
              'payload': {
                'id': 'assignment-1',
                'ownerUserId': 'user-1',
                'title': 'レポート',
                'dueAt': '2026-07-10T03:00:00.000Z',
                'updatedAt': '2026-07-10T01:02:03.000Z',
                'visibilityLevel': 'PRIVATE',
                'version': 1,
              },
            },
          },
        ];
      },
    );
    final mutation = PendingMutation(
      clientMutationId: 'mutation-1',
      ownerUserId: 'user-1',
      entityType: 'assignment',
      entityId: 'assignment-1',
      operation: SyncOperation.create,
      payload: {
        'id': 'assignment-1',
        'ownerUserId': 'user-1',
        'title': 'レポート',
        'dueAt': DateTime.parse('2026-07-10T12:00:00+09:00'),
        'updatedAt': DateTime.parse('2026-07-10T01:02:03Z'),
        'memo': {
          'reviewedAt': DateTime.parse('2026-07-09T18:00:00-04:00'),
          'history': [DateTime.parse('2026-07-08T00:00:00Z')],
        },
        'visibilityLevel': 'PRIVATE',
        'version': 1,
      },
      createdAt: DateTime.utc(2026, 7, 10),
    );

    final acknowledgement = await gateway.applyMutation(mutation);

    expect(functionName, 'apply_schedule_mutation');
    expect(parameters?['p_idempotency_key'], 'mutation-1');
    expect(parameters?['p_entity_type'], 'assignment');
    expect(parameters?['p_entity_id'], 'assignment-1');
    expect(parameters?['p_operation'], 'create');
    expect(parameters?['p_base_version'], isNull);
    final body = parameters?['p_payload'] as Map<String, Object?>;
    expect(body['dueAt'], '2026-07-10T03:00:00.000Z');
    expect(body['updatedAt'], '2026-07-10T01:02:03.000Z');
    final description = body['memo'] as Map<String, Object?>;
    expect(description['reviewedAt'], '2026-07-09T22:00:00.000Z');
    expect(description['history'], ['2026-07-08T00:00:00.000Z']);
    expect(() => jsonEncode(parameters), returnsNormally);
    expect(acknowledgement.outcome, ScheduleMutationOutcome.applied);
    expect(acknowledgement.serverVersion, 1);
    expect(acknowledgement.changeCursor, 7);
    expect(acknowledgement.change.payload['ownerUserId'], 'user-1');
  });

  test('routine exceptions use their dedicated authenticated mutation RPC',
      () async {
    String? functionName;
    Map<String, Object?>? parameters;
    final gateway = SupabaseScheduleGateway(
      rpcOverride: (capturedFunction, capturedParameters) async {
        functionName = capturedFunction;
        parameters = capturedParameters;
        return [
          {
            'outcome': 'applied',
            'entity_type': 'event_exception',
            'entity_id': 'exception-1',
            'operation': 'update',
            'replayed': false,
            'change': {
              'changeCursor': 8,
              'entityType': 'event_exception',
              'entityId': 'exception-1',
              'operation': 'upsert',
              'serverVersion': 2,
              'deletedAt': null,
              'payload': {
                'id': 'exception-1',
                'ownerUserId': 'user-1',
                'eventId': 'routine-1',
                'recurrenceId': '2026-07-13T00:00:00.000Z',
                'mode': 'modified',
                'overrideStartAt': '2026-07-13T01:00:00.000Z',
                'overrideEndAt': '2026-07-13T02:00:00.000Z',
                'overrideTitle': '午後の復習',
                'overrideLocation': null,
                'overrideDescription': null,
                'overrideVisibility': null,
                'updatedAt': '2026-07-12T00:00:00.000Z',
                'deletedAt': null,
                'version': 2,
              },
            },
          },
        ];
      },
    );
    final mutation = PendingMutation(
      clientMutationId: 'routine-mutation-1',
      ownerUserId: 'user-1',
      entityType: 'event_exception',
      entityId: 'exception-1',
      operation: SyncOperation.update,
      baseVersion: 1,
      payload: {
        'id': 'exception-1',
        'ownerUserId': 'user-1',
        'eventId': 'routine-1',
        'recurrenceId': DateTime.parse('2026-07-13T09:00:00+09:00'),
        'mode': 'modified',
        'overrideStartAt': DateTime.parse('2026-07-13T10:00:00+09:00'),
        'overrideEndAt': DateTime.parse('2026-07-13T11:00:00+09:00'),
        'overrideTitle': '午後の復習',
        'overrideLocation': null,
        'overrideDescription': null,
        'overrideVisibility': null,
        'updatedAt': DateTime.parse('2026-07-12T09:00:00+09:00'),
        'deletedAt': null,
        'version': 2,
      },
      createdAt: DateTime.utc(2026, 7, 12),
    );

    final acknowledgement = await gateway.applyMutation(mutation);

    expect(functionName, 'apply_event_exception_mutation');
    expect(parameters?['p_idempotency_key'], 'routine-mutation-1');
    expect(parameters?['p_entity_id'], 'exception-1');
    expect(parameters?['p_operation'], 'update');
    expect(parameters?['p_base_version'], 1);
    expect(parameters, isNot(contains('p_entity_type')));
    final body = parameters?['p_payload'] as Map<String, Object?>;
    expect(body['recurrenceId'], '2026-07-13T00:00:00.000Z');
    expect(body['overrideStartAt'], '2026-07-13T01:00:00.000Z');
    expect(acknowledgement.entityType, 'event_exception');
    expect(acknowledgement.serverVersion, 2);
    expect(RemoteScheduleCall.fromMutation(mutation).table, 'event_exceptions');
  });

  test(
      'routine exception create conflict accepts a same-ID canonical tombstone',
      () async {
    String? functionName;
    final gateway = SupabaseScheduleGateway(
      rpcOverride: (capturedFunction, parameters) async {
        functionName = capturedFunction;
        expect(parameters['p_operation'], 'create');
        return [
          {
            'outcome': 'conflict',
            'entity_type': 'event_exception',
            'entity_id': 'exception-1',
            'operation': 'create',
            'server_version': 2,
            'change_cursor': 9,
            'deleted_at': '2026-07-13T01:00:00.000Z',
            'replayed': false,
            'change': {
              'changeCursor': 9,
              'entityType': 'event_exception',
              'entityId': 'exception-1',
              'operation': 'delete',
              'serverVersion': 2,
              'deletedAt': '2026-07-13T01:00:00.000Z',
              'payload': {
                'id': 'exception-1',
                'ownerUserId': 'user-1',
                'eventId': 'routine-1',
                'recurrenceId': '2026-07-13T00:00:00.000Z',
                'mode': 'cancelled',
                'overrideStartAt': null,
                'overrideEndAt': null,
                'overrideTitle': null,
                'overrideLocation': null,
                'overrideDescription': null,
                'overrideVisibility': null,
                'updatedAt': '2026-07-13T01:00:00.000Z',
                'deletedAt': '2026-07-13T01:00:00.000Z',
                'version': 2,
              },
            },
          },
        ];
      },
    );
    final mutation = PendingMutation(
      clientMutationId: 'duplicate-routine-occurrence-create',
      ownerUserId: 'user-1',
      entityType: 'event_exception',
      entityId: 'exception-1',
      operation: SyncOperation.create,
      payload: const {
        'id': 'exception-1',
        'ownerUserId': 'user-1',
        'eventId': 'routine-1',
        'recurrenceId': '2026-07-13T00:00:00.000Z',
        'mode': 'cancelled',
        'overrideStartAt': null,
        'overrideEndAt': null,
        'overrideTitle': null,
        'overrideLocation': null,
        'overrideDescription': null,
        'overrideVisibility': null,
        'updatedAt': '2026-07-13T00:00:00.000Z',
        'deletedAt': null,
        'version': 1,
      },
      createdAt: DateTime.utc(2026, 7, 13),
    );

    final acknowledgement = await gateway.applyMutation(mutation);

    expect(functionName, 'apply_event_exception_mutation');
    expect(acknowledgement.outcome, ScheduleMutationOutcome.conflict);
    expect(acknowledgement.entityId, mutation.entityId);
    expect(acknowledgement.operation, SyncOperation.create);
    expect(acknowledgement.change.operation, ScheduleDeltaOperation.delete);
    expect(acknowledgement.serverVersion, 2);
    expect(acknowledgement.changeCursor, 9);
    expect(
      acknowledgement.deletedAt,
      DateTime.utc(2026, 7, 13, 1),
    );
  });

  test('pullDelta parses a strictly ordered single-row page envelope',
      () async {
    final gateway = SupabaseScheduleGateway(
      rpcOverride: (functionName, parameters) async {
        expect(functionName, 'get_schedule_delta');
        expect(parameters, {'p_after_cursor': 4, 'p_limit': 20});
        return [
          {
            'next_cursor': 5,
            'has_more': false,
            'changes': [
              {
                'changeCursor': 5,
                'entityType': 'event',
                'entityId': 'event-1',
                'operation': 'delete',
                'serverVersion': 3,
                'deletedAt': '2026-07-10T04:00:00Z',
                'payload': {
                  'id': 'event-1',
                  'ownerUserId': 'user-1',
                  'deletedAt': '2026-07-10T04:00:00Z',
                  'updatedAt': '2026-07-10T04:00:00Z',
                  'version': 3,
                },
              },
            ],
          },
        ];
      },
    );

    final page = await gateway.pullDelta(
      ownerUserId: 'user-1',
      afterCursor: 4,
      limit: 20,
    );

    expect(page.nextCursor, 5);
    expect(page.hasMore, isFalse);
    expect(page.changes.single.operation, ScheduleDeltaOperation.delete);
    expect(page.changes.single.deletedAt, DateTime.utc(2026, 7, 10, 4));
  });

  test('pullDelta rejects an offsetless deletion timestamp', () async {
    final gateway = SupabaseScheduleGateway(
      rpcOverride: (_, __) async => [
        {
          'nextCursor': 5,
          'hasMore': false,
          'changes': [
            {
              'changeCursor': 5,
              'entityType': 'event',
              'entityId': 'event-1',
              'operation': 'delete',
              'serverVersion': 3,
              'deletedAt': '2026-07-10T04:00:00',
              'payload': {
                'id': 'event-1',
                'ownerUserId': 'user-1',
                'deletedAt': '2026-07-10T04:00:00',
                'updatedAt': '2026-07-10T04:00:00',
                'version': 3,
              },
            },
          ],
        },
      ],
    );

    await expectLater(
      gateway.pullDelta(ownerUserId: 'user-1', afterCursor: 4, limit: 20),
      throwsA(isA<RemoteScheduleProtocolException>()),
    );
  });

  test('acknowledgement identity mismatch is rejected', () async {
    final gateway = SupabaseScheduleGateway(
      rpcOverride: (_, __) async => [
        {
          'outcome': 'applied',
          'entity_type': 'exam',
          'entity_id': 'other-id',
          'operation': 'create',
          'replayed': false,
          'change': {
            'changeCursor': 1,
            'entityType': 'exam',
            'entityId': 'other-id',
            'operation': 'upsert',
            'serverVersion': 1,
            'deletedAt': null,
            'payload': {
              'id': 'other-id',
              'ownerUserId': 'user-1',
              'version': 1,
            },
          },
        },
      ],
    );

    expect(
      () => gateway.applyMutation(
        PendingMutation(
          clientMutationId: 'mutation-1',
          ownerUserId: 'user-1',
          entityType: 'exam',
          entityId: 'exam-1',
          operation: SyncOperation.create,
          payload: const {
            'id': 'exam-1',
            'ownerUserId': 'user-1',
            'version': 1,
          },
          createdAt: DateTime.utc(2026, 7, 10),
        ),
      ),
      throwsA(isA<RemoteScheduleProtocolException>()),
    );
  });

  test('mutation base-version contract mirrors the authenticated RPC',
      () async {
    final gateway = SupabaseScheduleGateway(
      rpcOverride: (_, parameters) async {
        final baseVersion = parameters['p_base_version'] as int?;
        final version = (baseVersion ?? 0) + 1;
        final operation = parameters['p_operation'] as String;
        final status = operation == 'create' ? 'inProgress' : 'submitted';
        return [
          {
            'outcome': 'applied',
            'entity_type': 'assignment_user_state',
            'entity_id': 'assignment-1',
            'operation': operation,
            'replayed': false,
            'change': {
              'changeCursor': version,
              'entityType': 'assignment_user_state',
              'entityId': 'assignment-1',
              'operation': 'upsert',
              'serverVersion': version,
              'deletedAt': null,
              'payload': {
                'assignmentId': 'assignment-1',
                'userId': 'user-1',
                'status': status,
                'updatedAt': '2026-07-10T00:00:00Z',
                'deletedAt': null,
                'version': version,
              },
            },
          },
        ];
      },
    );

    for (final baseVersion in <int?>[null, 1]) {
      final acknowledgement = await gateway.applyMutation(
        _mutationForContract(
          entityType: 'assignment_user_state',
          operation: SyncOperation.submit,
          baseVersion: baseVersion,
        ),
      );
      expect(acknowledgement.serverVersion, (baseVersion ?? 0) + 1);
    }

    final initialProgress = await gateway.applyMutation(
      _mutationForContract(
        entityType: 'assignment_user_state',
        operation: SyncOperation.create,
        stateStatus: 'inProgress',
      ),
    );
    expect(initialProgress.operation, SyncOperation.create);
    expect(initialProgress.change.operation, ScheduleDeltaOperation.upsert);
    expect(initialProgress.serverVersion, 1);

    for (final invalid in [
      _mutationForContract(
        operation: SyncOperation.create,
        baseVersion: 1,
      ),
      _mutationForContract(operation: SyncOperation.update),
      _mutationForContract(
        operation: SyncOperation.delete,
        baseVersion: 0,
      ),
      _mutationForContract(
        entityType: 'assignment_user_state',
        operation: SyncOperation.submit,
        baseVersion: -1,
      ),
    ]) {
      await expectLater(
        gateway.applyMutation(invalid),
        throwsA(isA<RemoteScheduleProtocolException>()),
      );
    }
  });

  test('temporary PostgREST failures remain retryable', () async {
    for (final code in <String?>[
      'PGRST003',
      '57014',
      '57P03',
      '408',
      '429',
      '503',
      null,
    ]) {
      final gateway = SupabaseScheduleGateway(
        rpcOverride: (_, __) async => throw PostgrestException(
          message: 'temporary failure',
          code: code,
        ),
      );

      await expectLater(
        gateway.pullDelta(ownerUserId: 'user-1', afterCursor: 0),
        throwsA(isA<RemoteScheduleTransientException>()),
        reason: 'code $code must retain the retry path',
      );
    }
  });

  test('an aborted schedule RPC becomes a retryable transport failure',
      () async {
    final gateway = SupabaseScheduleGateway(
      rpcOverride: (_, __) async => throw http.RequestAbortedException(),
    );

    await expectLater(
      gateway.pullDelta(ownerUserId: 'user-1', afterCursor: 0),
      throwsA(isA<RemoteScheduleTransientException>()),
    );
  });

  test('PostgREST authorization and validation failures stay non-transient',
      () async {
    final unauthorized = SupabaseScheduleGateway(
      rpcOverride: (_, __) async => throw const PostgrestException(
        message: 'denied',
        code: '42501',
      ),
    );
    final invalid = SupabaseScheduleGateway(
      rpcOverride: (_, __) async => throw const PostgrestException(
        message: 'invalid input',
        code: '22023',
      ),
    );

    await expectLater(
      unauthorized.pullDelta(ownerUserId: 'user-1', afterCursor: 0),
      throwsA(isA<RemoteScheduleAuthenticationException>()),
    );
    await expectLater(
      invalid.pullDelta(ownerUserId: 'user-1', afterCursor: 0),
      throwsA(
        isA<RemoteScheduleException>()
            .having((error) => error, 'type',
                isNot(isA<RemoteScheduleTransientException>()))
            .having((error) => error, 'type',
                isNot(isA<RemoteScheduleAuthenticationException>())),
      ),
    );
  });
}

PendingMutation _mutationForContract({
  String entityType = 'assignment',
  SyncOperation operation = SyncOperation.create,
  int? baseVersion,
  String stateStatus = 'submitted',
}) {
  final assignmentState = entityType == 'assignment_user_state';
  return PendingMutation(
    clientMutationId: 'mutation-contract',
    ownerUserId: 'user-1',
    entityType: entityType,
    entityId: 'assignment-1',
    operation: operation,
    payload: assignmentState
        ? {
            'assignmentId': 'assignment-1',
            'userId': 'user-1',
            'status': stateStatus,
            'version': 1,
          }
        : const {
            'id': 'assignment-1',
            'ownerUserId': 'user-1',
            'version': 1,
          },
    baseVersion: baseVersion,
    createdAt: DateTime.utc(2026, 7, 10),
  );
}
