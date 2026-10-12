import 'dart:async';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:university_schedule_mobile/core/config/app_config.dart';
import 'package:university_schedule_mobile/core/config/app_config_provider.dart';
import 'package:university_schedule_mobile/features/auth/application/auth_providers.dart';
import 'package:university_schedule_mobile/features/auth/domain/auth_models.dart';
import 'package:university_schedule_mobile/features/email_import/application/email_reconciliation_runtime.dart';
import 'package:university_schedule_mobile/features/email_import/application/email_review_providers.dart';
import 'package:university_schedule_mobile/features/email_import/data/email_import_failure.dart';
import 'package:university_schedule_mobile/features/email_import/domain/email_reconciliation.dart';
import 'package:university_schedule_mobile/features/timetable/application/schedule_sync_runtime.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart' as local;
import 'package:university_schedule_mobile/local_db/app_database_provider.dart';

void main() {
  test('disabled production flag never invokes reconciliation', () async {
    final gateway = _Gateway();
    final container = ProviderContainer(
      overrides: [
        appConfigProvider.overrideWithValue(_config(enabled: false)),
        currentAuthSessionProvider.overrideWithValue(
          const AppAuthSession(userId: 'owner-a'),
        ),
        emailNetworkAvailableProvider.overrideWith(
          (ref) => Stream.value(true),
        ),
        emailReconciliationGatewayProvider.overrideWithValue(gateway),
        scheduleSyncRuntimeProvider.overrideWith(_StaticScheduleRuntime.new),
      ],
    );
    addTearDown(container.dispose);

    expect(
      container.read(emailReconciliationRuntimeProvider).phase,
      EmailReconciliationRuntimePhase.disabled,
    );
    await container.read(emailReconciliationRuntimeProvider.notifier).trigger();
    expect(gateway.requests, isEmpty);
  });

  test('online authenticated runtime drains owner receipt; offline does not',
      () async {
    final db = local.AppDatabase(NativeDatabase.memory());
    final gateway = _Gateway();
    await _seedDismissal(db);
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-publishable-key',
    );
    // The public provider exposes bool rather than connector-specific values.
    final network = StreamController<bool>();
    final container = ProviderContainer(
      overrides: [
        appConfigProvider.overrideWithValue(_config(enabled: true)),
        supabaseClientProvider.overrideWithValue(client),
        appDatabaseProvider.overrideWithValue(db),
        currentAuthSessionProvider.overrideWithValue(
          const AppAuthSession(userId: 'owner-a'),
        ),
        emailNetworkAvailableProvider.overrideWith((ref) => network.stream),
        emailReconciliationGatewayProvider.overrideWithValue(gateway),
        scheduleSyncRuntimeProvider.overrideWith(_StaticScheduleRuntime.new),
      ],
    );
    addTearDown(() async {
      await network.close();
      container.dispose();
      await db.close();
      client.dispose();
    });
    final subscription = container.listen(
      emailReconciliationRuntimeProvider,
      (_, __) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);

    network.add(false);
    await Future<void>.delayed(Duration.zero);
    expect(
      container.read(emailReconciliationRuntimeProvider).phase,
      EmailReconciliationRuntimePhase.offline,
    );
    await container.read(emailReconciliationRuntimeProvider.notifier).trigger();
    expect(gateway.requests, isEmpty);

    network.add(true);
    await Future<void>.delayed(Duration.zero);
    await container.read(emailReconciliationRuntimeProvider.notifier).trigger();
    final receipt =
        (await db.select(db.emailReconciliationReceipts).get()).single;
    expect(receipt.state, 'succeeded');
    expect(gateway.requests, hasLength(1));
    expect(gateway.requests.single.action, EmailReconciliationAction.dismissal);
  });

  test('online runtime wakes when a new durable receipt is created', () async {
    final db = local.AppDatabase(NativeDatabase.memory());
    final gateway = _Gateway();
    await _seedConnection(db);
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-publishable-key',
    );
    final container = ProviderContainer(
      overrides: [
        appConfigProvider.overrideWithValue(_config(enabled: true)),
        supabaseClientProvider.overrideWithValue(client),
        appDatabaseProvider.overrideWithValue(db),
        currentAuthSessionProvider.overrideWithValue(
          const AppAuthSession(userId: 'owner-a'),
        ),
        emailNetworkAvailableProvider.overrideWith(
          (ref) => Stream.value(true),
        ),
        emailReconciliationGatewayProvider.overrideWithValue(gateway),
        scheduleSyncRuntimeProvider.overrideWith(_StaticScheduleRuntime.new),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
      client.dispose();
    });
    final subscription = container.listen(
      emailReconciliationRuntimeProvider,
      (_, __) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);

    await Future<void>.delayed(Duration.zero);
    expect(gateway.requests, isEmpty);
    await _insertDismissalReceipt(db, id: 'dismissal:created-online');
    await _waitUntil(() async {
      final receipt = await (db.select(db.emailReconciliationReceipts)
            ..where((row) => row.id.equals('dismissal:created-online')))
          .getSingle();
      return receipt.state == 'succeeded';
    });

    expect(gateway.requests, hasLength(1));
  });

  test('transient failure retries at its durable retry deadline', () async {
    final db = local.AppDatabase(NativeDatabase.memory());
    final gateway = _Gateway()
      ..failureOnce = EmailImportFailure.rateLimited(
        const Duration(milliseconds: 40),
      );
    await _seedDismissal(db);
    final succeededReceipt = db
        .select(db.emailReconciliationReceipts)
        .watchSingle()
        .firstWhere((receipt) => receipt.state == 'succeeded');
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-publishable-key',
    );
    final container = ProviderContainer(
      overrides: [
        appConfigProvider.overrideWithValue(_config(enabled: true)),
        supabaseClientProvider.overrideWithValue(client),
        appDatabaseProvider.overrideWithValue(db),
        currentAuthSessionProvider.overrideWithValue(
          const AppAuthSession(userId: 'owner-a'),
        ),
        emailNetworkAvailableProvider.overrideWith(
          (ref) => Stream.value(true),
        ),
        emailReconciliationGatewayProvider.overrideWithValue(gateway),
        scheduleSyncRuntimeProvider.overrideWith(_StaticScheduleRuntime.new),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
      client.dispose();
    });
    final subscription = container.listen(
      emailReconciliationRuntimeProvider,
      (_, __) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);

    final receipt = await succeededReceipt.timeout(
      const Duration(seconds: 2),
      onTimeout: () => throw TestFailure(
        'Timed out waiting for reconciliation runtime progress.',
      ),
    );

    expect(gateway.requests, hasLength(2));
    expect(receipt.attemptCount, 2);
    expect(receipt.nextRetryAt, null);
  });
}

