import 'package:flutter_test/flutter_test.dart';
import 'package:shared_domain/shared_domain.dart';

void main() {
  test('demo timetable snapshot contains copied course links', () {
    final snapshot = WidgetSnapshotGenerator().generate(
      courses: DemoData.userCourses,
      generatedAt: DateTime(2026, 6, 29),
    );

    expect(snapshot.cells, hasLength(25));
    expect(snapshot.cells.where((cell) => cell.deepLink != null), isNotEmpty);
  });
}
