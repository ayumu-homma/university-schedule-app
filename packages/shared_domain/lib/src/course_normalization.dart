import 'models.dart';

class CourseNormalizer {
  static const _romanVariants = <String, String>{
    'Ⅰ': '1',
    'Ⅱ': '2',
    'Ⅲ': '3',
    'Ⅳ': '4',
    'Ⅴ': '5',
    'Ⅵ': '6',
    'Ⅶ': '7',
    'Ⅷ': '8',
    'Ⅸ': '9',
    'Ⅹ': '10',
    'ⅰ': '1',
    'ⅱ': '2',
    'ⅲ': '3',
    'ⅳ': '4',
    'ⅴ': '5',
    'I': '1',
    'II': '2',
    'III': '3',
    'IV': '4',
    'V': '5',
  };

  static const _honorifics = [
    '先生',
    '教授',
    '准教授',
    '講師',
    '助教',
    '氏',
    'さん',
    '様',
    'dr.',
    'dr',
    'prof.',
    'prof',
    'professor',
  ];

  String normalizeTitle(String input) {
    return _normalizeCommon(input, removeSpaces: true);
  }

  String normalizeInstructor(String? input) {
    if (input == null) return '';
    var normalized = _normalizeCommon(input, removeSpaces: true);
    for (final honorific in _honorifics) {
      normalized = normalized.replaceAll(honorific, '');
    }
    return normalized;
  }

  String normalizeRoom(String? input) {
    if (input == null) return '';
    return _normalizeCommon(input, removeSpaces: true)
        .replaceAll('教室', '')
        .replaceAll('号館', '館');
  }

  CourseTemplate normalizeTemplate(CourseTemplate template) {
    return CourseTemplate(
      id: template.id,
      universityId: template.universityId,
      academicYear: template.academicYear,
      termId: template.termId,
      title: template.title,
      normalizedTitle: normalizeTitle(template.title),
      instructorName: template.instructorName,
      normalizedInstructorName: normalizeInstructor(template.instructorName),
      dayOfWeek: template.dayOfWeek,
      periodNo: template.periodNo,
      room: template.room,
      normalizedRoom: normalizeRoom(template.room),
      creditCount: template.creditCount,
      syllabusUrl: template.syllabusUrl,
      externalCourseCode: template.externalCourseCode,
      copyCountTotal: template.copyCountTotal,
      copyCountTerm: template.copyCountTerm,
      trustScore: template.trustScore,
      duplicateKey: template.duplicateKey,
      rankScore: template.rankScore,
    );
  }

  double duplicateScore(CourseTemplate a, CourseTemplate b) {
    if (a.universityId != b.universityId) return 0;

    final titleA = a.normalizedTitle.isNotEmpty
        ? a.normalizedTitle
        : normalizeTitle(a.title);
    final titleB = b.normalizedTitle.isNotEmpty
        ? b.normalizedTitle
        : normalizeTitle(b.title);
    final instructorA =
        a.normalizedInstructorName ?? normalizeInstructor(a.instructorName);
    final instructorB =
        b.normalizedInstructorName ?? normalizeInstructor(b.instructorName);
    final roomA = a.normalizedRoom ?? normalizeRoom(a.room);
    final roomB = b.normalizedRoom ?? normalizeRoom(b.room);

    var score = 0.0;
    if (titleA == titleB) {
      score += 0.55;
    } else {
      score += 0.55 * _similarity(titleA, titleB);
    }

    if (instructorA.isNotEmpty && instructorA == instructorB) {
      score += 0.2;
    } else if (instructorA.isNotEmpty && instructorB.isNotEmpty) {
      score += 0.2 * _similarity(instructorA, instructorB);
    }

    if (a.dayOfWeek != null && a.dayOfWeek == b.dayOfWeek) score += 0.075;
    if (a.periodNo != null && a.periodNo == b.periodNo) score += 0.075;
    if (roomA.isNotEmpty && roomA == roomB) score += 0.05;
    if (a.termId != null && a.termId == b.termId) score += 0.05;

    return score.clamp(0, 1);
  }

