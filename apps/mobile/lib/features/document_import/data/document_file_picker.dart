import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:shared_domain/shared_domain.dart';

import '../domain/document_import_models.dart';

abstract interface class DocumentFilePicker {
  Future<DocumentSelectedFile?> pick();
}

class PlatformDocumentFilePicker implements DocumentFilePicker {
  const PlatformDocumentFilePicker();

  @override
  Future<DocumentSelectedFile?> pick() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf', 'png', 'jpg', 'jpeg', 'txt'],
      allowMultiple: false,
      withData: true,
      lockParentWindow: true,
    );
    if (result == null || result.files.isEmpty) return null;
    final platformFile = result.files.single;
    if (platformFile.size < 1 ||
        platformFile.size > documentImportMaximumBytes) {
      throw const DocumentImportFailure(
        DocumentImportErrorCategory.oversizedFile,
      );
    }
    Uint8List? bytes = platformFile.bytes;
    final path = platformFile.path;
    if (bytes == null && path != null) {
      bytes = await File(path).readAsBytes();
    }
    if (bytes == null) {
      throw const DocumentImportFailure(
        DocumentImportErrorCategory.corruptDocument,
      );
    }
    return DocumentSelectedFile.validate(
      extension: platformFile.extension ?? '',
      declaredSize: platformFile.size,
      bytes: bytes,
    );
  }
}
