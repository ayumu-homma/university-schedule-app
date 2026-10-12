/// A permanently revocable binding between an async operation and the
/// owner/database context that created it.
///
/// Providers create one lease after watching both auth and database. Rebuilds
/// dispose the provider and revoke the lease, so a delayed response cannot
/// write through a live owner lookup or a replaced database instance.
final class ScopedContextLease {
  ScopedContextLease({required this.ownerUserId, required this.database});

  final String ownerUserId;
  final Object database;
  bool _revoked = false;

  bool get isRevoked => _revoked;

  void revoke() {
    _revoked = true;
  }

  void check({required String ownerUserId, required Object database}) {
    if (_revoked ||
        ownerUserId != this.ownerUserId ||
        !identical(database, this.database)) {
      throw const ScopedContextLeaseException();
    }
  }
}

class ScopedContextLeaseException implements Exception {
  const ScopedContextLeaseException();

  @override
  String toString() => 'ScopedContextLeaseException(revoked)';
}
