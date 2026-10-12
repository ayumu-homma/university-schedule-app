import 'package:shared_domain/shared_domain.dart';

import '../../friends/domain/friend_models.dart';

enum AvailabilityStatus {
  loadingFriends,
  ready,
  searching,
  success,
  noCandidates,
  error
}

enum AvailabilityErrorKind {
  none,
  unauthenticated,
  validation,
  network,
  authorization
}

class AvailabilityState {
  const AvailabilityState({
    required this.selectedDate,
    this.startMinutes = 9 * 60,
    this.endMinutes = 18 * 60,
    this.minimumDurationMinutes = 60,
    this.viewerUserId,
    this.friends = const [],
    this.selectedFriendIds = const {},
    this.windows = const [],
    this.status = AvailabilityStatus.ready,
    this.errorKind = AvailabilityErrorKind.none,
    this.errorMessage,
    this.hasSearched = false,
  });

  final DateTime selectedDate;
  final int startMinutes;
  final int endMinutes;
  final int minimumDurationMinutes;
  final String? viewerUserId;
  final List<FriendRelationship> friends;
  final Set<String> selectedFriendIds;
  final List<TimeWindow> windows;
  final AvailabilityStatus status;
  final AvailabilityErrorKind errorKind;
  final String? errorMessage;
  final bool hasSearched;

  List<FriendRelationship> get acceptedFriends =>
      friends.where((friend) => friend.isAccepted).toList(growable: false);

  bool get isLoading =>
      status == AvailabilityStatus.loadingFriends ||
      status == AvailabilityStatus.searching;

  bool get hasValidRange =>
      startMinutes >= 0 && endMinutes <= 24 * 60 && startMinutes < endMinutes;

  AvailabilityState copyWith({
    DateTime? selectedDate,
    int? startMinutes,
    int? endMinutes,
    int? minimumDurationMinutes,
    String? viewerUserId,
    bool clearViewerUserId = false,
    List<FriendRelationship>? friends,
    Set<String>? selectedFriendIds,
    List<TimeWindow>? windows,
    AvailabilityStatus? status,
    AvailabilityErrorKind? errorKind,
    String? errorMessage,
    bool clearError = false,
    bool? hasSearched,
  }) {
    return AvailabilityState(
      selectedDate: selectedDate ?? this.selectedDate,
      startMinutes: startMinutes ?? this.startMinutes,
      endMinutes: endMinutes ?? this.endMinutes,
      minimumDurationMinutes:
          minimumDurationMinutes ?? this.minimumDurationMinutes,
      viewerUserId:
          clearViewerUserId ? null : viewerUserId ?? this.viewerUserId,
      friends: friends ?? this.friends,
      selectedFriendIds: selectedFriendIds ?? this.selectedFriendIds,
      windows: windows ?? this.windows,
      status: status ?? this.status,
      errorKind: errorKind ?? this.errorKind,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
      hasSearched: hasSearched ?? this.hasSearched,
    );
  }
}
