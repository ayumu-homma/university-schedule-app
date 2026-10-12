import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_schedule_mobile/features/notification/application/local_notification_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('phase8-notification-inbox-test');
  const platform = MethodChannelLocalNotificationPlatform(channel: channel);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('inbox returns the fresh list after a transient native busy error',
      () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'readInbox');
      expect(call.arguments, {'identity': 'synthetic-notification'});
      if (++calls == 1) throw PlatformException(code: 'storage_busy');
      return [
        {'identity': 'synthetic-notification', 'title': 'Current item'},
      ];
    });
    expect(await platform.readInbox(identity: 'synthetic-notification'), [
      {'identity': 'synthetic-notification', 'title': 'Current item'},
    ]);
    expect(calls, 2);
  });

  test('persistent inbox contention fails explicitly without unbounded retries',
      () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (_) async {
      calls++;
      throw PlatformException(code: 'storage_busy');
    });
    await expectLater(platform.readInbox(),
        throwsA(isA<LocalNotificationStorageBusyException>()));
    expect(calls, 2);
  });

  test('inbox preserves non-busy failures and does not retry them', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (_) async {
      calls++;
      throw PlatformException(code: 'notification_rejected');
    });
    await expectLater(
      platform.readInbox(),
      throwsA(isA<PlatformException>()
          .having((error) => error.code, 'code', 'notification_rejected')),
    );
    expect(calls, 1);
  });
}
