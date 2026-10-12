import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:shared_domain/shared_domain.dart';
import 'package:uuid/uuid.dart';

import '../../../core/config/app_config_provider.dart';
import '../../../core/error/app_error.dart';
import '../../../core/native/native_scope_bridge.dart';
import '../../../core/time/app_clock.dart';
import '../../../local_db/app_database_provider.dart';
import '../../auth/application/auth_providers.dart';
import '../../timetable/data/local_schedule_repository.dart';
import '../data/shared_friend_cache_database.dart';
import '../data/supabase_friend_repository.dart';
import '../domain/friend_models.dart';
import '../domain/friend_repository.dart';

final sharedFriendCacheDatabaseProvider = Provider<SharedFriendCacheDatabase>((
  ref,
) {
  final appPath = ref.watch(appDatabasePathProvider);
  final database = SharedFriendCacheDatabase(
    p.join(p.dirname(appPath), 'shared_friend_cache.sqlite'),
  );
  ref.onDispose(() => unawaited(database.close()));
  return database;
});

final friendRepositoryProvider = Provider<FriendRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  if (client == null) return const UnavailableFriendRepository();
  return SupabaseFriendRepository(client);
});

final friendsControllerProvider =
    AsyncNotifierProvider<FriendsController, FriendState>(
  FriendsController.new,
);

final friendAuthorizationLeaseDurationProvider =
    Provider<Duration>((ref) => const Duration(seconds: 60));

class FriendAuthorizationLease {
  FriendAuthorizationLease({
    this.ttl = const Duration(seconds: 60),
    void Function()? onExpired,
  }) : _stopwatch = (Stopwatch()..start()) {
    _expiryTimer = Timer(ttl, () {
      if (_closed) return;
      _closed = true;
      onExpired?.call();
    });
  }

  final Duration ttl;
  final Stopwatch _stopwatch;
  Timer? _expiryTimer;
  bool _closed = false;

  bool get isValid => !_closed && _stopwatch.elapsed < ttl;

  void close() {
    _closed = true;
    _expiryTimer?.cancel();
    _expiryTimer = null;
  }
}

class FriendsController extends AsyncNotifier<FriendState> {
  FriendRepository get _repository => ref.read(friendRepositoryProvider);
  SharedFriendCacheDatabase get _cache =>
      ref.read(sharedFriendCacheDatabaseProvider);

  String? _inviteToken;
  String? _inviteSessionId;
  FriendInvitation? _pendingInvitation;
  String? _pendingInvitationSessionId;
  int _inviteEpoch = 0;
  String? _selectedFriendId;
  bool _selectedPreview = false;
  DateTime? _selectedRangeStart;
  DateTime? _selectedRangeEnd;
  FriendScheduleScope? _selectedScope;
  FriendAuthorizationLease? _lease;
  Timer? _refreshTimer;
  int _requestEpoch = 0;
  int _controllerEpoch = 0;
  bool _foregroundSharing = false;
  Object? _foregroundView;
  bool _appActive = true;
  int _relationshipEpoch = 0;
  int _usernameSearchEpoch = 0;
  int _usernameRequestEpoch = 0;
  Timer? _usernameSearchTimer;
  String? _cacheViewerUserId;
  DateTime? _pendingInviteExpiresAt;
  String? _pendingInviteSessionId;

  @override
  Future<FriendState> build() async {
    final controllerEpoch = ++_controllerEpoch;
    ++_requestEpoch;
    ++_relationshipEpoch;
    ++_usernameSearchEpoch;
    _usernameSearchTimer?.cancel();
    _usernameSearchTimer = null;
    ++_inviteEpoch;
    _lease?.close();
    _selectedScope = null;
    _inviteToken = null;
    _inviteSessionId = null;
    ref.onDispose(() {
      _lease?.close();
      _refreshTimer?.cancel();
    });
    final session = ref.watch(currentAuthSessionProvider);
    final context = ref.watch(activeScheduleContextProvider);
    if (session == null || context == null) {
      _pendingInvitation = null;
      _pendingInvitationSessionId = null;
      final previousViewer = _cacheViewerUserId;
      _cacheViewerUserId = null;
      if (previousViewer != null) await _cache.clearViewer(previousViewer);
      return const FriendState();
    }
    if (_pendingInvitationSessionId != session.userId ||
        !(_pendingInvitation?.isActive ?? false)) {
      _pendingInvitation = null;
      _pendingInvitationSessionId = session.userId;
    }
    await _cache.initializeRegion(ref.read(storageRegionProvider).id);
    if (!_isControllerCurrent(controllerEpoch, session.userId)) {
      return const FriendState();
    }
    // A controller rebuild can follow an account switch without a process
    // restart.  Remove the previous viewer's partition before any new state
    // can be published; account A -> B -> A must not inherit A's old rows.
    final previousViewer = _cacheViewerUserId;
    if (previousViewer != null && previousViewer != session.userId) {
      await _cache.clearViewer(previousViewer);
    }
    _cacheViewerUserId = session.userId;
    try {
      final relationships = await _repository.listRelationships();
      final blocked = await _repository.listBlockedUsers();
      final invitations = await _repository.listInvitations();
      final friendUsername = await _repository.getMyFriendUsername();
      final visibilityRules = await _loadVisibilityRules(relationships);
      if (!_isControllerCurrent(controllerEpoch, session.userId)) {
        return const FriendState();
      }
      final pendingInvitation = _usablePendingInvitation(
        session.userId,
        invitations,
      );
      return FriendState(
        relationships: relationships,
        blockedUserIds: blocked.keys.toSet(),
        blockedUsers: blocked,
        blockStatusLoaded: true,
        blockStatusViewerUserId: session.userId,
        issuedInvitations: invitations,
        visibilityRules: visibilityRules,
        pendingInvitation: pendingInvitation,
        friendUsername: friendUsername,
      );
    } on Object catch (error) {
      return FriendState(
        isOffline: true,
        errorMessage: _safeMessage(error),
      );
    }
  }

