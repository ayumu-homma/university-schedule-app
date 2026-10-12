import 'package:shared_domain/shared_domain.dart';
import 'package:test/test.dart';

void main() {
  test('converts Japan civil time to a UTC instant without device timezone',
      () {
    final instant = JapanTime.at(
      year: 2026,
      month: 7,
      day: 6,
      hour: 9,
      minute: 15,
    );

    expect(instant, DateTime.utc(2026, 7, 6, 0, 15));
    expect(instant.isUtc, isTrue);
  });

  test('reads UTC instants as Asia/Tokyo civil time', () {
    final civil = JapanTime.civil(DateTime.utc(2026, 7, 5, 15, 30));

    expect((civil.year, civil.month, civil.day, civil.hour, civil.minute),
        (2026, 7, 6, 0, 30));
    expect(civil.weekday, DateTime.monday);
  });
}
