import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_schedule_mobile/local_db/legacy_storage_receipt.dart';

void main() {
  test('receipt requires the exact source set and verifies presence/digests',
      () async {
    final root = await Directory.systemTemp.createTemp('legacy-receipt-');
    addTearDown(() => root.delete(recursive: true));
    final db = File('${root.path}/university_schedule.sqlite')
      ..writeAsStringSync('db');
    final wal = File('${root.path}/university_schedule.sqlite-wal')
      ..writeAsStringSync('wal');
    String digest(File file) =>
        sha256.convert(file.readAsBytesSync()).toString();
    final receipt = LegacyStorageReceipt.fromJson({
      'format': LegacyStorageReceipt.format,
      'approvedPurpose': LegacyStorageReceipt.approvedPurposeValue,
      'policyVersion': 'phase5-local-demo-v1',
      'sourceSchemaVersion': 17,
      'sourceFiles': {
        'db': {
          'path': 'university_schedule.sqlite',
          'present': true,
          'sha256': digest(db),
        },
        'wal': {
          'path': 'university_schedule.sqlite-wal',
          'present': true,
          'sha256': digest(wal),
        },
        'journal': {
          'path': 'university_schedule.sqlite-journal',
          'present': false,
          'sha256': null,
        },
      },
      'targetRegionId': List.filled(64, 'a').join(),
      'provenanceReference': 'docs/design/integration/phase5/legacy.json',
    });

    await receipt.verifySourceFiles(sourceRoot: root);
    wal.writeAsStringSync('tampered');
    await expectLater(
      receipt.verifySourceFiles(sourceRoot: root),
      throwsStateError,
    );
  });

  test('receipt rejects SHM identity and wrong basenames', () {
    final json = <String, Object?>{
      'format': LegacyStorageReceipt.format,
      'approvedPurpose': LegacyStorageReceipt.approvedPurposeValue,
      'policyVersion': 'phase5-local-demo-v1',
      'sourceSchemaVersion': 17,
      'sourceFiles': {
        'db': {
          'path': 'university_schedule.sqlite',
          'present': false,
          'sha256': null,
        },
        'wal': {
          'path': 'university_schedule.sqlite-wal',
          'present': false,
          'sha256': null,
        },
        'journal': {
          'path': 'university_schedule.sqlite-journal',
          'present': false,
          'sha256': null,
        },
        'shm': {
          'path': 'university_schedule.sqlite-shm',
          'present': false,
          'sha256': null,
        },
      },
      'targetRegionId': List.filled(64, 'b').join(),
      'provenanceReference': 'phase5',
    };
    expect(
      () => LegacyStorageReceipt.decode(jsonEncode(json)),
      throwsFormatException,
    );
  });
}
