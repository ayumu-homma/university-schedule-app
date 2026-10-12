import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_schedule_mobile/core/native/native_scope_bridge.dart';
import 'package:university_schedule_mobile/features/auth/application/auth_providers.dart';
import 'package:university_schedule_mobile/features/auth/domain/auth_models.dart';
import 'package:university_schedule_mobile/features/notification/application/morning_alarm_controller.dart';
import 'package:university_schedule_mobile/features/notification/application/morning_alarm_platform.dart';
import 'package:university_schedule_mobile/features/notification/domain/morning_alarm_models.dart';

final _ownerProvider = NotifierProvider<_OwnerNotifier, String?>(
  _OwnerNotifier.new,
);

class _OwnerNotifier extends Notifier<String?> {
  @override
  String? build() => 'owner-a';

  void setOwner(String? ownerUserId) => state = ownerUserId;
}

class _PendingSynchronization {
  _PendingSynchronization(this.ownerUserId, this.completer);

  final String? ownerUserId;
  final Completer<MorningAlarmPlatformState> completer;
}

class _DelayedMorningAlarmPlatform implements MorningAlarmPlatform {
  final pending = <_PendingSynchronization>[];
  final calls = <String?>[];

  @override
  Future<MorningAlarmPlatformState> synchronizeOwner(String? ownerUserId) {
    final completer = Completer<MorningAlarmPlatformState>();
    calls.add(ownerUserId);
    pending.add(_PendingSynchronization(ownerUserId, completer));
    return completer.future;
  }

  Future<void> completeNext(MorningAlarmPlatformState value) async {
    pending.removeAt(0).completer.complete(value);
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> failNext(Object error) async {
    pending.removeAt(0).completer.completeError(error);
    await Future<void>.delayed(Duration.zero);
  }

  @override
  Future<MorningAlarmPlatformState> refresh(
    String ownerUserId, {
    NativeScopeState? expectedScope,
  }) =>
      Future.error(StateError('unused'));

  @override
  Future<MorningAlarmPlatformState> save(
    MorningAlarmSettings settings, {
    NativeScopeState? expectedScope,
  }) =>
      Future.error(StateError('unused'));

  @override
  Future<MorningAlarmPlatformState> requestNotificationPermission(
    String ownerUserId, {
    NativeScopeState? expectedScope,
  }) =>
      Future.error(StateError('unused'));

  @override
  Future<MorningAlarmPlatformState> openExactAlarmSettings(
    String ownerUserId, {
    NativeScopeState? expectedScope,
  }) =>
      Future.error(StateError('unused'));

  @override
  Future<MorningAlarmPlatformState> openFullScreenSettings(
    String ownerUserId, {
    NativeScopeState? expectedScope,
  }) =>
      Future.error(StateError('unused'));

  @override
  Future<MorningAlarmPlatformState> scheduleDebugTest(
    String ownerUserId, {
    NativeScopeState? expectedScope,
  }) =>
      Future.error(StateError('unused'));
}

MorningAlarmPlatformState _stateFor(String ownerUserId,
        {required bool enabled}) =>
    MorningAlarmPlatformState(
      ownerUserId: ownerUserId,
      settings: MorningAlarmSettings(
        ownerUserId: ownerUserId,
        enabled: enabled,
      ),
      capabilities: const MorningAlarmCapabilities.unavailable(),
      nextOccurrence: null,
    );

Future<void> _waitFor(bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt += 1) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Timed out waiting for controlled owner transition.');
}

void main() {
  test('ownership runtime cancels and rebinds across account and sign-out',
      () async {
    final platform = InMemoryMorningAlarmPlatform();
    final container = ProviderContainer(
      overrides: [
        currentAuthSessionProvider.overrideWith((ref) {
          final ownerUserId = ref.watch(_ownerProvider);
          return ownerUserId == null
              ? null
              : AppAuthSession(userId: ownerUserId);
        }),
        morningAlarmPlatformProvider.overrideWithValue(platform),
      ],
    );
    addTearDown(container.dispose);

    container.read(morningAlarmOwnershipRuntimeProvider);
    final ownerA = await container.read(morningAlarmControllerProvider.future);
    await container
        .read(morningAlarmControllerProvider.notifier)
        .updateSettings(ownerA.settings!.copyWith(enabled: true));

    container.read(_ownerProvider.notifier).setOwner('owner-b');
    final ownerB = await container.read(morningAlarmControllerProvider.future);

    expect(ownerB.ownerUserId, 'owner-b');
    expect(ownerB.settings!.enabled, isFalse);
    expect(platform.ownerCancellationCount, 1);

    container.read(_ownerProvider.notifier).setOwner(null);
    final signedOut =
        await container.read(morningAlarmControllerProvider.future);

    expect(signedOut.ownerUserId, isNull);
    expect(platform.activeOwner, isNull);
    expect(platform.ownerCancellationCount, 2);
  });

  test('ABA owner transition publishes only the final generation', () async {
    final platform = _DelayedMorningAlarmPlatform();
    final container = ProviderContainer(
      overrides: [
        currentAuthSessionProvider.overrideWith((ref) {
          final ownerUserId = ref.watch(_ownerProvider);
          return ownerUserId == null
              ? null
              : AppAuthSession(userId: ownerUserId);
        }),
        morningAlarmPlatformProvider.overrideWithValue(platform),
      ],
    );
    addTearDown(container.dispose);

    container.read(morningAlarmOwnershipRuntimeProvider);
    await _waitFor(() => platform.pending.length == 1);

    container.read(_ownerProvider.notifier).setOwner('owner-b');
    await platform.completeNext(_stateFor('owner-a', enabled: true));
    await _waitFor(() => platform.calls.length == 2);

    container.read(_ownerProvider.notifier).setOwner('owner-a');
    await platform.completeNext(_stateFor('owner-b', enabled: true));
    await _waitFor(() => platform.calls.length == 3);
    await platform.completeNext(_stateFor('owner-a', enabled: false));

    final state = await container.read(morningAlarmControllerProvider.future);
    expect(platform.calls, ['owner-a', 'owner-b', 'owner-a']);
    expect(state.ownerUserId, 'owner-a');
    expect(state.settings?.enabled, isFalse);
  });

  test('ABA owner transition ignores a stale failure before final owner',
      () async {
    final platform = _DelayedMorningAlarmPlatform();
    final container = ProviderContainer(
      overrides: [
        currentAuthSessionProvider.overrideWith((ref) {
          final ownerUserId = ref.watch(_ownerProvider);
          return ownerUserId == null
              ? null
              : AppAuthSession(userId: ownerUserId);
        }),
        morningAlarmPlatformProvider.overrideWithValue(platform),
      ],
    );
    addTearDown(container.dispose);

    container.read(morningAlarmOwnershipRuntimeProvider);
    await _waitFor(() => platform.pending.length == 1);
    container.read(_ownerProvider.notifier).setOwner('owner-b');
    await platform.completeNext(_stateFor('owner-a', enabled: false));
    await _waitFor(() => platform.calls.length == 2);

    container.read(_ownerProvider.notifier).setOwner('owner-a');
    await platform.failNext(StateError('stale owner B failure'));
    await _waitFor(() => platform.calls.length == 3);
    await platform.completeNext(_stateFor('owner-a', enabled: false));

    final state = await container.read(morningAlarmControllerProvider.future);
    expect(state.ownerUserId, 'owner-a');
    expect(state.settings?.enabled, isFalse);
  });
}