  bool isDuplicateCandidate(CourseTemplate a, CourseTemplate b,
      {double threshold = 0.78}) {
    return duplicateScore(a, b) >= threshold;
  }

  List<CourseTemplate> rankTemplates(
    Iterable<CourseTemplate> templates, {
    String query = '',
    int? dayOfWeek,
    int? periodNo,
  }) {
    final normalizedQuery = normalizeTitle(query);
    final ranked = templates.toList()
      ..sort((a, b) {
        final scoreA = _rankingScore(a, normalizedQuery, dayOfWeek, periodNo);
        final scoreB = _rankingScore(b, normalizedQuery, dayOfWeek, periodNo);
        return scoreB.compareTo(scoreA);
      });
    return ranked;
  }

  double _rankingScore(
    CourseTemplate template,
    String normalizedQuery,
    int? dayOfWeek,
    int? periodNo,
  ) {
    final title = template.normalizedTitle.isNotEmpty
        ? template.normalizedTitle
        : normalizeTitle(template.title);
    var score = template.copyCountTerm * 2 +
        template.copyCountTotal +
        template.trustScore.toDouble();
    if (normalizedQuery.isNotEmpty) {
      if (title.contains(normalizedQuery)) score += 500;
      score += 100 * _similarity(title, normalizedQuery);
    }
    if (dayOfWeek != null && template.dayOfWeek == dayOfWeek) score += 20;
    if (periodNo != null && template.periodNo == periodNo) score += 20;
    return score;
  }

  String _normalizeCommon(String input, {required bool removeSpaces}) {
    var output = _foldAscii(input).trim();
    output = output.replaceAllMapped(
      RegExp(r'[ⅠⅡⅢⅣⅤⅥⅦⅧⅨⅩⅰⅱⅲⅳⅴ]'),
      (match) => _romanVariants[match.group(0)]!,
    );
    output = output.replaceAllMapped(
      RegExp(r'(^|[^A-Za-z])(I|II|III|IV|V)(?=$|[^A-Za-z])',
          caseSensitive: false),
      (match) =>
          '${match.group(1)}${_romanVariants[match.group(2)!.toUpperCase()]}',
    );
    output = output.toLowerCase();
    output = output
        .replaceAll(RegExp(r'[（）\(\)\[\]【】「」『』:：,，.．・_/\\-]'), '')
        .replaceAll(RegExp(r'\s+'), removeSpaces ? '' : ' ');
    return output;
  }

  String _foldAscii(String input) {
    final buffer = StringBuffer();
    for (final codePoint in input.runes) {
      if (codePoint == 0x3000) {
        buffer.write(' ');
      } else if (codePoint >= 0xFF01 && codePoint <= 0xFF5E) {
        buffer.writeCharCode(codePoint - 0xFEE0);
      } else {
        buffer.writeCharCode(codePoint);
      }
    }
    return buffer.toString();
  }

  double _similarity(String a, String b) {
    if (a == b) return 1;
    if (a.isEmpty || b.isEmpty) return 0;
    final distance = _levenshtein(a, b);
    final maxLength = a.length > b.length ? a.length : b.length;
    return 1 - (distance / maxLength);
  }

  int _levenshtein(String a, String b) {
    final rows = a.length + 1;
    final cols = b.length + 1;
    final matrix = List.generate(rows, (i) => List<int>.filled(cols, 0));
    for (var i = 0; i < rows; i++) {
      matrix[i][0] = i;
    }
    for (var j = 0; j < cols; j++) {
      matrix[0][j] = j;
    }
    for (var i = 1; i < rows; i++) {
      for (var j = 1; j < cols; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        matrix[i][j] = [
          matrix[i - 1][j] + 1,
          matrix[i][j - 1] + 1,
          matrix[i - 1][j - 1] + cost,
        ].reduce((value, element) => value < element ? value : element);
      }
    }
    return matrix[a.length][b.length];
  }
}
