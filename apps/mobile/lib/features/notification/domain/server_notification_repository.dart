import 'server_notification.dart';

abstract interface class ServerNotificationRepository {
  Future<List<ServerNotification>> list({
    DateTime? before,
    String? beforeId,
    int limit = 30,
  });
  Future<bool> markRead(String inboxId);
  Future<List<TargetedGroupInvitation>> listInvitations();
  Future<void> inviteFriendToGroup({
    required String groupId,
    required String inviteeUserId,
    required DateTime expiresAt,
  });
  Future<void> respondToInvitation(String invitationId, {required bool accept});
}

class UnavailableServerNotificationRepository
    implements ServerNotificationRepository {
  const UnavailableServerNotificationRepository();

  @override
  Future<List<ServerNotification>> list({
    DateTime? before,
    String? beforeId,
    int limit = 30,
  }) =>
      Future.value(const []);

  @override
  Future<bool> markRead(String inboxId) => Future.value(false);

  @override
  Future<List<TargetedGroupInvitation>> listInvitations() =>
      Future.value(const []);

  @override
  Future<void> inviteFriendToGroup({
    required String groupId,
    required String inviteeUserId,
    required DateTime expiresAt,
  }) =>
      Future.error(StateError('Server notifications are unavailable.'));

  @override
  Future<void> respondToInvitation(String invitationId,
          {required bool accept}) =>
      Future.error(StateError('Server notifications are unavailable.'));
}