  Future<void> refreshRelationships() async {
    final session = ref.read(currentAuthSessionProvider);
    if (session == null) return;
    _invalidateBlockStatus();
    ++_usernameSearchEpoch;
    _usernameSearchTimer?.cancel();
    _usernameSearchTimer = null;
    final controllerEpoch = _controllerEpoch;
    final relationshipEpoch = ++_relationshipEpoch;
    try {
      final relationships = await _repository.listRelationships();
      final blocked = await _repository.listBlockedUsers();
      final invitations = await _repository.listInvitations();
      final friendUsername = await _repository.getMyFriendUsername();
      final visibilityRules = await _loadVisibilityRules(relationships);
      if (!_isControllerCurrent(controllerEpoch, session.userId) ||
          relationshipEpoch != _relationshipEpoch) {
        return;
      }
      final current = state.valueOrNull ?? const FriendState();
      final pendingInvitation = _usablePendingInvitation(
        session.userId,
        invitations,
      );
      state = AsyncData(current.copyWith(
        relationships: relationships,
        blockedUserIds: blocked.keys.toSet(),
        blockedUsers: blocked,
        blockStatusLoaded: true,
        blockStatusViewerUserId: session.userId,
        issuedInvitations: invitations,
        visibilityRules: visibilityRules,
        isOffline: false,
        clearError: true,
        pendingInvitation: pendingInvitation,
        clearPendingInvitation: pendingInvitation == null,
        friendUsername: friendUsername,
        usernameQuery: '',
        usernameMatches: const [],
        isSearchingUsername: false,
        clearUsernameError: true,
      ));
    } on Object catch (error) {
      if (_isControllerCurrent(controllerEpoch, session.userId) &&
          relationshipEpoch == _relationshipEpoch) {
        _setError(error);
      }
    }
  }

  void onUsernameQueryChanged(String rawQuery) {
    final query = FriendUsernamePolicy.normalize(rawQuery);
    final epoch = ++_usernameSearchEpoch;
    _usernameSearchTimer?.cancel();
    final current = state.valueOrNull ?? const FriendState();
    state = AsyncData(current.copyWith(
      usernameQuery: query,
      usernameMatches: const [],
      isSearchingUsername: FriendUsernamePolicy.isValid(query),
      clearUsernameError: true,
    ));
    if (!FriendUsernamePolicy.isValid(query)) {
      state = AsyncData((state.valueOrNull ?? current).copyWith(
        isSearchingUsername: false,
      ));
      return;
    }
    final sessionId = ref.read(currentAuthSessionProvider)?.userId;
    if (sessionId == null) {
      _clearUsernameSearch(error: 'ログインが必要です');
      return;
    }
    final controllerEpoch = _controllerEpoch;
    _usernameSearchTimer = Timer(const Duration(milliseconds: 300), () {
      unawaited(_lookupUsername(
        query,
        sessionId: sessionId,
        controllerEpoch: controllerEpoch,
        searchEpoch: epoch,
      ));
    });
  }

  Future<void> _lookupUsername(
    String query, {
    required String sessionId,
    required int controllerEpoch,
    required int searchEpoch,
  }) async {
    try {
      final matches = await _repository.findFriendByUsername(query);
      if (!_isUsernameSearchCurrent(
        query,
        sessionId: sessionId,
        controllerEpoch: controllerEpoch,
        searchEpoch: searchEpoch,
      )) {
        return;
      }
      state = AsyncData((state.valueOrNull ?? const FriendState()).copyWith(
        usernameMatches: matches.take(1).toList(growable: false),
        isSearchingUsername: false,
        clearUsernameError: true,
      ));
    } on Object catch (error) {
      if (_isUsernameSearchCurrent(
        query,
        sessionId: sessionId,
        controllerEpoch: controllerEpoch,
        searchEpoch: searchEpoch,
      )) {
        _clearUsernameSearch(error: _safeMessage(error));
      }
    }
  }

  bool _isUsernameSearchCurrent(
    String query, {
    required String sessionId,
    required int controllerEpoch,
    required int searchEpoch,
  }) {
    final current = state.valueOrNull;
    return _isControllerCurrent(controllerEpoch, sessionId) &&
        searchEpoch == _usernameSearchEpoch &&
        current?.usernameQuery == query &&
        FriendUsernamePolicy.isValid(query);
  }

  void _clearUsernameSearch({String? error}) {
    ++_usernameSearchEpoch;
    _usernameSearchTimer?.cancel();
    final current = state.valueOrNull ?? const FriendState();
    state = AsyncData(current.copyWith(
      usernameQuery: '',
      usernameMatches: const [],
      isSearchingUsername: false,
      usernameError: error,
      clearUsernameError: error == null,
    ));
  }

