import 'package:shared_domain/shared_domain.dart';

/// A safe, allow-listed failure crossing the trusted email endpoint boundary.
///
/// Provider diagnostics, addresses and message content must never be attached
/// to this exception or persisted by the mobile client.
class EmailImportFailure implements Exception {
  const EmailImportFailure({
    required this.connectionStatus,
    this.errorCategory,
    this.retryAfter,
  }) : assert(
          connectionStatus == EmailConnectionStatus.failed ||
              errorCategory == null,
          'Only failed connection state may carry an error category.',
        );

  factory EmailImportFailure.cursorExpired() => const EmailImportFailure(
        connectionStatus: EmailConnectionStatus.failed,
        errorCategory: EmailErrorCategory.cursorExpired,
      );

  factory EmailImportFailure.rateLimited(Duration retryAfter) =>
      EmailImportFailure(
        connectionStatus: EmailConnectionStatus.rateLimited,
        retryAfter: retryAfter,
      );

  factory EmailImportFailure.timeout() => const EmailImportFailure(
        connectionStatus: EmailConnectionStatus.failed,
        errorCategory: EmailErrorCategory.timeout,
      );

  factory EmailImportFailure.authorizationRevoked() => const EmailImportFailure(
        connectionStatus: EmailConnectionStatus.reauthRequired,
      );

  final EmailConnectionStatus connectionStatus;
  final EmailErrorCategory? errorCategory;
  final Duration? retryAfter;

  @override
  String toString() => 'EmailImportFailure(${connectionStatus.wireName})';
}
