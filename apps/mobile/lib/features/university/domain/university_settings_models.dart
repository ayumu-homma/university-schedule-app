enum UniversityRequestStatus {
  pending('pending', '審査中'),
  approved('approved', '承認済み'),
  rejected('rejected', '見送り'),
  merged('merged', '既存大学へ統合');

  const UniversityRequestStatus(this.wireName, this.label);

  final String wireName;
  final String label;

  static UniversityRequestStatus fromWire(String value) {
    return UniversityRequestStatus.values.firstWhere(
      (status) => status.wireName == value,
      orElse: () => throw StateError('Unknown university request status.'),
    );
  }
}

class UniversityRequestRecord {
  const UniversityRequestRecord({
    required this.id,
    required this.name,
    required this.status,
    required this.createdAt,
    this.prefecture,
    this.officialUrl,
  });

  final String id;
  final String name;
  final String? prefecture;
  final String? officialUrl;
  final UniversityRequestStatus status;
  final DateTime createdAt;
}

class UniversityRequestInput {
  const UniversityRequestInput({
    required this.name,
    this.prefecture,
    this.officialUrl,
  });

  final String name;
  final String? prefecture;
  final String? officialUrl;

  UniversityRequestInput normalized() {
    return UniversityRequestInput(
      name: name.trim(),
      prefecture: _nullIfBlank(prefecture),
      officialUrl: _nullIfBlank(officialUrl),
    );
  }

  void validate() {
    final value = normalized();
    if (value.name.length < 2 || value.name.length > 120) {
      throw ArgumentError('University name length is invalid.');
    }
    if ((value.prefecture?.length ?? 0) > 50) {
      throw ArgumentError('Prefecture length is invalid.');
    }
    final url = value.officialUrl;
    if (url != null) {
      final uri = Uri.tryParse(url);
      if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
        throw ArgumentError('Official URL must use HTTPS.');
      }
    }
  }

  String? _nullIfBlank(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}
