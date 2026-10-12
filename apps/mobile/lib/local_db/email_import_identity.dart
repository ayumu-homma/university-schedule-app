import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Hashes a provider identifier with account and purpose domain separation.
/// Raw message and thread identifiers must never enter dismissal tombstones.
String emailProviderIdentifierHash({
  required String kind,
  required String provider,
  required String providerAccountHash,
  required String rawIdentifier,
}) {
  final input = [
    'university-schedule-email-import-v1',
    kind,
    provider,
    providerAccountHash,
    rawIdentifier,
  ].join('\u0000');
  return sha256.convert(utf8.encode(input)).toString();
}