  Future<bool> saveMyFriendUsername({
    required String username,
    required bool searchable,
  }) async {
    final sessionId = ref.read(currentAuthSessionProvider)?.userId;
    final clean = FriendUsernamePolicy.normalize(username);
    if (sessionId == null) {
      _clearUsernameSearch(error: 'ログインが必要です');
      return false;
    }
    if ((clean.isNotEmpty && !FriendUsernamePolicy.isValid(clean)) ||
        (searchable && clean.isEmpty)) {
      state = AsyncData((state.valueOrNull ?? const FriendState()).copyWith(
        usernameError: 'ユーザー名は半角英数字と _ の3〜32文字で入力してください',
      ));
      return false;
    }
    final controllerEpoch = _controllerEpoch;
    final current = state.valueOrNull ?? const FriendState();
    state =
        AsyncData(current.copyWith(isMutating: true, clearUsernameError: true));
    try {
      final profile = await _repository.setMyFriendUsername(
        username: clean.isEmpty ? null : clean,
        searchable: searchable,
      );
      if (!_isControllerCurrent(controllerEpoch, sessionId)) return false;
      _clearUsernameSearch();
      state = AsyncData((state.valueOrNull ?? current).copyWith(
        friendUsername: profile,
        isMutating: false,
      ));
      return true;
    } on Object catch (error) {
      if (_isControllerCurrent(controllerEpoch, sessionId)) {
        _clearUsernameSearch(error: _safeMessage(error));
        state = AsyncData((state.valueOrNull ?? current).copyWith(
          isMutating: false,
        ));
      }
      return false;
    }
  }

  Future<bool> confirmUsernameFriendRequest(FriendUsernameMatch target) async {
    final sessionId = ref.read(currentAuthSessionProvider)?.userId;
    final current = state.valueOrNull ?? const FriendState();
    final query = current.usernameQuery;
    if (current.isMutating ||
        sessionId == null ||
        current.usernameMatches.length != 1 ||
        current.usernameMatches.single.userId != target.userId ||
        current.usernameMatches.single.username != target.username ||
        query != target.username) {
      _clearUsernameSearch(error: '検索結果が更新されました。もう一度検索してください');
      return false;
    }
    final searchEpoch = _usernameSearchEpoch;
    final controllerEpoch = _controllerEpoch;
    final mutationEpoch = ++_usernameRequestEpoch;
    final operationId = const Uuid().v4();
    state =
        AsyncData(current.copyWith(isMutating: true, clearUsernameError: true));
    try {
      final relationship = await _repository.requestFriendByUsername(
        target: target,
        shownUsername: target.username,
        operationId: operationId,
      );
      if (!_isUsernameSearchCurrent(
        query,
        sessionId: sessionId,
        controllerEpoch: controllerEpoch,
        searchEpoch: searchEpoch,
      )) {
        return false;
      }
      final latest = state.valueOrNull ?? current;
      state = AsyncData(latest.copyWith(
        relationships: [
          ...latest.relationships.where((item) => item.id != relationship.id),
          relationship,
        ],
        usernameQuery: '',
        usernameMatches: const [],
        isSearchingUsername: false,
        isMutating: false,
        clearUsernameError: true,
      ));
      ++_usernameSearchEpoch;
      return true;
    } on Object catch (error) {
      if (_isControllerCurrent(controllerEpoch, sessionId) &&
          searchEpoch == _usernameSearchEpoch) {
        _clearUsernameSearch(error: _safeMessage(error));
        state = AsyncData((state.valueOrNull ?? current).copyWith(
          isMutating: false,
        ));
      }
      return false;
    } finally {
      // Query edits and realtime/offline invalidation intentionally make the
      // response stale, but they must not strand this mutation's busy state.
      // This fence is independent of the search epoch and still prevents an
      // old account/controller request from clearing a newer mutation.
      if (_isControllerCurrent(controllerEpoch, sessionId) &&
          mutationEpoch == _usernameRequestEpoch) {
        final latest = state.valueOrNull;
        if (latest != null && latest.isMutating) {
          state = AsyncData(latest.copyWith(isMutating: false));
        }
      }
    }
  }

  Future<FriendInvitation?> createInvitation() async {
    if (state.valueOrNull?.isMutating == true) return null;
    final session = ref.read(currentAuthSessionProvider);
    if (session == null) {
      _setError(const PermissionError('招待リンクの発行にはログインが必要です'));
      return null;
    }
    final current = state.valueOrNull ?? const FriendState();
    final controllerEpoch = _controllerEpoch;
    final reusable = _usablePendingInvitation(
      session.userId,
      current.issuedInvitations,
    );
    if (reusable != null) {
      if (current.pendingInvitation?.id != reusable.id) {
        state = AsyncData(current.copyWith(pendingInvitation: reusable));
      }
      return reusable;
    }
    if (_pendingInviteSessionId != session.userId) {
      _pendingInviteSessionId = session.userId;
      _pendingInviteExpiresAt = null;
    }
    state = AsyncData(current.copyWith(isMutating: true, clearError: true));
    try {
      // Seven days is the smallest useful recovery window for manual link
      // delivery and is recorded in the Phase 8 handoff.
      final expiresAt = _pendingInviteExpiresAt ??=
          ref.read(appClockProvider).now().toUtc().add(const Duration(days: 7));
      final result = await _repository.createInvitation(expiresAt: expiresAt);
      if (!_isControllerCurrent(controllerEpoch, session.userId)) {
        return null;
      }
      state = AsyncData((state.valueOrNull ?? current).copyWith(
        pendingInvitation: result,
        issuedInvitations: [
          ...current.issuedInvitations,
          FriendInvitationSummary(id: result.id, expiresAt: result.expiresAt),
        ],
        isMutating: false,
        isOffline: false,
        clearError: true,
      ));
      _pendingInvitation = result;
      _pendingInvitationSessionId = session.userId;
      _pendingInviteExpiresAt = null;
      _pendingInviteSessionId = null;
      return result;
    } on Object catch (error) {
      if (_isControllerCurrent(controllerEpoch, session.userId)) {
        _setError(error);
      }
      return null;
    }
  }

