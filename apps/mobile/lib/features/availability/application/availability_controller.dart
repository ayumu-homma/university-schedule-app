import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_domain/shared_domain.dart';

import '../../../core/error/app_error.dart';
import '../../../core/time/app_clock.dart';
import '../../auth/application/auth_providers.dart';
import '../../friends/application/friend_providers.dart';
import '../../friends/domain/friend_models.dart';
import '../../friends/domain/friend_repository.dart';
import '../domain/availability_models.dart';

final availabilityControllerProvider = AsyncNotifierProvider.autoDispose<
    AvailabilityController, AvailabilityState>(
  AvailabilityController.new,
);

class AvailabilityController
    extends AutoDisposeAsyncNotifier<AvailabilityState> {
  FriendRepository get _repository => ref.read(friendRepositoryProvider);

  int _controllerEpoch = 0;
  int _requestEpoch = 0;
  bool _disposed = false;
  Timer? _resultLeaseTimer;

  @override
  Future<AvailabilityState> build() async {
    _disposed = false;
    ref.onDispose(() {
      _disposed = true;
      ++_controllerEpoch;
      ++_requestEpoch;
      _resultLeaseTimer?.cancel();
      _resultLeaseTimer = null;
    });
    final controllerEpoch = ++_controllerEpoch;
    final session = ref.watch(currentAuthSessionProvider);
    final initial = AvailabilityState(selectedDate: _todayInJapan());
    if (session == null) {
      return initial.copyWith(
        status: AvailabilityStatus.error,
        errorKind: AvailabilityErrorKind.unauthenticated,
        errorMessage: '空きコマ検索にはログインが必要です。',
      );
    }

    final loading = initial.copyWith(
      viewerUserId: session.userId,
      status: AvailabilityStatus.loadingFriends,
      errorKind: AvailabilityErrorKind.none,
      clearError: true,
    );
    try {
      final relationships = await _repository.listRelationships();
      if (!_isCurrent(controllerEpoch, session.userId)) return loading;
      return loading.copyWith(
        friends: _accepted(relationships),
        status: AvailabilityStatus.ready,
      );
    } on Object catch (error) {
      if (!_isCurrent(controllerEpoch, session.userId)) return loading;
      return loading.copyWith(
        status: AvailabilityStatus.error,
        errorKind: _errorKind(error),
        errorMessage: _message(error),
      );
    }
  }

  Future<void> retry() async {
    final session = ref.read(currentAuthSessionProvider);
    if (session == null) {
      _publishUnauthenticated();
      return;
    }
    final current = state.valueOrNull ?? _defaultState(session.userId);
    // A retry shown after a completed search must repeat the same search, not
    // merely refresh the friend list. The search itself revalidates accepted
    // relationships immediately before fetching each participant.
    if (current.hasSearched &&
        (current.errorKind == AvailabilityErrorKind.network ||
            current.errorKind == AvailabilityErrorKind.authorization)) {
      await search();
      return;
    }
    final epoch = ++_requestEpoch;
    final controllerEpoch = _controllerEpoch;
    state = AsyncData(current.copyWith(
      status: AvailabilityStatus.loadingFriends,
      errorKind: AvailabilityErrorKind.none,
      clearError: true,
    ));
    try {
      final relationships = await _repository.listRelationships();
      if (!_isCurrent(controllerEpoch, session.userId) ||
          epoch != _requestEpoch) {
        return;
      }
      final accepted = _accepted(relationships);
      final selected = current.selectedFriendIds
          .where((id) => accepted.any((friend) => friend.otherUserId == id))
          .toSet();
      _publish(current.copyWith(
        friends: accepted,
        selectedFriendIds: selected,
        status: AvailabilityStatus.ready,
        errorKind: AvailabilityErrorKind.none,
        clearError: true,
      ));
    } on Object catch (error) {
      if (!_isCurrent(controllerEpoch, session.userId) ||
          epoch != _requestEpoch) {
        return;
      }
      _publish(current.copyWith(
        status: AvailabilityStatus.error,
        errorKind: _errorKind(error),
        errorMessage: _message(error),
      ));
    }
  }

  void setDate(DateTime value) {
    final current = _current;
    _invalidatePending(current.copyWith(
      selectedDate: DateTime.utc(value.year, value.month, value.day),
    ));
  }

  void setStartMinutes(int value) {
    _invalidatePending(_current.copyWith(startMinutes: value));
  }

  void setEndMinutes(int value) {
    _invalidatePending(_current.copyWith(endMinutes: value));
  }

  void setMinimumDurationMinutes(int value) {
    _invalidatePending(_current.copyWith(minimumDurationMinutes: value));
  }

  void toggleFriend(String friendUserId) {
    final accepted = _current.acceptedFriends
        .any((friend) => friend.otherUserId == friendUserId);
    if (!accepted) return;
    final selected = {..._current.selectedFriendIds};
    if (!selected.add(friendUserId)) selected.remove(friendUserId);
    _invalidatePending(_current.copyWith(selectedFriendIds: selected));
  }

  void setSelectedFriends(Iterable<String> friendUserIds) {
    final acceptedIds =
        _current.acceptedFriends.map((friend) => friend.otherUserId).toSet();
    _invalidatePending(_current.copyWith(
      selectedFriendIds: friendUserIds.where(acceptedIds.contains).toSet(),
    ));
  }

  Future<void> search() async {
    final session = ref.read(currentAuthSessionProvider);
    if (session == null) {
      _publishUnauthenticated();
      return;
    }
    final current = _current;
    final validation = _validate(current);
    if (validation != null) {
      _publish(current.copyWith(
        status: AvailabilityStatus.error,
        errorKind: AvailabilityErrorKind.validation,
        errorMessage: validation,
        windows: const [],
        hasSearched: false,
      ));
      return;
    }

    final requestEpoch = ++_requestEpoch;
    final controllerEpoch = _controllerEpoch;
    final selectedDate = current.selectedDate;
    final startMinutes = current.startMinutes;
    final endMinutes = current.endMinutes;
    final minimumDuration = Duration(minutes: current.minimumDurationMinutes);
    final selectedFriendIds = Set<String>.of(current.selectedFriendIds);
    final rangeStart = _atMinutes(selectedDate, startMinutes);
    final rangeEnd = _atMinutes(selectedDate, endMinutes);
    _publish(current.copyWith(
      status: AvailabilityStatus.searching,
      errorKind: AvailabilityErrorKind.none,
      windows: const [],
      clearError: true,
      hasSearched: true,
    ));

    try {
      // Re-read relationships immediately before fetching schedules. This
      // closes the window where a revoked friendship could remain selected.
      final relationships = await _repository.listRelationships();
      if (!_isRequestCurrent(requestEpoch, controllerEpoch, session.userId)) {
        return;
      }
      final accepted = _accepted(relationships);
      final acceptedIds = accepted.map((friend) => friend.otherUserId).toSet();
      if (!selectedFriendIds.every(acceptedIds.contains)) {
        _publishRelationshipSnapshot(accepted);
        throw const PermissionError('友だち関係が変更されたため、参加者を確認してください。');
      }

      final participantIds = <String>[session.userId, ...selectedFriendIds];
      final rows = <VisibleEventProjection>[];
      for (final ownerUserId in participantIds) {
        if (!_isRequestCurrent(requestEpoch, controllerEpoch, session.userId)) {
          return;
        }
        final terms = await _repository.listFriendTerms(ownerUserId);
        final term = _termCovering(terms, selectedDate);
        if (term == null) {
          throw const ValidationError('選択した日を含む学期情報を取得できませんでした。');
        }
        final snapshot = await _repository.fetchSchedule(
          friendUserId: ownerUserId,
          termId: term.id,
          rangeStart: rangeStart,
          rangeEnd: rangeEnd,
        );
        if (!snapshot.allowed) {
          throw const PermissionError('参加者の予定を取得する権限が失効しました。');
        }
        rows.addAll(
          snapshot.rows
              .where((event) =>
                  ownerUserId == session.userId ||
                  event.visibilityLevel != VisibilityLevel.private)
              .map(
                (event) => VisibleEventProjection(
                  eventId: event.eventId,
                  ownerUserId: ownerUserId,
                  startAt: event.startAt,
                  endAt: event.endAt,
                  // The owner is allowed to receive PRIVATE timing, but the
                  // availability projection must still treat that timing as
                  // busy. Friend PRIVATE rows are filtered above and never
                  // reach this projection.
                  visibilityLevel:
                      event.visibilityLevel == VisibilityLevel.private &&
                              ownerUserId == session.userId
                          ? VisibilityLevel.busyOnly
                          : event.visibilityLevel,
                  title: event.title,
                ),
              ),
        );
      }

      final windows = FreeTimeSearchService().findCommonFreeWindows(
        rangeStart: rangeStart,
        rangeEnd: rangeEnd,
        visibleEvents: rows,
        minimumDuration: minimumDuration,
      );
      final latestRelationships = await _repository.listRelationships();
      if (!_isRequestCurrent(requestEpoch, controllerEpoch, session.userId)) {
        return;
      }
      final latestAccepted = _accepted(latestRelationships);
      final latestById = {
        for (final relationship in latestAccepted)
          relationship.otherUserId: relationship,
      };
      final prefetchedById = {
        for (final relationship in accepted)
          relationship.otherUserId: relationship,
      };
      final relationshipChanged = selectedFriendIds.any((friendId) {
        final before = prefetchedById[friendId];
        final after = latestById[friendId];
        return before == null ||
            after == null ||
            before.revision != after.revision ||
            before.incarnation != after.incarnation;
      });
      if (relationshipChanged) {
        _publishRelationshipSnapshot(latestAccepted);
        throw const PermissionError('友だち関係が変更されたため、参加者を確認してください。');
      }
      if (!_isRequestCurrent(requestEpoch, controllerEpoch, session.userId)) {
        return;
      }
      final latest = _current;
      final result = latest.copyWith(
        friends: accepted,
        selectedFriendIds: selectedFriendIds,
        windows: windows,
        status: windows.isEmpty
            ? AvailabilityStatus.noCandidates
            : AvailabilityStatus.success,
        errorKind: AvailabilityErrorKind.none,
        clearError: true,
        hasSearched: true,
      );
      _publish(result);
      _armResultLease(result);
    } on Object catch (error) {
      if (!_isRequestCurrent(requestEpoch, controllerEpoch, session.userId)) {
        return;
      }
      if (error is PermissionError) {
        try {
          final latestRelationships = await _repository.listRelationships();
          if (!_isRequestCurrent(
              requestEpoch, controllerEpoch, session.userId)) {
            return;
          }
          _publishRelationshipSnapshot(_accepted(latestRelationships));
        } on Object {
          // Preserve the authorization error if refreshing the relationship
          // list is itself unavailable.
        }
      }
      _publish(_current.copyWith(
        status: AvailabilityStatus.error,
        errorKind: _errorKind(error),
        errorMessage: _message(error),
        windows: const [],
        hasSearched: true,
      ));
    }
  }

  AvailabilityState get _current =>
      state.valueOrNull ??
      _defaultState(ref.read(currentAuthSessionProvider)?.userId);

  /// Clears a displayed result after a bounded authorization/lifecycle event.
  ///
  /// Search inputs and the accepted participant selection remain available for
  /// an explicit retry, but no previously authorized schedule projection is
  /// left visible while its authorization lifetime is uncertain.
  void invalidateDisplayedResults() {
    final current = _current;
    if (!current.hasSearched && current.windows.isEmpty) return;
    _clearResultLease();
    ++_requestEpoch;
    _publish(current.copyWith(
      windows: const [],
      status: AvailabilityStatus.ready,
      errorKind: AvailabilityErrorKind.none,
      clearError: true,
      hasSearched: false,
    ));
  }

  /// Called by the availability route when the app returns to the foreground.
  /// The next explicit search revalidates relationships and schedule access.
  void onAppResumed() => invalidateDisplayedResults();

  AvailabilityState _defaultState(String? userId) => AvailabilityState(
        selectedDate: _todayInJapan(),
        viewerUserId: userId,
      );

  void _invalidatePending(AvailabilityState next) {
    _clearResultLease();
    ++_requestEpoch;
    _publish(next.copyWith(
      windows: const [],
      status: next.errorKind == AvailabilityErrorKind.validation
          ? AvailabilityStatus.error
          : AvailabilityStatus.ready,
      errorKind: AvailabilityErrorKind.none,
      clearError: true,
      hasSearched: false,
    ));
  }

  void _publish(AvailabilityState value) {
    if (_disposed) return;
    state = AsyncData(value);
  }

  void _publishRelationshipSnapshot(List<FriendRelationship> accepted) {
    final selected = _current.selectedFriendIds
        .where((id) => accepted.any((friend) => friend.otherUserId == id))
        .toSet();
    _publish(_current.copyWith(
      friends: accepted,
      selectedFriendIds: selected,
    ));
  }

  void _publishUnauthenticated() {
    _clearResultLease();
    ++_requestEpoch;
    _publish(_current.copyWith(
      status: AvailabilityStatus.error,
      errorKind: AvailabilityErrorKind.unauthenticated,
      errorMessage: '空きコマ検索にはログインが必要です。',
      windows: const [],
    ));
  }

  bool _isCurrent(int controllerEpoch, String userId) =>
      !_disposed &&
      controllerEpoch == _controllerEpoch &&
      ref.read(currentAuthSessionProvider)?.userId == userId;

  bool _isRequestCurrent(
          int requestEpoch, int controllerEpoch, String userId) =>
      requestEpoch == _requestEpoch && _isCurrent(controllerEpoch, userId);

  List<FriendRelationship> _accepted(List<FriendRelationship> input) =>
      input.where((friend) => friend.isAccepted).toList(growable: false);

  void _armResultLease(AvailabilityState result) {
    _clearResultLease();
    if (result.status != AvailabilityStatus.success &&
        result.status != AvailabilityStatus.noCandidates) {
      return;
    }
    final duration = ref.read(friendAuthorizationLeaseDurationProvider);
    _resultLeaseTimer = Timer(duration, () {
      if (_disposed) return;
      final current = _current;
      if (current.hasSearched &&
          (current.status == AvailabilityStatus.success ||
              current.status == AvailabilityStatus.noCandidates)) {
        invalidateDisplayedResults();
      }
    });
  }

  void _clearResultLease() {
    _resultLeaseTimer?.cancel();
    _resultLeaseTimer = null;
  }

  FriendTerm? _termCovering(List<FriendTerm> terms, DateTime selectedDate) {
    final date = DateTime.utc(
      selectedDate.year,
      selectedDate.month,
      selectedDate.day,
    );
    for (final term in terms) {
      final start = _dateOnly(term.startDate);
      final end = _dateOnly(term.endDate);
      if (!date.isBefore(start) && !date.isAfter(end)) return term;
    }
    return null;
  }

  DateTime _dateOnly(DateTime value) {
    // Term start/end are backend civil dates. Reconstruct their JST calendar
    // fields so a transport instant such as UTC 15:00 (JST midnight) does not
    // shift the represented date backward.
    final civil = JapanTime.civil(value);
    return DateTime.utc(civil.year, civil.month, civil.day);
  }

  DateTime _todayInJapan() {
    final civil = JapanTime.civil(ref.read(appClockProvider).now());
    return DateTime.utc(civil.year, civil.month, civil.day);
  }

  DateTime _atMinutes(DateTime date, int minutes) {
    final base = JapanTime.at(
      year: date.year,
      month: date.month,
      day: date.day,
    );
    return base.add(Duration(minutes: minutes));
  }

  String? _validate(AvailabilityState value) {
    if (!value.hasValidRange) return '開始時刻は終了時刻より前にしてください。';
    if (value.minimumDurationMinutes <= 0 ||
        value.minimumDurationMinutes > 24 * 60) {
      return '最小時間は1分以上で指定してください。';
    }
    if (value.minimumDurationMinutes > value.endMinutes - value.startMinutes) {
      return '最小時間は検索範囲以内にしてください。';
    }
    if (value.selectedFriendIds.isEmpty) {
      return '少なくとも1人の承認済みの友だちを選択してください。';
    }
    return null;
  }

  AvailabilityErrorKind _errorKind(Object error) {
    if (error is PermissionError || error is AuthError) {
      return AvailabilityErrorKind.authorization;
    }
    if (error is ValidationError) return AvailabilityErrorKind.validation;
    if (error is NetworkError) return AvailabilityErrorKind.network;
    return AvailabilityErrorKind.network;
  }

  String _message(Object error) {
    if (error is AppError) return error.message;
    return '予定を取得できませんでした。通信を確認して再試行してください。';
  }
}
