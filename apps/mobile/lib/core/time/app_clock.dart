import 'package:flutter_riverpod/flutter_riverpod.dart';

abstract interface class AppClock {
  DateTime now();
}

class SystemAppClock implements AppClock {
  const SystemAppClock();

  @override
  DateTime now() => DateTime.now();
}

final appClockProvider = Provider<AppClock>((ref) => const SystemAppClock());
