import 'package:shared_domain/shared_domain.dart';

class FriendUsernameProfile {
  const FriendUsernameProfile({this.username, required this.searchable});

  final String? username;
  final bool searchable;
}

class FriendUsernameMatch {
  const FriendUsernameMatch({
    required this.userId,
    required this.username,
    required this.displayName,
  });

  final String userId;
  final String username;
  final String displayName;
}

abstract final class FriendUsernamePolicy {
  static String normalize(String input) => input.trim().toLowerCase();

  static bool isValid(String username) =>
      RegExp(r'^[a-z0-9_]{3,32}$').hasMatch(username);
}

class FriendInvitation {
  const FriendInvitation({
    required this.id,
    required this.token,
    required this.expiresAt,
  });

  final String id;
  // The token is held only in the in-memory controller state and is consumed
  // by explicit link/QR actions. It is never persisted, logged, or included
  // in invitation summaries.
  final String token;
  final DateTime expiresAt;

  bool get isActive => expiresAt.isAfter(DateTime.now());
}

/// Metadata for an issuer's invite list.  The secret token is never part of
/// this DTO, so a list refresh cannot accidentally render or log it.
class FriendInvitationSummary {
  const FriendInvitationSummary({
    required this.id,
    required this.expiresAt,
    this.claimed = false,
    this.revoked = false,
  });

  final String id;
  final DateTime expiresAt;
  final bool claimed;
  final bool revoked;

  bool get isActive =>
      !claimed && !revoked && expiresAt.isAfter(DateTime.now());

  FriendInvitationSummary copyWith({bool? claimed, bool? revoked}) {
    return FriendInvitationSummary(
      id: id,
      expiresAt: expiresAt,
      claimed: claimed ?? this.claimed,
      revoked: revoked ?? this.revoked,
    );
  }
}

class FriendInvitationPreview {
  const FriendInvitationPreview({
    required this.invitationId,
    this.issuerUserId,
    this.issuerDisplayName,
    this.expiresAt,
    required this.status,
  });

  final String? invitationId;
  final String? issuerUserId;
  final String? issuerDisplayName;
  final DateTime? expiresAt;
  final String status;

  bool get isUsable =>
      status == 'active' &&
      issuerUserId != null &&
      expiresAt != null &&
      expiresAt!.isAfter(DateTime.now());
}

class FriendRelationship {
  const FriendRelationship({
    required this.id,
    required this.otherUserId,
    required this.otherDisplayName,
    required this.status,
    this.visibilityLevel = VisibilityLevel.private,
    this.isRequester = false,
    this.incarnation,
    this.revision,
  });

  final String id;
  final String otherUserId;
  final String otherDisplayName;
  final FriendshipStatus status;
  final VisibilityLevel visibilityLevel;
  final bool isRequester;
  final String? incarnation;
  final int? revision;

  bool get isAccepted => status == FriendshipStatus.accepted;
  bool get isPending => status == FriendshipStatus.pending;

  FriendRelationship copyWith({
    FriendshipStatus? status,
    VisibilityLevel? visibilityLevel,
    String? incarnation,
    int? revision,
  }) {
    return FriendRelationship(
      id: id,
      otherUserId: otherUserId,
      otherDisplayName: otherDisplayName,
      status: status ?? this.status,
      visibilityLevel: visibilityLevel ?? this.visibilityLevel,
      isRequester: isRequester,
      incarnation: incarnation ?? this.incarnation,
      revision: revision ?? this.revision,
    );
  }
}

class FriendVisibilityRule {
  const FriendVisibilityRule({
    required this.targetKind,
    this.targetId,
    this.targetValue,
    required this.level,
    this.inherited = false,
  });

  final String targetKind;
  final String? targetId;
  final String? targetValue;
  final VisibilityLevel level;
  final bool inherited;
}

class FriendSharedEvent {
  const FriendSharedEvent({
    required this.eventId,
    required this.ownerUserId,
    required this.startAt,
    required this.endAt,
    required this.visibilityLevel,
    this.title,
    this.kind,
    this.instructorName,
    this.location,
    this.description,
  });

  final String eventId;
  final String ownerUserId;
  final DateTime startAt;
  final DateTime endAt;
  final VisibilityLevel visibilityLevel;
  final String? title;
  final String? kind;
  final String? instructorName;
  final String? location;
  final String? description;

  bool get isBusyOnly => visibilityLevel == VisibilityLevel.busyOnly;
}

class FriendScheduleSnapshot {
  const FriendScheduleSnapshot({
    required this.allowed,
    required this.revision,
    required this.rows,
  });

  final bool allowed;
  final String revision;
  final List<FriendSharedEvent> rows;
}

class FriendTerm {
  const FriendTerm({
    required this.id,
    required this.name,
    required this.academicYear,
    required this.startDate,
    required this.endDate,
  });

  final String id;
  final String name;
  final int academicYear;
  final DateTime startDate;
  final DateTime endDate;
}

class FriendScheduleScope {
  const FriendScheduleScope({
    required this.viewerUserId,
    required this.sourceOwnerUserId,
    required this.contextKey,
    required this.regionId,
    required this.ownerHash,
    required this.activationToken,
    required this.generation,
    required this.accessMode,
    required this.effectiveViewerUserId,
  });

