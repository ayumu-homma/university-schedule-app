import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:shared_domain/shared_domain.dart';

const documentImportMaximumBytes = 10 * 1024 * 1024;

class DocumentImportFailure implements Exception {
  const DocumentImportFailure(this.category);

  final DocumentImportErrorCategory category;

  @override
  String toString() => 'DocumentImportFailure(${category.wireName})';
}

/// Cooperative cancellation for upload/analysis work whose underlying SDK
/// request cannot always be aborted. Callers must still discard late results.
class DocumentImportCancellation {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;

  void throwIfCancelled() {
    if (_cancelled) {
      throw const DocumentImportFailure(DocumentImportErrorCategory.cancelled);
    }
  }
}

/// An in-memory selection passed directly to the authenticated upload
/// boundary. The original filename is discarded after extension validation.
class DocumentSelectedFile {
  const DocumentSelectedFile({
    required this.extension,
    required this.mediaType,
    required this.bytes,
  });

  final String extension;
  final DocumentMediaType mediaType;
  final Uint8List bytes;

  int get byteLength => bytes.lengthInBytes;
  String get contentHash => sha256.convert(bytes).toString();

  static DocumentSelectedFile validate({
    required String extension,
    required int declaredSize,
    required Uint8List bytes,
  }) {
    final normalizedExtension = extension.trim().toLowerCase();
    final mediaType = switch (normalizedExtension) {
      'pdf' => DocumentMediaType.pdf,
      'png' => DocumentMediaType.png,
      'jpg' || 'jpeg' => DocumentMediaType.jpeg,
      'txt' => DocumentMediaType.plainText,
      _ => throw const DocumentImportFailure(
          DocumentImportErrorCategory.unsupportedType,
        ),
    };
    if (declaredSize < 1 ||
        declaredSize > documentImportMaximumBytes ||
        bytes.isEmpty ||
        bytes.lengthInBytes > documentImportMaximumBytes ||
        declaredSize != bytes.lengthInBytes) {
      throw const DocumentImportFailure(
        DocumentImportErrorCategory.oversizedFile,
      );
    }
    if (!_matchesContent(mediaType, bytes)) {
      throw const DocumentImportFailure(
        DocumentImportErrorCategory.spoofedMediaType,
      );
    }
    return DocumentSelectedFile(
      extension: switch (mediaType) {
        DocumentMediaType.jpeg => 'jpg',
        _ => normalizedExtension,
      },
      mediaType: mediaType,
      bytes: bytes,
    );
  }

  static bool _matchesContent(
    DocumentMediaType mediaType,
    Uint8List bytes,
  ) {
    switch (mediaType) {
      case DocumentMediaType.pdf:
        return _startsWith(bytes, const [0x25, 0x50, 0x44, 0x46, 0x2d]);
      case DocumentMediaType.png:
        return _startsWith(
          bytes,
          const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
        );
      case DocumentMediaType.jpeg:
        return _startsWith(bytes, const [0xff, 0xd8, 0xff]);
      case DocumentMediaType.plainText:
        try {
          final text = utf8.decode(bytes, allowMalformed: false);
          return text.trim().isNotEmpty &&
              !text.contains('\u0000') &&
              !_activeMarkup.hasMatch(text);
        } on FormatException {
          return false;
        }
    }
  }

  static bool _startsWith(Uint8List bytes, List<int> signature) {
    if (bytes.length < signature.length) return false;
    for (var index = 0; index < signature.length; index++) {
      if (bytes[index] != signature[index]) return false;
    }
    return true;
  }

  static final _activeMarkup = RegExp(
    r'<\s*/?\s*(?:script|iframe|object|embed)[^>]*>|'
    r'\bon(?:load|error|click)\s*=|javascript\s*:',
    caseSensitive: false,
  );
}

class RemoteDocumentCandidateIdentity {
  const RemoteDocumentCandidateIdentity({
    required this.id,
    required this.version,
  });

  final String id;
  final int version;
}

class DocumentAnalysisResult {
  const DocumentAnalysisResult({
    required this.batch,
    required this.storagePath,
    required this.remoteCandidates,
    required this.remoteSourceVersion,
  });

  final ScheduleCandidateBatch batch;
  final String? storagePath;
  final Map<String, RemoteDocumentCandidateIdentity> remoteCandidates;
  final int? remoteSourceVersion;
}

class DocumentCandidateReview {
  const DocumentCandidateReview({
    required this.localId,
    required this.sourceId,
    required this.candidate,
    required this.reviewState,
    required this.isSelected,
    required this.remoteSyncPending,
    this.courseId,
    this.remoteCandidateId,
    this.remoteVersion,
    this.linkedEntityType,
    this.linkedEntityId,
  });

  final String localId;
  final String sourceId;
  final DocumentScheduleCandidate candidate;
  final DocumentCandidateReviewState reviewState;
  final bool isSelected;
  final bool remoteSyncPending;
  final String? courseId;
  final String? remoteCandidateId;
  final int? remoteVersion;
  final String? linkedEntityType;
  final String? linkedEntityId;

  bool get canConfirm =>
      reviewState == DocumentCandidateReviewState.needsReview && isSelected;
}

class DocumentReviewBatch {
  const DocumentReviewBatch({
    required this.sourceId,
    required this.contentHash,
    required this.mediaType,
    required this.processingState,
    required this.candidates,
  });

  final String sourceId;
  final String contentHash;
  final DocumentMediaType mediaType;
  final DocumentImportState processingState;
  final List<DocumentCandidateReview> candidates;
}

class DocumentCandidateEdit {
  const DocumentCandidateEdit({
    required this.candidate,
    this.courseId,
  });

  final DocumentScheduleCandidate candidate;
  final String? courseId;
}

class DocumentCourseOption {
  const DocumentCourseOption({required this.id, required this.title});

  final String id;
  final String title;
}

class DocumentRemoteConfirmation {
  const DocumentRemoteConfirmation({
    required this.entityType,
    required this.entityId,
    required this.replayed,
  });

  final DocumentCandidateType entityType;
  final String entityId;
  final bool replayed;
}

abstract interface class DocumentImportGateway {
  bool get confirmsOnServer;

  Future<DocumentAnalysisResult> analyze(
    DocumentSelectedFile file, {
    void Function(DocumentImportState state)? onState,
    DocumentImportCancellation? cancellation,
  });

  Future<int?> updateCandidate({
    required RemoteDocumentCandidateIdentity identity,
    required DocumentScheduleCandidate candidate,
    required String action,
  });

  Future<DocumentRemoteConfirmation> confirmCandidate({
    required RemoteDocumentCandidateIdentity identity,
    required DocumentScheduleCandidate candidate,
    required String entityId,
    required String idempotencyKey,
    required String? courseId,
  });

  Future<void> deleteSource({
    required String sourceId,
    required String? storagePath,
  });
}
