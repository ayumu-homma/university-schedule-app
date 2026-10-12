import 'package:flutter_test/flutter_test.dart';

import 'package:university_schedule_mobile/core/config/app_config.dart';
import 'package:university_schedule_mobile/core/config/storage_region.dart';

AppConfig _live(String url) {
  return AppConfig.validated(
    environment: 'local',
    demoMode: false,
    supabaseUrl: url,
    supabasePublishableKey: 'local-publishable-key',
  );
}

void main() {
  test('demo has a fixed origin and is isolated from live config', () {
    final first = StorageRegion.fromConfig(AppConfig.demoForTesting());
    final second = StorageRegion.fromConfig(AppConfig.demoForTesting());
    final live = StorageRegion.fromConfig(_live('http://127.0.0.1:54321'));

    expect(first.id, second.id);
    expect(first.mode, 'demo');
    expect(first.canonicalOrigin, startsWith('demo://'));
    expect(first.id, isNot(live.id));
  });

  test('canonical origin preserves effective ports and ignores root slash', () {
    final implicit = StorageRegion.fromConfig(_live('http://127.0.0.1'));
    final explicitDefault =
        StorageRegion.fromConfig(_live('http://127.0.0.1:80/'));
    final alternatePort =
        StorageRegion.fromConfig(_live('http://127.0.0.1:54321'));

    expect(implicit.canonicalOrigin, 'http://127.0.0.1:80');
    expect(implicit.id, explicitDefault.id);
    expect(implicit.id, isNot(alternatePort.id));
  });

  test('environment, mode, origin and IPv6 spelling affect the identity safely',
      () {
    final loopback = StorageRegion.fromConfig(_live('http://[::1]:54321'));
    final otherLoopback =
        StorageRegion.fromConfig(_live('http://127.0.0.1:54321'));
    final upper = StorageRegion.fromConfig(_live('HTTP://LOCALHOST:54321'));

    expect(loopback.canonicalOrigin, 'http://[::1]:54321');
    expect(loopback.id, isNot(otherLoopback.id));
    expect(upper.canonicalOrigin, 'http://localhost:54321');
  });
}