AppConfig _config({required bool enabled}) {
  return AppConfig.validated(
    environment: 'test',
    demoMode: false,
    supabaseUrl: 'http://127.0.0.1:54321',
    supabasePublishableKey: 'test-publishable-key',
    emailImportEnabled: enabled,
    emailImportGmailClientId:
        enabled ? 'mobile-public.apps.googleusercontent.com' : '',
  );
}

Future<void> _seedDismissal(local.AppDatabase db) async {
  await _seedConnection(db);
  await _insertDismissalReceipt(db, id: 'dismissal:runtime');
}

Future<void> _seedConnection(local.AppDatabase db) async {
  await db.into(db.emailConnections).insert(
        local.EmailConnectionsCompanion.insert(
          id: _connectionId,
          ownerUserId: 'owner-a',
          provider: 'gmail',
          providerAccountHash: 'a' * 64,
          state: const Value('connected'),
        ),
      );
}

Future<void> _insertDismissalReceipt(
  local.AppDatabase db, {
  required String id,
}) async {
  await db.into(db.emailReconciliationReceipts).insert(
        local.EmailReconciliationReceiptsCompanion.insert(
          id: id,
          ownerUserId: 'owner-a',
          connectionId: _connectionId,
          action: 'dismissal',
          localReferenceId: 'runtime',
          provider: 'gmail',
          providerAccountHash: 'a' * 64,
          providerMessageIdHash: 'b' * 64,
          providerThreadIdHash: 'c' * 64,
          sanitizedContentHash: 'd' * 64,
          idempotencyKey: 'dismissal-runtime-key',
        ),
      );
}

Future<void> _waitUntil(
  Future<bool> Function() predicate, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for reconciliation runtime progress.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class _Gateway implements EmailReconciliationGateway {
  final requests = <EmailReconciliationRequest>[];
  Object? failureOnce;

  @override
  Future<EmailReconciliationResult> reconcile(
    EmailReconciliationRequest request,
  ) async {
    requests.add(request);
    final failure = failureOnce;
    failureOnce = null;
    if (failure != null) throw failure;
    return EmailReconciliationResult(
      connectionId: request.connectionId,
      idempotencyKey: request.idempotencyKey,
      action: request.action,
      outcome: EmailReconciliationOutcome.dismissed,
      entityType: null,
      entityId: null,
      replayed: false,
    );
  }
}

class _StaticScheduleRuntime extends ScheduleSyncRuntimeController {
  @override
  ScheduleSyncStatus build() => const ScheduleSyncStatus.disabled();
}

const _connectionId = '11111111-1111-4111-8111-111111111111';
