import 'group_models.dart';
import 'package:shared_domain/shared_domain.dart';

abstract interface class GroupRepository {
  Future<List<GroupSummary>> listGroups();
  Future<GroupSummary> createGroup({
    required String name,
    required String type,
    String? description,
    required String eventCreatePolicy,
  });
  Future<GroupSummary> getGroup(String groupId);
  Future<String> setGroupDefaultVisibility({
    required String groupId,
    required String visibility,
  });
  Future<GroupSummary> updateGroup({
    required String groupId,
    required String name,
    required String type,
    String? description,
    required String eventCreatePolicy,
  });
  Future<List<GroupMemberSummary>> listMembers(String groupId);

  /// Returns only in-group peers blocked by the authenticated viewer in either
  /// direction. An empty set is a known no-block result; errors stay unknown.
  Future<Set<String>> listBlockedGroupMembers(String groupId);
  Future<List<GroupInviteSummary>> listInvites(String groupId);
  Future<GroupInviteCreated> createInvite({
    required String groupId,
    required DateTime expiresAt,
    int? maxUses,
  });
  Future<void> revokeInvite(String groupId, String invitationId);
  Future<GroupInvitePreview> previewInvite(String token);
  Future<GroupSummary> joinInvite(String token);
  Future<void> leaveGroup(String groupId);
  Future<void> removeMember(String groupId, String userId);
  Future<void> changeMemberRole(String groupId, String userId, GroupRole role);
  Future<void> transferOwnership(String groupId, String userId);
  Future<void> deleteGroup(String groupId);
  Future<List<GroupEventSummary>> listGroupEvents(String groupId);
  Future<GroupEventSummary> getGroupEvent(String eventId);
  Future<List<GroupEventRsvp>> listGroupEventRsvps(String eventId);
  Future<GroupEventSummary> createGroupEvent(
      {required String groupId,
      required String title,
      required DateTime startAt,
      required DateTime endAt,
      String? location,
      String? description});
  Future<GroupEventSummary> updateGroupEvent(
      {required String eventId,
      required String title,
      required DateTime startAt,
      required DateTime endAt,
      String? location,
      String? description,
      required int expectedVersion});
  Future<void> cancelGroupEvent(String eventId, int expectedVersion);
  Future<GroupEventRsvp> setGroupEventRsvp(String eventId, String status);
  Future<GroupEventContent> getGroupEventContent(String eventId);
  Future<bool> validateGroupEventContent({
    required String eventId,
    required String generation,
  });
  Future<List<GroupEventComment>> listGroupEventComments(String eventId);
  Future<GroupEventComment> createGroupEventComment(
      {required String eventId, required String body});
  Future<GroupEventComment> updateGroupEventComment({
    required String commentId,
    required String body,
    required int expectedVersion,
  });
  Future<void> deleteGroupEventComment(
      {required String commentId, required int expectedVersion});
  Future<void> moderateDeleteGroupEventComment(String commentId);
  Future<List<GroupEventReaction>> listGroupEventReactions(String eventId);
  Future<void> setGroupEventReaction(
      {required String eventId, required String reaction});
  Future<void> removeGroupEventReaction(
      {required String eventId, required String reaction});
  Future<void> reportGroupContent({
    required String targetType,
    required String targetId,
    required String reason,
  });
  Future<GroupAvailabilityResult> findGroupAvailability(
      {required String groupId,
      required List<String> memberIds,
      required DateTime rangeStart,
      required DateTime rangeEnd,
      required int minimumDurationMinutes});
  Future<bool> validateGroupAvailability(
      {required String groupId,
      required List<String> memberIds,
      required String generation});
}
