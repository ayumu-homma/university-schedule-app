import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config_provider.dart';
import '../data/supabase_server_notification_repository.dart';
import '../domain/server_notification_repository.dart';

final serverNotificationRepositoryProvider =
    Provider<ServerNotificationRepository>((ref) {
  final config = ref.watch(appConfigProvider);
  if (config.demoMode) {
    return const UnavailableServerNotificationRepository();
  }
  final client = ref.watch(supabaseClientProvider);
  if (client == null) {
    return const UnavailableServerNotificationRepository();
  }
  return SupabaseServerNotificationRepository(client);
});