  Future<bool> revokeInvitation(String invitationId) async {
    return _onlineMutation(
      () => _repository.revokeInvitation(invitationId),
      onSuccess: (_) async {
        final current = state.valueOrNull ?? const FriendState();
        state = AsyncData(current.copyWith(
          issuedInvitations: current.issuedInvitations
              .map((invite) => invite.id == invitationId
                  ? invite.copyWith(revoked: true)
                  : invite)
              .toList(growable: false),
        ));
        if (_pendingInvitation?.id == invitationId) {
          _pendingInvitation = null;
          _pendingInvitationSessionId = null;
          state = AsyncData(
            (state.valueOrNull ?? current).copyWith(
              clearPendingInvitation: true,
            ),
          );
        }
      },
    );
  }

  FriendInvitation? _usablePendingInvitation(
    String sessionId,
    List<FriendInvitationSummary> summaries,
  ) {
    final pending = _pendingInvitation;
    if (_pendingInvitationSessionId != sessionId || pending == null) {
      return null;
    }
    final summary =
        summaries.where((item) => item.id == pending.id).firstOrNull;
    if (summary == null || !summary.isActive || !pending.isActive) {
      _pendingInvitation = null;
      _pendingInvitationSessionId = sessionId;
      return null;
    }
    return pending;
  }

  /// Clears only expired in-memory invite material. Server refresh remains the
  /// authority for claimed/revoked state; callers use this for exact local
  /// expiry rendering without issuing another invitation.
  void clearExpiredPendingInvitation() {
    final pending = _pendingInvitation;
    final current = state.valueOrNull;
    if (pending == null || current == null || pending.isActive) return;
    _pendingInvitation = null;
    _pendingInvitationSessionId = null;
    state = AsyncData(current.copyWith(clearPendingInvitation: true));
  }

  Future<void> previewInvitation(String token) async {
    final session = ref.read(currentAuthSessionProvider);
    if (session == null || token.trim().isEmpty) {
      _setError(const PermissionError('招待の確認にはログインが必要です'));
      return;
    }
    _inviteToken = token;
    _inviteSessionId = session.userId;
    final inviteEpoch = ++_inviteEpoch;
    final controllerEpoch = _controllerEpoch;
    final current = state.valueOrNull ?? const FriendState();
    state = AsyncData(current.copyWith(
      isLoading: true,
      clearPreview: true,
      clearError: true,
    ));
    try {
      final preview = await _repository.previewInvitation(token);
      if (!_inviteIsCurrent(session.userId) ||
          controllerEpoch != _controllerEpoch ||
          inviteEpoch != _inviteEpoch) {
        return;
      }
      state = AsyncData((state.valueOrNull ?? current).copyWith(
        preview: preview,
        isLoading: false,
        isOffline: false,
        clearError: true,
      ));
    } on Object catch (error) {
      if (_inviteIsCurrent(session.userId) &&
          controllerEpoch == _controllerEpoch &&
          inviteEpoch == _inviteEpoch) {
        _setError(error);
      }
    }
  }

  Future<bool> requestInvitation() async {
    final token = _inviteToken;
    final sessionId = _inviteSessionId;
    final inviteEpoch = _inviteEpoch;
    final preview = state.valueOrNull?.preview;
    if (token == null ||
        sessionId == null ||
        preview == null ||
        !preview.isUsable ||
        state.valueOrNull?.isLoading == true ||
        !_inviteIsCurrent(sessionId)) {
      _setError(const ValidationError('招待をもう一度開いてください'));
      return false;
    }
    final result = await _onlineMutation(
      () async {
        final relationship = await _repository.requestInvitation(token);
        if (!_inviteIsCurrent(sessionId) ||
            preview.issuerUserId == null ||
            relationship.otherUserId != preview.issuerUserId ||
            inviteEpoch != _inviteEpoch) {
          throw const AuthError('認証中の利用者が変わりました');
        }
        return relationship;
      },
      onSuccess: (relationship) async {
        final current = state.valueOrNull ?? const FriendState();
        state = AsyncData(current.copyWith(
          relationships: [
            ...current.relationships
                .where((item) => item.id != relationship.id),
            relationship,
          ],
          clearPreview: true,
        ));
        _inviteToken = null;
        _inviteSessionId = null;
        _inviteEpoch++;
      },
      isCurrent: () =>
          _inviteIsCurrent(sessionId) && inviteEpoch == _inviteEpoch,
    );
    return result;
  }

  Future<bool> respondToRequest(
    FriendRelationship relationship, {
    required bool accept,
  }) async {
    final result = await _onlineMutation(
      () => _repository.respondToRequest(
        relationship: relationship,
        accept: accept,
      ),
    );
    if (result) await refreshRelationships();
    return result;
  }

  Future<bool> cancelRequest(FriendRelationship relationship) async {
    final result = await _onlineMutation(
      () => _repository.cancelRequest(relationship),
    );
    if (result) await refreshRelationships();
    return result;
  }

