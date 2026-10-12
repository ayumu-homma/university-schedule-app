import 'package:shared_domain/shared_domain.dart';
import 'package:test/test.dart';

void main() {
  group('CourseNormalizer', () {
    final normalizer = CourseNormalizer();

    test('normalizes whitespace, punctuation, width, and roman variants', () {
      expect(
        normalizer.normalizeTitle('アルゴリズム と データ構造 Ⅰ'),
        equals('アルゴリズムとデータ構造1'),
      );
      expect(
        normalizer.normalizeTitle('アルゴリズムとデータ構造 I'),
        equals('アルゴリズムとデータ構造1'),
      );
      expect(
        normalizer.normalizeTitle('Ａｃａｄｅｍｉｃ　Ｅｎｇｌｉｓｈ'),
        equals('academicenglish'),
      );
    });

    test('removes instructor honorifics without changing core name', () {
      expect(normalizer.normalizeInstructor('山田 太郎 教授'), equals('山田太郎'));
      expect(normalizer.normalizeInstructor('Suzuki Prof.'), equals('suzuki'));
    });

    test('scores duplicate course templates inside same university', () {
      final a = CourseTemplate(
        id: 'a',
        universityId: 'u1',
        academicYear: 2026,
        title: 'アルゴリズムとデータ構造Ⅰ',
        normalizedTitle: normalizer.normalizeTitle('アルゴリズムとデータ構造Ⅰ'),
        instructorName: '山田 太郎 教授',
        normalizedInstructorName: normalizer.normalizeInstructor('山田 太郎 教授'),
        dayOfWeek: DateTime.monday,
        periodNo: 2,
        room: 'A101',
        normalizedRoom: normalizer.normalizeRoom('A101'),
        termId: 'spring',
      );
      final b = CourseTemplate(
        id: 'b',
        universityId: 'u1',
        academicYear: 2026,
        title: 'アルゴリズムとデータ構造 I',
        normalizedTitle: normalizer.normalizeTitle('アルゴリズムとデータ構造 I'),
        instructorName: '山田太郎先生',
        normalizedInstructorName: normalizer.normalizeInstructor('山田太郎先生'),
        dayOfWeek: DateTime.monday,
        periodNo: 2,
        room: 'A101教室',
        normalizedRoom: normalizer.normalizeRoom('A101教室'),
        termId: 'spring',
      );

      expect(normalizer.duplicateScore(a, b), greaterThanOrEqualTo(0.95));
      expect(normalizer.isDuplicateCandidate(a, b), isTrue);
    });

    test('does not duplicate across universities', () {
      final a = CourseTemplate(
        id: 'a',
        universityId: 'u1',
        academicYear: 2026,
        title: '線形代数',
        normalizedTitle: normalizer.normalizeTitle('線形代数'),
      );
      final b = CourseTemplate(
        id: 'b',
        universityId: 'u2',
        academicYear: 2026,
        title: '線形代数',
        normalizedTitle: normalizer.normalizeTitle('線形代数'),
      );

      expect(normalizer.duplicateScore(a, b), equals(0));
    });

    test('ranking prioritizes query match, slot match, and copy counts', () {
      final popular = CourseTemplate(
        id: 'popular',
        universityId: 'u1',
        academicYear: 2026,
        title: '心理学',
        normalizedTitle: normalizer.normalizeTitle('心理学'),
        copyCountTotal: 500,
      );
      final relevant = CourseTemplate(
        id: 'relevant',
        universityId: 'u1',
        academicYear: 2026,
        title: '情報数学',
        normalizedTitle: normalizer.normalizeTitle('情報数学'),
        dayOfWeek: DateTime.wednesday,
        periodNo: 3,
        copyCountTotal: 10,
      );

      final ranked = normalizer.rankTemplates(
        [popular, relevant],
        query: '情報',
        dayOfWeek: DateTime.wednesday,
        periodNo: 3,
      );

      expect(ranked.first.id, equals('relevant'));
    });

    test('preserves remote search metadata while normalizing a template', () {
      final normalized = normalizer.normalizeTemplate(
        const CourseTemplate(
          id: 'catalog-result',
          universityId: 'u1',
          academicYear: 2026,
          title: '分散 システム',
          normalizedTitle: 'ignored-by-normalizer',
          duplicateKey: '分散システム:山田太郎:1:2',
          rankScore: 123.45,
        ),
      );

      expect(normalized.duplicateKey, '分散システム:山田太郎:1:2');
      expect(normalized.rankScore, 123.45);
    });
  });
}
