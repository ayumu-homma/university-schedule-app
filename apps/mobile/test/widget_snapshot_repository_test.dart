import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/features/widget_bridge/application/widget_snapshot_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('widget_snapshot_repository_test');
  const repository = MethodChannelWidgetSnapshotRepository(channel: channel);

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('publishes only the strict serialized snapshot payload', () async {
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      received = call;
      return null;
    });
    final snapshot = WidgetSnapshotGenerator().generate(
      generatedAt: DateTime.utc(2026, 7, 1),
      courses: const [
        UserCourse(
          id: 'course-1',
          ownerUserId: 'owner-secret',
          termId: 'term-secret',
          title: '解析学',
          normalizedTitle: '解析学',
          dayOfWeek: DateTime.tuesday,
          periodNo: 3,
        ),
      ],
    );

    await repository.saveSnapshot(snapshot);

    expect(received?.method, 'saveSnapshot');
    final arguments = received?.arguments! as Map<Object?, Object?>;
    final payload = arguments['payload']! as String;
    expect(payload, contains('"schemaVersion":1'));
    expect(payload, contains('"courseId":"course-1"'));
    expect(payload, isNot(contains('owner-secret')));
    expect(payload, isNot(contains('term-secret')));
  });

  test('read fails closed for malformed native payload', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => '{"schemaVersion":2}');

    expect(repository.readLatestSnapshot(), throwsA(isA<FormatException>()));
  });
}