  final String viewerUserId;
  final String sourceOwnerUserId;
  final String contextKey;
  final String regionId;
  final String ownerHash;
  final String activationToken;
  final int generation;
  final String accessMode;
  final String effectiveViewerUserId;

  String get partitionKey => [
        viewerUserId,
        sourceOwnerUserId,
        contextKey,
        regionId,
        ownerHash,
        activationToken,
        generation,
        accessMode,
        effectiveViewerUserId,
      ].join('|');
}

class FriendState {
  const FriendState({
    this.relationships = const [],
    this.blockedUserIds = const {},
    this.blockedUsers = const {},
    this.blockStatusLoaded = false,
    this.blockStatusViewerUserId,
    this.visibilityRules = const {},
    this.selectedFriend,
    this.scheduleFriendId,
    this.schedulePreview = false,
    this.schedule = const [],
    this.scheduleAllowed = false,
    this.preview,
    this.pendingInvitation,
    this.issuedInvitations = const [],
    this.isLoading = false,
    this.isMutating = false,
    this.isOffline = false,
    this.errorMessage,
    this.friendUsername,
    this.usernameQuery = '',
    this.usernameMatches = const [],
    this.isSearchingUsername = false,
    this.usernameError,
  });

  final List<FriendRelationship> relationships;
  final Set<String> blockedUserIds;
  final Map<String, String> blockedUsers;
  final bool blockStatusLoaded;
  final String? blockStatusViewerUserId;
  final Map<String, List<FriendVisibilityRule>> visibilityRules;
  final FriendRelationship? selectedFriend;
  final String? scheduleFriendId;
  final bool schedulePreview;
  final List<FriendSharedEvent> schedule;
  final bool scheduleAllowed;
  final FriendInvitationPreview? preview;
  final FriendInvitation? pendingInvitation;
  final List<FriendInvitationSummary> issuedInvitations;
  final bool isLoading;
  final bool isMutating;
  final bool isOffline;
  final String? errorMessage;
  final FriendUsernameProfile? friendUsername;
  final String usernameQuery;
  final List<FriendUsernameMatch> usernameMatches;
  final bool isSearchingUsername;
  final String? usernameError;

  FriendState copyWith({
    List<FriendRelationship>? relationships,
    Set<String>? blockedUserIds,
    Map<String, String>? blockedUsers,
    bool? blockStatusLoaded,
    String? blockStatusViewerUserId,
    Map<String, List<FriendVisibilityRule>>? visibilityRules,
    FriendRelationship? selectedFriend,
    bool clearSelectedFriend = false,
    String? scheduleFriendId,
    bool clearScheduleSelection = false,
    bool? schedulePreview,
    List<FriendSharedEvent>? schedule,
    bool? scheduleAllowed,
    FriendInvitationPreview? preview,
    bool clearPreview = false,
    FriendInvitation? pendingInvitation,
    bool clearPendingInvitation = false,
    List<FriendInvitationSummary>? issuedInvitations,
    bool? isLoading,
    bool? isMutating,
    bool? isOffline,
    String? errorMessage,
    bool clearError = false,
    FriendUsernameProfile? friendUsername,
    bool clearFriendUsername = false,
    String? usernameQuery,
    List<FriendUsernameMatch>? usernameMatches,
    bool? isSearchingUsername,
    String? usernameError,
    bool clearUsernameError = false,
  }) {
    return FriendState(
      relationships: relationships ?? this.relationships,
      blockedUserIds: blockedUserIds ?? this.blockedUserIds,
      blockedUsers: blockedUsers ?? this.blockedUsers,
      blockStatusLoaded: blockStatusLoaded ?? this.blockStatusLoaded,
      blockStatusViewerUserId:
          blockStatusViewerUserId ?? this.blockStatusViewerUserId,
      visibilityRules: visibilityRules ?? this.visibilityRules,
      selectedFriend:
          clearSelectedFriend ? null : selectedFriend ?? this.selectedFriend,
      scheduleFriendId: clearScheduleSelection
          ? null
          : scheduleFriendId ?? this.scheduleFriendId,
      schedulePreview: schedulePreview ?? this.schedulePreview,
      schedule: schedule ?? this.schedule,
      scheduleAllowed: scheduleAllowed ?? this.scheduleAllowed,
      preview: clearPreview ? null : preview ?? this.preview,
      pendingInvitation: clearPendingInvitation
          ? null
          : pendingInvitation ?? this.pendingInvitation,
      issuedInvitations: issuedInvitations ?? this.issuedInvitations,
      isLoading: isLoading ?? this.isLoading,
      isMutating: isMutating ?? this.isMutating,
      isOffline: isOffline ?? this.isOffline,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
      friendUsername:
          clearFriendUsername ? null : friendUsername ?? this.friendUsername,
      usernameQuery: usernameQuery ?? this.usernameQuery,
      usernameMatches: usernameMatches ?? this.usernameMatches,
      isSearchingUsername: isSearchingUsername ?? this.isSearchingUsername,
      usernameError:
          clearUsernameError ? null : usernameError ?? this.usernameError,
    );
  }
}
