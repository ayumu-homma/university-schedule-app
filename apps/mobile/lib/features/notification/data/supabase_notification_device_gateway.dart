import 'package:supabase_flutter/supabase_flutter.dart';

import '../application/notification_device_registration.dart';

class SupabaseNotificationDeviceGateway implements NotificationDeviceGateway {
  const SupabaseNotificationDeviceGateway(this._client);

  final SupabaseClient _client;

  @override
  String? get currentUserId => _client.auth.currentUser?.id;

  @override
  Stream<String?> watchUserIds() => _client.auth.onAuthStateChange.map(
        (state) => state.session?.user.id,
      );

  @override
  Future<int?> register({
    required String expectedUserId,
    required String installationId,
    required int clientGeneration,
    required String platform,
    required String token,
  }) async {
    if (currentUserId != expectedUserId) return null;
    final response = await _client.rpc(
      'register_notification_device',
      params: {
        'p_installation_id': installationId,
        'p_client_generation': clientGeneration,
        'p_platform': platform,
        'p_token': token,
        'p_app_version': null,
        'p_device_id': null,
      },
    );
    if (currentUserId != expectedUserId ||
        response is! List ||
        response.length != 1) {
      return null;
    }
    final row = Map<String, dynamic>.from(response.single as Map);
    final accepted = row['accepted'];
    final bindingGeneration = row['binding_generation'];
    if (accepted != true || bindingGeneration is! num) return null;
    final result = bindingGeneration.toInt();
    return result > 0 ? result : null;
  }

  @override
  Future<bool> revoke({
    required String expectedUserId,
    required String installationId,
    required int clientGeneration,
    required int bindingGeneration,
  }) async {
    if (currentUserId != expectedUserId) return false;
    final result = await _client.rpc(
      'revoke_notification_device',
      params: {
        'p_installation_id': installationId,
        'p_client_generation': clientGeneration,
        'p_binding_generation': bindingGeneration,
      },
    );
    if (currentUserId != expectedUserId || result is! bool) return false;
    return result;
  }
}
