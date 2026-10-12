import 'package:shared_domain/shared_domain.dart';

class GroupSummary {
  const GroupSummary({
    required this.id,
    required this.name,
    required this.ownerUserId,
    required this.type,
    this.description,
    this.eventCreatePolicy = 'member',
    this.defaultVisibility = 'TITLE_ONLY',
    this.role = GroupRole.member,
  });

  final String id;
  final String name;
  final String ownerUserId;
  final GroupType type;
  final String? description;
  final String eventCreatePolicy;
  final String defaultVisibility;
  final GroupRole role;

  GroupSummary copyWith({String? defaultVisibility}) => GroupSummary(
        id: id,
        name: name,
        ownerUserId: ownerUserId,
        type: type,
        description: description,
        eventCreatePolicy: eventCreatePolicy,
        defaultVisibility: defaultVisibility ?? this.defaultVisibility,
        role: role,
      );
}

class GroupMemberSummary {
  const GroupMemberSummary({
    required this.groupId,
    required this.userId,
    required this.displayName,
    required this.role,
  });

  final String groupId;
  final String userId;
  final String displayName;
  final GroupRole role;
}

class GroupInviteSummary {
  const GroupInviteSummary({
    required this.id,
    required this.expiresAt,
    required this.maxUses,
    required this.usedCount,
    required this.revoked,
  });

  final String id;
  final DateTime expiresAt;
  final int? maxUses;
  final int usedCount;
  final bool revoked;

  bool get active =>
      !revoked &&
      expiresAt.isAfter(DateTime.now().toUtc()) &&
      (maxUses == null || usedCount < maxUses!);
}

class GroupInviteCreated {
  const GroupInviteCreated({
    required this.id,
    required this.token,
    required this.expiresAt,
  });

  final String id;
  final String token;
  final DateTime expiresAt;
}

class GroupInvitePreview {
  const GroupInvitePreview({
    required this.invitationId,
    required this.groupId,
    required this.groupName,
    required this.expiresAt,
    required this.status,
  });

  final String invitationId;
  final String groupId;
  final String groupName;
  final DateTime expiresAt;
  final String status;

  bool get usable =>
      status == 'active' && expiresAt.isAfter(DateTime.now().toUtc());
}

class GroupEventSummary {
  const GroupEventSummary(
      {required this.eventId,
      required this.groupId,
      required this.title,
      required this.startAt,
      required this.endAt,
      this.location,
      this.description,
      required this.createdBy,
      required this.version,
      this.cancelled = false});
  final String eventId;
  final String groupId;
  final String title;
  final DateTime startAt;
  final DateTime endAt;
  final String? location;
  final String? description;
  final String createdBy;
  final int version;
  final bool cancelled;
}

class GroupEventRsvp {
  const GroupEventRsvp(
      {required this.userId, required this.status, required this.updatedAt});
  final String userId;
  final String status;
  final DateTime? updatedAt;
}

class GroupEventDraft {
  const GroupEventDraft(
      {required this.eventId,
      required this.title,
      required this.startAt,
      required this.endAt,
      this.location,
      this.description});
  final String? eventId;
  final String title;
  final DateTime startAt;
  final DateTime endAt;
  final String? location;
  final String? description;
}

class GroupEventComment {
  const GroupEventComment({
    required this.commentId,
    required this.eventId,
    required this.authorUserId,
    required this.body,
    required this.createdAt,
    required this.updatedAt,
    required this.version,
  });

  final String commentId;
  final String eventId;
  final String authorUserId;
  final String body;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int version;
}

class GroupEventReaction {
  const GroupEventReaction({
    required this.reaction,
    required this.reactionCount,
    required this.reactedByMe,
  });

  final String reaction;
  final int reactionCount;
  final bool reactedByMe;
}

class GroupEventContent {
  const GroupEventContent({
    required this.eventId,
    required this.groupId,
    required this.generation,
    required this.rsvps,
    required this.comments,
    required this.reactions,
  });

  final String eventId;
  final String groupId;
  final String generation;
  final List<GroupEventRsvp> rsvps;
  final List<GroupEventComment> comments;
  final List<GroupEventReaction> reactions;
}

class GroupEventCommentDraft {
  const GroupEventCommentDraft({
    required this.commentId,
    required this.body,
    required this.expectedVersion,
  });

  final String commentId;
  final String body;
  final int expectedVersion;
}

class GroupAvailabilityRow {
  const GroupAvailabilityRow(
      {required this.memberId,
      required this.startAt,
      required this.endAt,
      required this.visibility});
  final String memberId;
  final DateTime startAt;
  final DateTime endAt;
  final String visibility;
}

class GroupAvailabilityResult {
  const GroupAvailabilityResult(
      {required this.rows,
      required this.memberIds,
      required this.queryId,
      required this.generation});
  final List<GroupAvailabilityRow> rows;
  final List<String> memberIds;
  final String queryId;
  final String generation;
}