  Future<bool> setVisibility(
    FriendRelationship relationship,
    VisibilityLevel level, {
    String targetKind = 'default',
    String? targetId,
    String? targetValue,
    bool inherit = false,
  }) async {
    final result = await _onlineMutation(
      () => _repository.setVisibility(
        relationship: relationship,
        friendUserId: relationship.otherUserId,
        level: level.wireName,
        targetKind: targetKind,
        targetId: targetId,
        targetValue: targetValue,
        inherit: inherit,
      ),
    );
    if (result) {
      await _invalidateFriend(relationship.otherUserId);
      await refreshRelationships();
    }
    return result;
  }

  Future<Map<String, List<FriendVisibilityRule>>> _loadVisibilityRules(
    List<FriendRelationship> relationships,
  ) async {
    final accepted = relationships.where((item) => item.isAccepted);
    final entries = await Future.wait(
      accepted.map(
        (relationship) async => MapEntry(
          relationship.otherUserId,
          await _repository.listVisibilityRules(relationship),
        ),
      ),
    );
    return Map<String, List<FriendVisibilityRule>>.fromEntries(entries);
  }

  Future<bool> removeFriend(FriendRelationship relationship) async {
    await _invalidateFriend(relationship.otherUserId);
    final result = await _onlineMutation(
      () => _repository.removeFriend(relationship),
    );
    if (result) await refreshRelationships();
    return result;
  }

  Future<bool> blockUser(FriendRelationship relationship) async {
    await _invalidateFriend(relationship.otherUserId);
    _invalidateBlockStatus();
    final result = await _onlineMutation(
      () => _repository.blockUser(relationship.otherUserId),
    );
    if (result) await refreshRelationships();
    return result;
  }

  Future<bool> unblockUser(String userId) async {
    _invalidateBlockStatus();
    final result = await _onlineMutation(() => _repository.unblockUser(userId));
    if (result) await refreshRelationships();
    return result;
  }

  Future<void> selectFriend(
    FriendRelationship relationship, {
    DateTime? rangeStart,
    DateTime? rangeEnd,
  }) async {
    if (!relationship.isAccepted) return;
    _selectedFriendId = relationship.otherUserId;
    _selectedPreview = false;
    _selectedRangeStart = rangeStart;
    _selectedRangeEnd = rangeEnd;
    _setForegroundSharing(true);
    await _fetchFriendSchedule(
      relationship.otherUserId,
      rangeStart: rangeStart,
      rangeEnd: rangeEnd,
      preview: false,
    );
  }

  Future<void> previewFriend(
    FriendRelationship relationship, {
    DateTime? rangeStart,
    DateTime? rangeEnd,
  }) async {
    _selectedFriendId = relationship.otherUserId;
    _selectedPreview = true;
    _selectedRangeStart = rangeStart;
    _selectedRangeEnd = rangeEnd;
    _setForegroundSharing(true);
    await _fetchFriendSchedule(
      relationship.otherUserId,
      rangeStart: rangeStart,
      rangeEnd: rangeEnd,
      preview: true,
    );
  }

  void setForegroundSharing(bool active) {
    _setForegroundSharing(active);
    if (!active) {
      _selectedFriendId = null;
      unawaited(_invalidateSelected());
    }
  }

  void claimForegroundView(Object view) {
    _foregroundView = view;
    _setForegroundSharing(true);
  }

  void releaseForegroundView(Object view) {
    if (!identical(_foregroundView, view)) return;
    _foregroundView = null;
    setForegroundSharing(false);
  }

  Future<void> refreshSelected() async {
    final friendId = _selectedFriendId;
    if (friendId == null || !_foregroundSharing || !_appActive) return;
    final relationship = (state.valueOrNull?.relationships ?? const [])
        .where((item) => item.otherUserId == friendId && item.isAccepted)
        .firstOrNull;
    if (relationship == null) return;
    if (_selectedPreview) {
      await previewFriend(
        relationship,
        rangeStart: _selectedRangeStart,
        rangeEnd: _selectedRangeEnd,
      );
    } else {
      await selectFriend(
        relationship,
        rangeStart: _selectedRangeStart,
        rangeEnd: _selectedRangeEnd,
      );
    }
  }

  Future<void> onConnectionLost() async {
    _clearUsernameSearch();
    final invalidation = _invalidateSelected();
    final epoch = _requestEpoch;
    await invalidation;
    if (epoch != _requestEpoch) return;
    final current = state.valueOrNull ?? const FriendState();
    state = AsyncData(current.copyWith(isOffline: true));
  }

  Future<void> onAppResumed() async {
    _appActive = true;
    await onConnectionRestored();
  }

  Future<void> onConnectionRestored() async {
    if (!_appActive) return;
    _setForegroundSharing(_foregroundSharing);
    await refreshRelationships();
    if (_foregroundSharing) await refreshSelected();
  }

  Future<void> onAppPaused() async {
    _appActive = false;
    _refreshTimer?.cancel();
    await onConnectionLost();
  }

  /// Realtime is only an accelerator.  Close the friend view before any
  /// asynchronous cleanup, then refresh the authoritative relationship list
  /// and restore the exact selected mode if the screen is still active.
  Future<void> onFriendInvalidated() async {
    _clearUsernameSearch();
    final hadSelection = _selectedFriendId != null;
    final invalidation = _invalidateSelected();
    final epoch = _requestEpoch;
    await invalidation;
    if (epoch != _requestEpoch) return;
    await refreshRelationships();
    if (epoch == _requestEpoch && hadSelection && _foregroundSharing) {
      await refreshSelected();
    }
  }

