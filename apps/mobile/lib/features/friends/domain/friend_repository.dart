import 'friend_models.dart';

abstract interface class FriendRepository {
  Future<FriendUsernameProfile?> getMyFriendUsername();

  Future<FriendUsernameProfile> setMyFriendUsername({
    required String? username,
    required bool searchable,
  });

  Future<List<FriendUsernameMatch>> findFriendByUsername(String username);

  Future<FriendRelationship> requestFriendByUsername({
    required FriendUsernameMatch target,
    required String shownUsername,
    required String operationId,
  });

  Future<FriendInvitation> createInvitation({required DateTime expiresAt});

  Future<void> revokeInvitation(String invitationId);

  Future<List<FriendInvitationSummary>> listInvitations();

  Future<FriendInvitationPreview> previewInvitation(String token);

  Future<FriendRelationship> requestInvitation(String token);

  Future<FriendRelationship> respondToRequest({
    required FriendRelationship relationship,
    required bool accept,
  });

  Future<void> cancelRequest(FriendRelationship relationship);

  Future<List<FriendRelationship>> listRelationships();

  Future<void> setVisibility({
    required FriendRelationship relationship,
    required String friendUserId,
    required String level,
    required String targetKind,
    String? targetId,
    String? targetValue,
    bool inherit = false,
  });

  Future<List<FriendVisibilityRule>> listVisibilityRules(
    FriendRelationship relationship,
  );

  Future<FriendScheduleSnapshot> fetchSchedule({
    required String friendUserId,
    required String termId,
    required DateTime rangeStart,
    required DateTime rangeEnd,
  });

  Future<FriendScheduleSnapshot> previewSchedule({
    required String friendUserId,
    required String termId,
    required DateTime rangeStart,
    required DateTime rangeEnd,
  });

  Future<List<FriendTerm>> listFriendTerms(String friendUserId);

  Future<void> removeFriend(FriendRelationship relationship);

  Future<void> blockUser(String userId);

  Future<void> unblockUser(String userId);

  Future<Map<String, String>> listBlockedUsers();
}
