import 'package:flutter_test/flutter_test.dart';

import 'package:university_schedule_mobile/features/friends/application/friend_providers.dart';

void main() {
  test('lease closes at request-start deadline and invokes the gate callback',
      () async {
    var expired = false;
    final lease = FriendAuthorizationLease(
      ttl: const Duration(milliseconds: 20),
      onExpired: () => expired = true,
    );
    expect(lease.isValid, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 35));
    expect(expired, isTrue);
    expect(lease.isValid, isFalse);
  });

  test('closing a lease prevents a delayed expiry callback', () async {
    var expired = false;
    final lease = FriendAuthorizationLease(
      ttl: const Duration(milliseconds: 20),
      onExpired: () => expired = true,
    )..close();
    await Future<void>.delayed(const Duration(milliseconds: 35));
    expect(expired, isFalse);
    expect(lease.isValid, isFalse);
  });
}
