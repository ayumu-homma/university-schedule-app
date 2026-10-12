import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Compile-time opt-in. Normal builds start no experimental subscriptions,
/// ticker or measurement callback. Provider overrides are for local tests.
final spatialWeekEnabledProvider = Provider<bool>(
  (ref) => const bool.fromEnvironment('APP_ENABLE_SPATIAL_WEEK'),
);