  Future<bool> _onlineMutation<T>(
    Future<T> Function() action, {
    Future<void> Function(T value)? onSuccess,
    bool Function()? isCurrent,
  }) async {
    final current = state.valueOrNull ?? const FriendState();
    if (current.isMutating) return false;
    final sessionId = ref.read(currentAuthSessionProvider)?.userId;
    final controllerEpoch = _controllerEpoch;
    state = AsyncData(current.copyWith(isMutating: true, clearError: true));
    try {
      final value = await action();
      if (sessionId == null ||
          !_isControllerCurrent(controllerEpoch, sessionId) ||
          !(isCurrent?.call() ?? true)) {
        return false;
      }
      if (onSuccess != null) await onSuccess(value);
      if (state.valueOrNull != null) {
        state = AsyncData(state.valueOrNull!.copyWith(
          isMutating: false,
          isOffline: false,
          clearError: true,
        ));
      }
      return true;
    } on Object catch (error) {
      if (sessionId == null ||
          !_isControllerCurrent(controllerEpoch, sessionId) ||
          !(isCurrent?.call() ?? true)) {
        return false;
      }
      await refreshRelationships();
      if (_isControllerCurrent(controllerEpoch, sessionId) &&
          (isCurrent?.call() ?? true)) {
        _setError(error);
      }
      return false;
    }
  }

