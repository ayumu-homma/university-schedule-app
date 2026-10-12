import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Exact receipt filename used for an explicit local-demo legacy adoption.
const legacyStorageReceiptRelativePath =
    'migration/legacy-demo-receipt-v1.json';

class LegacyStorageReceipt {
  const LegacyStorageReceipt({
    required this.approvedPurpose,
    required this.policyVersion,
    required this.sourceSchemaVersion,
    required this.sourceFiles,
    required this.targetRegionId,
    required this.provenanceReference,
  });

  static const format = 'university-schedule-legacy-receipt-v1';
  static const approvedPurposeValue = 'local-demo-adoption';

  final String approvedPurpose;
  final String policyVersion;
  final int sourceSchemaVersion;
  final Map<String, LegacyReceiptFile> sourceFiles;
  final String targetRegionId;
  final String provenanceReference;

  factory LegacyStorageReceipt.fromJson(Object? value) {
    if (value is! Map) {
      throw const FormatException('Legacy receipt must be a JSON object.');
    }
    final map = Map<String, Object?>.from(value);
    _requireKeys(map, {
      'format',
      'approvedPurpose',
      'policyVersion',
      'sourceSchemaVersion',
      'sourceFiles',
      'targetRegionId',
      'provenanceReference',
    });
    if (map['format'] != format ||
        map['approvedPurpose'] != approvedPurposeValue) {
      throw const FormatException(
          'Legacy receipt purpose or format is invalid.');
    }
    final sourceSchemaVersion = map['sourceSchemaVersion'];
    final sourceFiles = map['sourceFiles'];
    if (sourceSchemaVersion is! int || sourceFiles is! Map) {
      throw const FormatException('Legacy receipt source metadata is invalid.');
    }
    final files = Map<String, Object?>.from(sourceFiles);
    _requireKeys(files, {'db', 'wal', 'journal'});
    return LegacyStorageReceipt(
      approvedPurpose: map['approvedPurpose'] as String,
      policyVersion: _requiredString(map, 'policyVersion'),
      sourceSchemaVersion: sourceSchemaVersion,
      sourceFiles: {
        for (final entry in files.entries)
          entry.key: LegacyReceiptFile.fromJson(
            entry.value,
            expectedBasename: _expectedBasename(entry.key),
          ),
      },
      targetRegionId: _requiredHex64(map, 'targetRegionId'),
      provenanceReference: _requiredString(map, 'provenanceReference'),
    );
  }

  factory LegacyStorageReceipt.decode(String contents) =>
      LegacyStorageReceipt.fromJson(jsonDecode(contents));

  Map<String, Object?> toJson() => {
        'format': format,
        'approvedPurpose': approvedPurpose,
        'policyVersion': policyVersion,
        'sourceSchemaVersion': sourceSchemaVersion,
        'sourceFiles': {
          for (final entry in sourceFiles.entries)
            entry.key: entry.value.toJson(),
        },
        'targetRegionId': targetRegionId,
        'provenanceReference': provenanceReference,
      };

  Future<void> verifySourceFiles({Directory? sourceRoot}) async {
    for (final file in sourceFiles.values) {
      final source = sourceRoot == null
          ? File(file.path)
          : File('${sourceRoot.path}${Platform.pathSeparator}${file.path}');
      final exists = await source.exists();
      if (exists != file.present) {
        throw StateError('Legacy receipt source presence does not match.');
      }
      if (!exists) continue;
      final digest = await sha256.bind(source.openRead()).first;
      if (file.sha256 != digest.toString()) {
        throw StateError('Legacy receipt source digest does not match.');
      }
    }
  }

  static void _requireKeys(Map<String, Object?> map, Set<String> expected) {
    if (map.keys.toSet().length != expected.length ||
        !map.keys.toSet().containsAll(expected)) {
      throw const FormatException(
          'Legacy receipt contains unknown or missing keys.');
    }
  }

  static String _requiredString(Map<String, Object?> map, String key) {
    final value = map[key];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('Legacy receipt $key is invalid.');
    }
    return value;
  }

  static String _requiredHex64(Map<String, Object?> map, String key) {
    final value = _requiredString(map, key);
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
      throw FormatException('Legacy receipt $key is invalid.');
    }
    return value;
  }

  static String _expectedBasename(String key) => switch (key) {
        'db' => 'university_schedule.sqlite',
        'wal' => 'university_schedule.sqlite-wal',
        'journal' => 'university_schedule.sqlite-journal',
        _ =>
          throw const FormatException('Legacy receipt source key is invalid.'),
      };
}

class LegacyReceiptFile {
  const LegacyReceiptFile({
    required this.path,
    required this.present,
    required this.sha256,
  });

  final String path;
  final bool present;
  final String? sha256;

  factory LegacyReceiptFile.fromJson(
    Object? value, {
    required String expectedBasename,
  }) {
    if (value is! Map) {
      throw const FormatException('Legacy receipt file entry is invalid.');
    }
    final map = Map<String, Object?>.from(value);
    if (map.keys.toSet().length != 3 ||
        !map.keys.toSet().containsAll({'path', 'present', 'sha256'})) {
      throw const FormatException('Legacy receipt file keys are invalid.');
    }
    final path = map['path'];
    final present = map['present'];
    final digest = map['sha256'];
    if (path is! String ||
        path.trim().isEmpty ||
        present is! bool ||
        path.contains('/') ||
        path.contains('\\') ||
        path != expectedBasename) {
      throw const FormatException('Legacy receipt file metadata is invalid.');
    }
    if (present != (digest is String)) {
      throw const FormatException(
          'Legacy receipt file digest presence is invalid.');
    }
    if (digest is String && !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) {
      throw const FormatException('Legacy receipt file digest is invalid.');
    }
    return LegacyReceiptFile(
        path: path, present: present, sha256: digest as String?);
  }

  Map<String, Object?> toJson() => {
        'path': path,
        'present': present,
        'sha256': sha256,
      };
}
