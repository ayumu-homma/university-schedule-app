import 'dart:async';

import 'package:drift/drift.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../native/sqlite_identity_handshake.dart';

typedef StorageCorruptionRecorder = Future<void> Function(
  String region,
  String reason,
);
typedef StorageHealthChecker = Future<void> Function(String region);

/// Gives a competing canonical connection a bounded window to release its
/// transaction. SQLite's default busy timeout is zero, so production worker
/// connections must install this before Drift migrations or queries run.
const sqliteBusyTimeoutMilliseconds = 2500;

/// Thrown after a canonical storage corruption has been latched.
///
/// The latch is deliberately local to the Drift worker. The native bridge is
/// the durable source of truth, and this local latch closes the small window
/// between recording the marker and the next queued request reaching SQLite.
final class SqliteStorageLatchedException implements Exception {
  const SqliteStorageLatchedException(this.regionId);

  final String regionId;

  @override
  String toString() => 'SqliteStorageLatchedException($regionId)';
}

/// Combines the SQLite failure with a failure to persist the durable health
/// marker. Callers must see both: continuing silently would make recovery
/// appear safe while the native latch may not have been written.
final class SqliteStorageCorruptionException implements Exception {
  const SqliteStorageCorruptionException({
    required this.original,
    required this.originalStack,
    required this.markerCause,
    required this.markerStack,
  });

  final Object original;
  final StackTrace originalStack;
  final Object markerCause;
  final StackTrace markerStack;

  @override
  String toString() =>
      'SqliteStorageCorruptionException(original: $original, marker: $markerCause)';
}

/// Intercepts every production Drift operation in the isolate that owns the
/// SQLite handle. It is intentionally attached after [NativeDatabase] is
/// created in the worker, so the guard covers the real executor rather than a
/// foreground proxy.
final class SqliteStorageGuard extends QueryInterceptor {
  SqliteStorageGuard({
    required this.regionId,
    StorageCorruptionRecorder? recordCorruption,
    StorageHealthChecker? checkHealth,
  })  : _recordCorruption = recordCorruption ??
            ((region, reason) => const SqliteIdentityHandshake()
                .recordCorruption(region, reason: reason)),
        _checkHealth = checkHealth ??
            ((region) => const SqliteIdentityHandshake().checkHealth(region));

  final String regionId;
  final StorageCorruptionRecorder _recordCorruption;
  final StorageHealthChecker _checkHealth;

  bool _latched = false;
  Future<void>? _latchFuture;
  Object? _latchFailure;

  bool get isLatched => _latched;
  Object? get latchFailure => _latchFailure;

  void _ensureHealthy() {
    if (_latched) {
      throw SqliteStorageLatchedException(regionId);
    }
  }

  Future<T> _run<T>(Future<T> Function() operation) async {
    try {
      await _ensureHealthyAsync();
      final result = await operation();
      // A concurrent request may have latched while this SQL operation was
      // already executing. Do not cancel that SQL; reject its result and all
      // subsequent work once the latch is observed.
      _ensureHealthy();
      return result;
    } catch (error, stack) {
      if (_isCorruption(error)) {
        await _latch(error, stack);
        final markerFailure = _latchFailure;
        if (markerFailure is _LatchedMarkerFailure) {
          Error.throwWithStackTrace(
            SqliteStorageCorruptionException(
              original: error,
              originalStack: stack,
              markerCause: markerFailure.error,
              markerStack: markerFailure.stackTrace,
            ),
            stack,
          );
        }
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  Future<void> _ensureHealthyAsync() async {
    _ensureHealthy();
    try {
      await _checkHealth(regionId);
    } catch (error, stack) {
      _latched = true;
      Error.throwWithStackTrace(error, stack);
    }
    _ensureHealthy();
  }

  Future<void> _runVoid(Future<void> Function() operation) =>
      _run<void>(operation);

  Future<void> _latch(Object error, StackTrace stack) {
    _latched = true;
    return _latchFuture ??= _recordLatch(error, stack);
  }

  Future<void> _recordLatch(Object error, StackTrace stack) async {
    final reason = _corruptionReason(error);
    try {
      await _recordCorruption(regionId, reason);
    } catch (latchError, latchStack) {
      // The original SQLite exception remains the error thrown to the caller.
      // Keep the marker failure observable for diagnostics and focused tests.
      _latchFailure = _LatchedMarkerFailure(latchError, latchStack);
    }
  }

  @override
  Future<bool> ensureOpen(QueryExecutor executor, QueryExecutorUser user) =>
      _run(() => executor.ensureOpen(user));

  @override
  Future<void> runBatched(
    QueryExecutor executor,
    BatchedStatements statements,
  ) =>
      _runVoid(() => executor.runBatched(statements));

  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) =>
      _runVoid(() => executor.runCustom(statement, args));

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) =>
      _run(() => executor.runInsert(statement, args));

  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) =>
      _run(() => executor.runDelete(statement, args));

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) =>
      _run(() => executor.runUpdate(statement, args));

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) =>
      _run(() => executor.runSelect(statement, args));

  @override
  TransactionExecutor beginTransaction(QueryExecutor parent) {
    _ensureHealthy();
    try {
      return parent.beginTransaction();
    } catch (error, stack) {
      if (_isCorruption(error)) {
        unawaited(_latch(error, stack));
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  @override
  QueryExecutor beginExclusive(QueryExecutor parent) {
    _ensureHealthy();
    try {
      return parent.beginExclusive();
    } catch (error, stack) {
      if (_isCorruption(error)) {
        unawaited(_latch(error, stack));
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  @override
  Future<void> commitTransaction(TransactionExecutor inner) =>
      _runVoid(inner.send);

  @override
  Future<void> rollbackTransaction(TransactionExecutor inner) =>
      // Rollback remains available after a corruption latch so an in-flight
      // transaction can release its SQLite state deterministically.
      _runAllowLatched(inner.rollback);

  Future<T> _runAllowLatched<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } catch (error, stack) {
      if (_isCorruption(error)) {
        await _latch(error, stack);
        final markerFailure = _latchFailure;
        if (markerFailure is _LatchedMarkerFailure) {
          Error.throwWithStackTrace(
            SqliteStorageCorruptionException(
              original: error,
              originalStack: stack,
              markerCause: markerFailure.error,
              markerStack: markerFailure.stackTrace,
            ),
            stack,
          );
        }
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  @override
  Future<void> close(QueryExecutor inner) => _runAllowLatched(inner.close);

  static bool isCorruption(Object error) => _isCorruption(error);

  static String corruptionReason(Object error) {
    return _corruptionReason(error);
  }

  static bool _isCorruption(Object error) {
    return error is sqlite.SqliteException &&
        const {10, 11, 26}.contains(error.resultCode);
  }

  static String _corruptionReason(Object error) {
    if (error is sqlite.SqliteException) {
      return 'sqlite_result_${error.resultCode}';
    }
    return 'sqlite_corruption';
  }
}

final class _LatchedMarkerFailure {
  const _LatchedMarkerFailure(this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;

  @override
  String toString() => '$_LatchedMarkerFailure($error)';
}