  Future<void> _fetchFriendSchedule(
    String friendUserId, {
    DateTime? rangeStart,
    DateTime? rangeEnd,
    required bool preview,
  }) async {
    if (!_appActive) return;
    final session = ref.read(currentAuthSessionProvider);
    final context = ref.read(activeScheduleContextProvider);
    if (session == null || context == null) return;
    final epoch = ++_requestEpoch;
    final controllerEpoch = _controllerEpoch;
    _lease?.close();
    final lease = FriendAuthorizationLease(
      ttl: ref.read(friendAuthorizationLeaseDurationProvider),
      onExpired: () {
        if (epoch == _requestEpoch) unawaited(_invalidateSelected());
      },
    );
    _lease = lease;
    _selectedScope = null;
    final current = state.valueOrNull ?? const FriendState();
    state = AsyncData(current.copyWith(
      selectedFriend: current.relationships
          .where((item) => item.otherUserId == friendUserId)
          .firstOrNull,
      scheduleFriendId: friendUserId,
      schedulePreview: preview,
      schedule: const [],
      scheduleAllowed: false,
      isLoading: true,
      clearError: true,
    ));
    try {
      final nativeScope = await ref.read(nativeScopeBridgeProvider).current();
      if (!nativeScope.active ||
          nativeScope.regionId == null ||
          nativeScope.ownerHash == null ||
          nativeScope.activationToken == null ||
          nativeScope.regionId != ref.read(storageRegionProvider).id ||
          !nativeScope.matchesOwner(session.userId)) {
        if (epoch == _requestEpoch) await onConnectionLost();
        return;
      }
      if (!await _isLiveNativeRequest(
        epoch: epoch,
        controllerEpoch: controllerEpoch,
        sessionId: session.userId,
        context: context,
        capturedScope: nativeScope,
        lease: lease,
      )) {
        if (epoch == _requestEpoch) await _invalidateSelected();
        return;
      }
      final baseScope = FriendScheduleScope(
        viewerUserId: session.userId,
        sourceOwnerUserId: preview ? session.userId : friendUserId,
        contextKey: jsonEncode({
          'universityId': context.universityId,
          'termId': context.termId,
          'academicYear': context.academicYear,
          'calendarId': context.primaryCalendarId,
        }),
        regionId: nativeScope.regionId!,
        ownerHash: nativeScope.ownerHash!,
        activationToken: nativeScope.activationToken!,
        generation: nativeScope.generation,
        accessMode: preview ? 'owner-preview' : 'friend',
        effectiveViewerUserId: preview ? friendUserId : session.userId,
      );
      final start = rangeStart ?? ref.read(appClockProvider).now().toUtc();
      final end = rangeEnd ?? start.add(const Duration(days: 90));
      final friendTerms = await _repository.listFriendTerms(
        preview ? session.userId : friendUserId,
      );
      if (epoch != _requestEpoch ||
          ref.read(currentAuthSessionProvider)?.userId != session.userId ||
          !lease.isValid) {
        return;
      }
      if (!await _isLiveNativeRequest(
        epoch: epoch,
        controllerEpoch: controllerEpoch,
        sessionId: session.userId,
        context: context,
        capturedScope: nativeScope,
        lease: lease,
      )) {
        if (epoch == _requestEpoch) await _invalidateSelected();
        return;
      }
      final friendTerm = _selectFriendTerm(friendTerms, start, end);
      if (friendTerm == null) {
        throw const ValidationError('相手の学期情報を確認できませんでした');
      }
      final scope = FriendScheduleScope(
        viewerUserId: baseScope.viewerUserId,
        sourceOwnerUserId: baseScope.sourceOwnerUserId,
        contextKey: jsonEncode({
          'viewer': jsonDecode(baseScope.contextKey),
          'ownerTermId': friendTerm.id,
          'ownerAcademicYear': friendTerm.academicYear,
        }),
        regionId: baseScope.regionId,
        ownerHash: baseScope.ownerHash,
        activationToken: baseScope.activationToken,
        generation: baseScope.generation,
        accessMode: baseScope.accessMode,
        effectiveViewerUserId: baseScope.effectiveViewerUserId,
      );
      _selectedScope = scope;
      final result = preview
          ? await _repository.previewSchedule(
              friendUserId: friendUserId,
              termId: friendTerm.id,
              rangeStart: start,
              rangeEnd: end,
            )
          : await _repository.fetchSchedule(
              friendUserId: friendUserId,
              termId: friendTerm.id,
              rangeStart: start,
              rangeEnd: end,
            );
      if (!_isCurrentRequest(
        epoch: epoch,
        controllerEpoch: controllerEpoch,
        sessionId: session.userId,
        scope: scope,
        lease: lease,
      )) {
        return;
      }
      if (!await _isLiveNativeRequest(
        epoch: epoch,
        controllerEpoch: controllerEpoch,
        sessionId: session.userId,
        context: context,
        capturedScope: nativeScope,
        lease: lease,
      )) {
        if (epoch == _requestEpoch) await _invalidateSelected();
        return;
      }
      final rows = result.rows
          .map((event) => SharedFriendCacheRowsCompanion.insert(
                cacheKey: '${scope.partitionKey}|${event.eventId}',
                partitionKey: scope.partitionKey,
                viewerUserId: scope.viewerUserId,
                sourceOwnerUserId: scope.sourceOwnerUserId,
                sourceType: 'event',
                sourceId: event.eventId,
                contextKey: scope.contextKey,
                regionId: scope.regionId,
                ownerHash: scope.ownerHash,
                activationToken: scope.activationToken,
                generation: scope.generation,
                accessMode: scope.accessMode,
                effectiveViewerUserId: scope.effectiveViewerUserId,
                requestEpoch: epoch,
                revision: result.revision,
                visibilityLevel: event.visibilityLevel.wireName,
                startAtMs: event.startAt.millisecondsSinceEpoch,
                endAtMs: event.endAt.millisecondsSinceEpoch,
                title: Value(event.title),
                kind: Value(event.kind),
                instructorName: Value(event.instructorName),
                location: Value(event.location),
                description: Value(event.description),
                fetchedAtMs:
                    ref.read(appClockProvider).now().millisecondsSinceEpoch,
              ))
          .toList(growable: false);
      final cacheWritten = await _cache.replaceSnapshotIfCurrent(
        partition: FriendCachePartition(
          viewerUserId: scope.viewerUserId,
          sourceOwnerUserId: scope.sourceOwnerUserId,
          contextKey: scope.contextKey,
          regionId: scope.regionId,
          ownerHash: scope.ownerHash,
          activationToken: scope.activationToken,
          generation: scope.generation,
          accessMode: scope.accessMode,
          effectiveViewerUserId: scope.effectiveViewerUserId,
        ),
        allowed: result.allowed,
        revision: result.revision,
        requestEpoch: epoch,
        rows: rows,
        fetchedAtMs: ref.read(appClockProvider).now().millisecondsSinceEpoch,
        isCurrent: () => _isCurrentRequest(
          epoch: epoch,
          controllerEpoch: controllerEpoch,
          sessionId: session.userId,
          scope: scope,
          lease: lease,
        ),
      );
      if (!cacheWritten) {
        return;
      }
      if (!_isCurrentRequest(
        epoch: epoch,
        controllerEpoch: controllerEpoch,
        sessionId: session.userId,
        scope: scope,
        lease: lease,
      )) {
        return;
      }
      final cachedRows = await _cache.rowsFor(scope.partitionKey);
      if (!_isCurrentRequest(
        epoch: epoch,
        controllerEpoch: controllerEpoch,
        sessionId: session.userId,
        scope: scope,
        lease: lease,
      )) {
        if (epoch == _requestEpoch) await _invalidateSelected();
        return;
      }
      if (!await _isLiveNativeRequest(
        epoch: epoch,
        controllerEpoch: controllerEpoch,
        sessionId: session.userId,
        context: context,
        capturedScope: nativeScope,
        lease: lease,
      )) {
        if (epoch == _requestEpoch) await _invalidateSelected();
        return;
      }
      state = AsyncData((state.valueOrNull ?? current).copyWith(
        schedule: cachedRows.map(_eventFromCache).toList(growable: false),
        scheduleAllowed: result.allowed,
        isLoading: false,
        isOffline: false,
        clearError: true,
      ));
    } on Object catch (error) {
      lease.close();
      if (epoch == _requestEpoch &&
          controllerEpoch == _controllerEpoch &&
          ref.read(currentAuthSessionProvider)?.userId == session.userId) {
        final invalidation = _invalidateSelected();
        final errorEpoch = _requestEpoch;
        await invalidation;
        if (errorEpoch == _requestEpoch &&
            _isControllerCurrent(controllerEpoch, session.userId)) {
          _setError(error);
        }
      }
    }
  }

  bool _isCurrentRequest({
    required int epoch,
    required int controllerEpoch,
    required String sessionId,
    required FriendScheduleScope scope,
    required FriendAuthorizationLease lease,
  }) {
    final current = ref.read(currentAuthSessionProvider);
    final context = ref.read(activeScheduleContextProvider);
    return lease.isValid &&
        epoch == _requestEpoch &&
        controllerEpoch == _controllerEpoch &&
        current?.userId == sessionId &&
        _selectedScope?.partitionKey == scope.partitionKey &&
        context?.ownerUserId == sessionId;
  }

  bool _isControllerCurrent(int epoch, String sessionId) {
    return epoch == _controllerEpoch &&
        ref.read(currentAuthSessionProvider)?.userId == sessionId;
  }

  Future<bool> _isLiveNativeRequest({
    required int epoch,
    required int controllerEpoch,
    required String sessionId,
    required ActiveScheduleContext context,
    required NativeScopeState capturedScope,
    required FriendAuthorizationLease lease,
  }) async {
    if (!lease.isValid ||
        epoch != _requestEpoch ||
        controllerEpoch != _controllerEpoch ||
        ref.read(currentAuthSessionProvider)?.userId != sessionId) {
      return false;
    }
    final liveContext = ref.read(activeScheduleContextProvider);
    if (liveContext == null ||
        liveContext.ownerUserId != context.ownerUserId ||
        liveContext.universityId != context.universityId ||
        liveContext.termId != context.termId ||
        liveContext.academicYear != context.academicYear ||
        liveContext.primaryCalendarId != context.primaryCalendarId) {
      return false;
    }
    final liveScope = await ref.read(nativeScopeBridgeProvider).current();
    // The native read itself is asynchronous.  Recheck every fence after it
    // completes so an account/context/native ABA during that await cannot
    // make an old tuple look current again.
    final postReadContext = ref.read(activeScheduleContextProvider);
    if (!lease.isValid ||
        epoch != _requestEpoch ||
        controllerEpoch != _controllerEpoch ||
        ref.read(currentAuthSessionProvider)?.userId != sessionId ||
        postReadContext == null ||
        postReadContext.ownerUserId != context.ownerUserId ||
        postReadContext.universityId != context.universityId ||
        postReadContext.termId != context.termId ||
        postReadContext.academicYear != context.academicYear ||
        postReadContext.primaryCalendarId != context.primaryCalendarId) {
      return false;
    }
    if (liveScope.regionId != ref.read(storageRegionProvider).id ||
        !liveScope.matchesOwner(sessionId)) {
      return false;
    }
    return liveScope.active == capturedScope.active &&
        liveScope.regionId == capturedScope.regionId &&
        liveScope.ownerHash == capturedScope.ownerHash &&
        liveScope.activationToken == capturedScope.activationToken &&
        liveScope.generation == capturedScope.generation;
  }

  FriendSharedEvent _eventFromCache(SharedFriendCacheRow row) {
    return FriendSharedEvent(
      eventId: row.sourceId,
      ownerUserId: row.sourceOwnerUserId,
      startAt: DateTime.fromMillisecondsSinceEpoch(
        row.startAtMs,
        isUtc: true,
      ),
      endAt: DateTime.fromMillisecondsSinceEpoch(row.endAtMs, isUtc: true),
      visibilityLevel: VisibilityLevel.fromWire(row.visibilityLevel),
      title: row.title,
      kind: row.kind,
      instructorName: row.instructorName,
      location: row.location,
      description: row.description,
    );
  }

  FriendTerm? _selectFriendTerm(
    List<FriendTerm> terms,
    DateTime rangeStart,
    DateTime rangeEnd,
  ) {
    final overlapping = terms
        .where((term) =>
            term.startDate.isBefore(rangeEnd) &&
            term.endDate.isAfter(rangeStart))
        .toList(growable: false)
      ..sort((a, b) => a.startDate.compareTo(b.startDate));
    if (overlapping.isNotEmpty) return overlapping.first;
    final future = terms
        .where((term) => term.startDate.isAfter(rangeStart))
        .toList(growable: false)
      ..sort((a, b) => a.startDate.compareTo(b.startDate));
    if (future.isNotEmpty) return future.first;
    return terms.isEmpty ? null : terms.last;
  }

  Future<void> _invalidateSelected() async {
    _lease?.close();
    _lease = null;
    final scope = _selectedScope;
    _selectedScope = null;
    _requestEpoch++;
    final current = state.valueOrNull ?? const FriendState();
    state = AsyncData(current.copyWith(
      schedule: const [],
      scheduleAllowed: false,
      isLoading: false,
      clearSelectedFriend: true,
      clearScheduleSelection: true,
    ));
    if (scope != null) await _cache.clearPartition(scope.partitionKey);
  }

  Future<void> _invalidateFriend(String friendUserId) async {
    _clearUsernameSearch();
    if (_selectedFriendId == friendUserId) await _invalidateSelected();
    final session = ref.read(currentAuthSessionProvider);
    if (session != null) await _cache.clearViewer(session.userId);
  }

  void _setForegroundSharing(bool active) {
    _foregroundSharing = active;
    _refreshTimer?.cancel();
    _refreshTimer = null;
    if (active && _appActive) {
      _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
        final lease = _lease;
        if (lease != null && !lease.isValid) {
          unawaited(_invalidateSelected());
        } else {
          unawaited(refreshSelected());
        }
      });
    }
  }

  bool _inviteIsCurrent(String sessionId) =>
      ref.read(currentAuthSessionProvider)?.userId == sessionId;

  void _invalidateBlockStatus() {
    final current = state.valueOrNull;
    if (current == null || !current.blockStatusLoaded) return;
    state = AsyncData(current.copyWith(blockStatusLoaded: false));
  }

  void _setError(Object error) {
    _clearUsernameSearch();
    final current = state.valueOrNull ?? const FriendState();
    state = AsyncData(current.copyWith(
      isLoading: false,
      isMutating: false,
      isOffline: error is NetworkError,
      errorMessage: _safeMessage(error),
    ));
  }

  String _safeMessage(Object error) {
    if (error is AppError) return error.message;
    return '共有情報を確認できませんでした。通信状態を確認してください。';
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
