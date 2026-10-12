// ignore_for_file: curly_braces_in_flow_control_structures

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_domain/shared_domain.dart';

import '../../../core/config/app_config_provider.dart';
import '../../../core/error/app_error.dart';
import '../../auth/application/auth_providers.dart';
import '../data/supabase_group_repository.dart';
import '../domain/group_models.dart';
import '../domain/group_repository.dart';

final groupRepositoryProvider = Provider<GroupRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  if (client == null) return const UnavailableGroupRepository();
  return SupabaseGroupRepository(client);
});

class GroupState {
  const GroupState(
      {this.groups = const [],
      this.selected,
      this.members = const [],
      this.blockedMemberUserIds = const {},
      this.blockedMemberStatusLoaded = false,
      this.blockedMemberStatusGroupId,
      this.blockedMemberStatusViewerUserId,
      this.invites = const [],
      this.events = const [],
      this.eventRsvps = const [],
      this.eventRsvpEventId,
      this.eventComments = const [],
      this.eventCommentsEventId,
      this.eventReactions = const [],
      this.eventReactionsEventId,
      this.eventContentGeneration,
      this.eventCommentDraft,
      this.eventDraft,
      this.availabilityResult,
      this.availabilityWindows = const [],
      this.preview,
      this.previewTokenDigest,
      this.createdInvite,
      this.loading = false,
      this.mutating = false,
      this.errorMessage});
  final List<GroupSummary> groups;
  final GroupSummary? selected;
  final List<GroupMemberSummary> members;
  final Set<String> blockedMemberUserIds;
  final bool blockedMemberStatusLoaded;
  final String? blockedMemberStatusGroupId;
  final String? blockedMemberStatusViewerUserId;
  final List<GroupInviteSummary> invites;
  final List<GroupEventSummary> events;
  final List<GroupEventRsvp> eventRsvps;
  final String? eventRsvpEventId;
  final List<GroupEventComment> eventComments;
  final String? eventCommentsEventId;
  final List<GroupEventReaction> eventReactions;
  final String? eventReactionsEventId;
  final String? eventContentGeneration;
  final GroupEventCommentDraft? eventCommentDraft;
  final GroupEventDraft? eventDraft;
  final GroupAvailabilityResult? availabilityResult;
  final List<TimeWindow> availabilityWindows;
  final GroupInvitePreview? preview;
  final String? previewTokenDigest;
  final GroupInviteCreated? createdInvite;
  final bool loading;
  final bool mutating;
  final String? errorMessage;
  GroupState copyWith(
          {List<GroupSummary>? groups,
          GroupSummary? selected,
          bool clearSelected = false,
          List<GroupMemberSummary>? members,
          Set<String>? blockedMemberUserIds,
          bool? blockedMemberStatusLoaded,
          String? blockedMemberStatusGroupId,
          String? blockedMemberStatusViewerUserId,
          bool clearMemberBlockStatus = false,
          List<GroupInviteSummary>? invites,
          List<GroupEventSummary>? events,
          List<GroupEventRsvp>? eventRsvps,
          String? eventRsvpEventId,
          bool clearEventRsvps = false,
          List<GroupEventComment>? eventComments,
          String? eventCommentsEventId,
          bool clearEventComments = false,
          List<GroupEventReaction>? eventReactions,
          String? eventReactionsEventId,
          bool clearEventReactions = false,
          String? eventContentGeneration,
          bool clearEventContent = false,
          GroupEventCommentDraft? eventCommentDraft,
          bool clearEventCommentDraft = false,
          GroupEventDraft? eventDraft,
          bool clearEventDraft = false,
          GroupAvailabilityResult? availabilityResult,
          List<TimeWindow>? availabilityWindows,
          bool clearAvailability = false,
          GroupInvitePreview? preview,
          String? previewTokenDigest,
          bool clearPreview = false,
          GroupInviteCreated? createdInvite,
          bool clearCreatedInvite = false,
          bool? loading,
          bool? mutating,
          String? errorMessage,
          bool clearError = false}) =>
      GroupState(
          groups: groups ?? this.groups,
          selected: clearSelected ? null : selected ?? this.selected,
          members: members ?? this.members,
          blockedMemberUserIds: clearMemberBlockStatus
              ? const {}
              : blockedMemberUserIds ?? this.blockedMemberUserIds,
          blockedMemberStatusLoaded: clearMemberBlockStatus
              ? false
              : blockedMemberStatusLoaded ?? this.blockedMemberStatusLoaded,
          blockedMemberStatusGroupId: clearMemberBlockStatus
              ? null
              : blockedMemberStatusGroupId ?? this.blockedMemberStatusGroupId,
          blockedMemberStatusViewerUserId: clearMemberBlockStatus
              ? null
              : blockedMemberStatusViewerUserId ??
                  this.blockedMemberStatusViewerUserId,
          invites: invites ?? this.invites,
          events: events ?? this.events,
          eventRsvps:
              clearEventRsvps ? const [] : eventRsvps ?? this.eventRsvps,
          eventRsvpEventId: clearEventRsvps
              ? null
              : eventRsvpEventId ?? this.eventRsvpEventId,
          eventComments: clearEventComments
              ? const []
              : eventComments ?? this.eventComments,
          eventCommentsEventId: clearEventComments
              ? null
              : eventCommentsEventId ?? this.eventCommentsEventId,
          eventReactions: clearEventReactions
              ? const []
              : eventReactions ?? this.eventReactions,
          eventReactionsEventId: clearEventReactions
              ? null
              : eventReactionsEventId ?? this.eventReactionsEventId,
          eventContentGeneration: clearEventContent
              ? null
              : eventContentGeneration ?? this.eventContentGeneration,
          eventCommentDraft: clearEventCommentDraft
              ? null
              : eventCommentDraft ?? this.eventCommentDraft,
          eventDraft: clearEventDraft ? null : eventDraft ?? this.eventDraft,
          availabilityResult: clearAvailability
              ? null
              : availabilityResult ?? this.availabilityResult,
          availabilityWindows: clearAvailability
              ? const []
              : availabilityWindows ?? this.availabilityWindows,
          preview: clearPreview ? null : preview ?? this.preview,
          previewTokenDigest: clearPreview
              ? null
              : previewTokenDigest ?? this.previewTokenDigest,
          createdInvite:
              clearCreatedInvite ? null : createdInvite ?? this.createdInvite,
          loading: loading ?? this.loading,
          mutating: mutating ?? this.mutating,
          errorMessage: clearError ? null : errorMessage ?? this.errorMessage);
}

final groupsControllerProvider =
    AsyncNotifierProvider<GroupsController, GroupState>(GroupsController.new);

class GroupsController extends AsyncNotifier<GroupState> {
  GroupRepository get _repository => ref.read(groupRepositoryProvider);
  int _epoch = 0;
  int _memberBlockProjectionEpoch = 0;
  bool _disposed = false;

  @override
  Future<GroupState> build() async {
    _disposed = false;
    final epoch = ++_epoch;
    ref.onDispose(() {
      _disposed = true;
      ++_epoch;
    });
    final session = ref.watch(currentAuthSessionProvider);
    if (session == null) {
      return const GroupState(errorMessage: 'グループ機能にはログインが必要です。');
    }
    try {
      final groups = await _repository.listGroups();
      if (!_current(epoch, session.userId)) return const GroupState();
      return GroupState(groups: groups);
    } on Object catch (e) {
      if (!_current(epoch, session.userId)) return const GroupState();
      return GroupState(errorMessage: _message(e));
    }
  }

  Future<void> refresh() async {
    final session = ref.read(currentAuthSessionProvider);
    if (session == null) return;
    final epoch = ++_epoch;
    _publish(_state.copyWith(loading: true, clearError: true));
    try {
      final groups = await _repository.listGroups();
      if (_current(epoch, session.userId))
        _publish(_state.copyWith(groups: groups, loading: false));
    } on Object catch (e) {
      if (_current(epoch, session.userId))
        _publish(_state.copyWith(loading: false, errorMessage: _message(e)));
    }
  }

  Future<GroupSummary?> create(
      {required String name,
      required String type,
      String? description,
      required String eventCreatePolicy}) async {
    final session = ref.read(currentAuthSessionProvider);
    if (session == null) return null;
    final epoch = ++_epoch;
    _publish(_state.copyWith(mutating: true, clearError: true));
    try {
      final group = await _repository.createGroup(
          name: name,
          type: type,
          description: description,
          eventCreatePolicy: eventCreatePolicy);
      if (!_current(epoch, session.userId)) return null;
      _publish(_state.copyWith(
          groups: [group, ..._state.groups], selected: group, mutating: false));
      return group;
    } on Object catch (e) {
      if (_current(epoch, session.userId))
        _publish(_state.copyWith(mutating: false, errorMessage: _message(e)));
      return null;
    }
  }

  Future<bool> open(String id) async {
    final session = ref.read(currentAuthSessionProvider);
    if (session == null) return false;
    final epoch = ++_epoch;
    ++_memberBlockProjectionEpoch;
    _publish(_state.copyWith(
      selected: null,
      clearSelected: true,
      members: const [],
      clearMemberBlockStatus: true,
      invites: const [],
      events: const [],
      clearAvailability: true,
      clearEventRsvps: true,
      clearEventComments: true,
      clearEventReactions: true,
      clearEventContent: true,
      clearEventCommentDraft: true,
      loading: true,
      clearError: true,
    ));
    try {
      final group = await _repository.getGroup(id);
      final members = await _repository.listMembers(id);
      Set<String>? blockedMemberUserIds;
      try {
        blockedMemberUserIds = await _repository.listBlockedGroupMembers(id);
      } on Object {
        // A missing RPC on a retained pre-migration DB or any fetch failure
        // remains unknown. Presentation stays fail-closed for peer names.
      }
      final events = await _repository.listGroupEvents(id);
      final invites =
          group.role == GroupRole.owner || group.role == GroupRole.admin
              ? await _repository.listInvites(id)
              : const <GroupInviteSummary>[];
      if (!_current(epoch, session.userId)) return false;
      _publish(_state.copyWith(
          selected: group,
          members: members,
          blockedMemberUserIds: blockedMemberUserIds ?? const {},
          blockedMemberStatusLoaded: blockedMemberUserIds != null,
          blockedMemberStatusGroupId: blockedMemberUserIds == null ? null : id,
          blockedMemberStatusViewerUserId:
              blockedMemberUserIds == null ? null : session.userId,
          invites: invites,
          events: events,
          loading: false));
      return true;
    } on Object catch (e) {
      if (_current(epoch, session.userId))
        _publish(_state.copyWith(loading: false, errorMessage: _message(e)));
      return false;
    }
  }

  Future<void> refreshMemberBlockStatus(String groupId) async {
    final session = ref.read(currentAuthSessionProvider);
    if (session == null || _state.selected?.id != groupId) return;
    final epoch = _epoch;
    final projectionEpoch = ++_memberBlockProjectionEpoch;
    _publish(_state.copyWith(clearMemberBlockStatus: true));
    try {
      final blockedMemberUserIds =
          await _repository.listBlockedGroupMembers(groupId);
      if (projectionEpoch != _memberBlockProjectionEpoch ||
          !_current(epoch, session.userId) ||
          _state.selected?.id != groupId) return;
      _publish(_state.copyWith(
        blockedMemberUserIds: blockedMemberUserIds,
        blockedMemberStatusLoaded: true,
        blockedMemberStatusGroupId: groupId,
        blockedMemberStatusViewerUserId: session.userId,
      ));
    } on Object {
      // Preserve unknown state if the RPC is unavailable or cannot complete.
    }
  }

  Future<GroupInvitePreview?> preview(String token) async {
    final initialSession = ref.read(currentAuthSessionProvider)?.userId;
    final epoch = ++_epoch;
    _publish(
        _state.copyWith(clearPreview: true, loading: true, clearError: true));
    try {
      final preview = await _repository.previewInvite(token);
      if (!_previewCurrent(epoch, initialSession)) return null;
      _publish(_state.copyWith(
          preview: preview,
          previewTokenDigest: _digestToken(token),
          loading: false));
      return preview;
    } on Object catch (e) {
      if (_previewCurrent(epoch, initialSession))
        _publish(_state.copyWith(loading: false, errorMessage: _message(e)));
      return null;
    }
  }

  Future<GroupSummary?> join(String token) async {
    final session = ref.read(currentAuthSessionProvider);
    if (session == null) return null;
    final epoch = ++_epoch;
    _publish(_state.copyWith(mutating: true, clearError: true));
    try {
      final group = await _repository.joinInvite(token);
      if (!_current(epoch, session.userId)) return null;
      _publish(_state.copyWith(
          groups: [group, ..._state.groups.where((g) => g.id != group.id)],
          selected: group,
          clearPreview: true,
          mutating: false));
      return group;
    } on Object catch (e) {
      if (_current(epoch, session.userId))
        _publish(_state.copyWith(mutating: false, errorMessage: _message(e)));
      return null;
    }
  }

  Future<GroupInviteCreated?> createInvite(String groupId) async {
    final session = ref.read(currentAuthSessionProvider);
    if (session == null) return null;
    final epoch = ++_epoch;
    _publish(_state.copyWith(mutating: true, clearError: true));
    try {
      final invite = await _repository.createInvite(
          groupId: groupId,
          expiresAt: DateTime.now().toUtc().add(const Duration(days: 7)),
          maxUses: 1);
      if (!_current(epoch, session.userId)) return null;
      _publish(_state.copyWith(createdInvite: invite, mutating: false));
      return invite;
    } on Object catch (e) {
      if (_current(epoch, session.userId))
        _publish(_state.copyWith(mutating: false, errorMessage: _message(e)));
      return null;
    }
  }

  void clearCreatedInvite() {
    _publish(_state.copyWith(clearCreatedInvite: true));
  }

  String digestToken(String token) => _digestToken(token);

  Future<bool> leave(String id) async =>
      _voidMutation(() => _repository.leaveGroup(id));
  Future<bool> delete(String id) async =>
      _voidMutation(() => _repository.deleteGroup(id));

  Future<bool> updateGroup(
      {required String groupId,
      required String name,
      required String type,
      String? description,
      required String eventCreatePolicy}) async {
    final session = ref.read(currentAuthSessionProvider);
    if (session == null) return false;
    final epoch = ++_epoch;
    _publish(_state.copyWith(mutating: true, clearError: true));
    try {
      final group = await _repository.updateGroup(
          groupId: groupId,
          name: name,
          type: type,
          description: description,
          eventCreatePolicy: eventCreatePolicy);
      if (!_current(epoch, session.userId)) return false;
      _publish(_state.copyWith(
          selected: group,
          groups:
              _state.groups.map((g) => g.id == group.id ? group : g).toList(),
          mutating: false));
      return true;
    } on Object catch (e) {
      if (!_disposed &&
          ref.read(currentAuthSessionProvider)?.userId == session.userId) {
        _publish(_state.copyWith(mutating: false, errorMessage: _message(e)));
      }
      return false;
    }
  }

  Future<bool> setGroupDefaultVisibility({
    required String groupId,
    required String visibility,
  }) async {
    final session = ref.read(currentAuthSessionProvider);
    if (session == null ||
        !const {'PRIVATE', 'BUSY_ONLY', 'TITLE_ONLY', 'FULL'}
            .contains(visibility)) {
      return false;
    }
    ++_epoch;
    _publish(_state.copyWith(mutating: true, clearError: true));
    try {
      final savedVisibility = await _repository.setGroupDefaultVisibility(
          groupId: groupId, visibility: visibility);
      if (_disposed ||
          ref.read(currentAuthSessionProvider)?.userId != session.userId) {
        return false;
      }
      final current = _state.selected;
      if (current == null || current.id != groupId) {
        _publish(_state.copyWith(mutating: false));
        return false;
      }
      final group = current.copyWith(defaultVisibility: savedVisibility);
      _publish(_state.copyWith(
        selected: group,
        groups: _state.groups.map((g) => g.id == group.id ? group : g).toList(),
        mutating: false,
      ));
      return true;
    } on Object catch (e) {
      if (!_disposed &&
          ref.read(currentAuthSessionProvider)?.userId == session.userId) {
        _publish(_state.copyWith(mutating: false, errorMessage: _message(e)));
      }
      return false;
    }
  }

  Future<bool> revokeInvite(String groupId, String invitationId) async =>
      _voidMutation(() => _repository.revokeInvite(groupId, invitationId),
          retainSelection: true);

  Future<bool> createEvent(
      {required String groupId,
      required String title,
      required DateTime startAt,
      required DateTime endAt,
      String? location,
      String? description}) async {
    final session = ref.read(currentAuthSessionProvider);
    if (session == null) return false;
    final epoch = ++_epoch;
    _publish(_state.copyWith(mutating: true, clearError: true));
    try {
      final event = await _repository.createGroupEvent(
          groupId: groupId,
          title: title,
          startAt: startAt,
          endAt: endAt,
          location: location,
          description: description);
      if (!_current(epoch, session.userId)) return false;
      _publish(
          _state.copyWith(events: [event, ..._state.events], mutating: false));
      return true;
    } on Object catch (e) {
      if (_current(epoch, session.userId))
        _publish(_state.copyWith(mutating: false, errorMessage: _message(e)));
      return false;
    }
  }

  Future<bool> setEventRsvp(String eventId, String status) async {
    final session = ref.read(currentAuthSessionProvider);
    if (session == null) return false;
    final epoch = ++_epoch;
    _publish(_state.copyWith(mutating: true, clearError: true));
    try {
      final rsvp = await _repository.setGroupEventRsvp(eventId, status);
      if (!_current(epoch, session.userId)) return false;
      if (_state.eventRsvpEventId != eventId) return false;
      _publish(_state.copyWith(eventRsvps: [
        rsvp,
        ..._state.eventRsvps.where((r) => r.userId != rsvp.userId)
      ], eventRsvpEventId: eventId, mutating: false));
      return true;
    } on Object catch (e) {
      if (_current(epoch, session.userId))
        _publish(_state.copyWith(mutating: false, errorMessage: _message(e)));
      return false;
    }
  }

  Future<bool> loadEventRsvps(String eventId) async {
    final session = ref.read(currentAuthSessionProvider);
    if (session == null) return false;
    final epoch = ++_epoch;
    _publish(_state.copyWith(clearEventRsvps: true, clearError: true));
    try {
      final values = await _repository.listGroupEventRsvps(eventId);
      if (!_current(epoch, session.userId)) return false;
      _publish(_state.copyWith(eventRsvps: values, eventRsvpEventId: eventId));
      return true;
    } on Object catch (e) {
      if (_current(epoch, session.userId))
        _publish(_state.copyWith(errorMessage: _message(e)));
      return false;
    }
  }

  Future<bool> loadEventComments(String eventId) async {
    final session = ref.read(currentAuthSessionProvider);
    if (session == null) return false;
    final epoch = ++_epoch;
    _publish(_state.copyWith(clearEventComments: true, clearError: true));
    try {
      final values = await _repository.listGroupEventComments(eventId);
      if (!_current(epoch, session.userId)) return false;
      _publish(_state.copyWith(
          eventComments: values, eventCommentsEventId: eventId));
      return true;
    } on Object catch (e) {
      if (_current(epoch, session.userId))
        _publish(_state.copyWith(errorMessage: _message(e)));
      return false;
    }
  }

  Future<bool> loadEventContent(String eventId) async {
    final session = ref.read(currentAuthSessionProvider);
    if (session == null) return false;
    final epoch = ++_epoch;
    _publish(_state.copyWith(
        clearEventRsvps: true,
        clearEventComments: true,
        clearEventReactions: true,
        clearEventContent: true,
        clearError: true));
    try {
      final content = await _repository.getGroupEventContent(eventId);
      final valid = await _repository.validateGroupEventContent(
          eventId: eventId, generation: content.generation);
      if (!_current(epoch, session.userId) ||
          !valid ||
          content.eventId != eventId ||
          content.groupId != _state.selected?.id ||
          content.generation.isEmpty) {
        return false;
      }
      _publish(_state.copyWith(
          eventRsvps: content.rsvps,
          eventRsvpEventId: eventId,
          eventComments: content.comments,
          eventCommentsEventId: eventId,
          eventReactions: content.reactions,
          eventReactionsEventId: eventId,
          eventContentGeneration: content.generation));
      return true;
    } on Object catch (e) {
      if (_current(epoch, session.userId)) {
        _publish(_state.copyWith(
            clearEventRsvps: true,
            clearEventComments: true,
            clearEventReactions: true,
            clearEventContent: true,
            errorMessage: _message(e)));
      }
      return false;
    }
  }

  Future<bool> createComment(String eventId, String body) async {
    final session = ref.read(currentAuthSessionProvider);
    if (session == null) return false;
    final epoch = ++_epoch;
    _publish(_state.copyWith(mutating: true, clearError: true));
    try {
      final comment = await _repository.createGroupEventComment(
          eventId: eventId, body: body);
      if (!_current(epoch, session.userId)) return false;
      _publish(_state.copyWith(
          eventComments: _state.eventCommentsEventId == eventId
              ? [..._state.eventComments, comment]
              : _state.eventComments,
          eventCommentsEventId: eventId,
          mutating: false));
      return true;
    } on Object catch (e) {
      if (_current(epoch, session.userId))
        _publish(_state.copyWith(mutating: false, errorMessage: _message(e)));
      return false;
    }
  }

  Future<bool> updateComment(GroupEventComment comment, String body) async {
    final session = ref.read(currentAuthSessionProvider);
    if (session == null) return false;
    final epoch = ++_epoch;
    _publish(_state.copyWith(mutating: true, clearError: true));
    try {
      final value = await _repository.updateGroupEventComment(
          commentId: comment.commentId,
          body: body,
          expectedVersion: comment.version);
      if (!_current(epoch, session.userId)) return false;
      _publish(_state.copyWith(
          eventComments: _state.eventComments
              .map((item) => item.commentId == value.commentId ? value : item)
              .toList(),
          clearEventCommentDraft: true,
          mutating: false));
      return true;
    } on Object catch (e) {
      if (_current(epoch, session.userId)) {
        _publish(_state.copyWith(
            mutating: false,
            errorMessage: _message(e),
            eventCommentDraft: GroupEventCommentDraft(
                commentId: comment.commentId,
                body: body,
                expectedVersion: comment.version)));
        if (e is ConflictError) await loadEventContent(comment.eventId);
      }
      return false;
    }
  }

  Future<bool> deleteComment(GroupEventComment comment) async {
    final ok = await _contentVoid(() => _repository.deleteGroupEventComment(
        commentId: comment.commentId, expectedVersion: comment.version));
    if (ok) {
      _publish(_state.copyWith(
          eventComments: _state.eventComments
              .where((item) => item.commentId != comment.commentId)
              .toList()));
    }
    return ok;
  }

  Future<bool> moderateDeleteComment(String commentId) async {
    final ok = await _contentVoid(
        () => _repository.moderateDeleteGroupEventComment(commentId));
    if (ok) {
      _publish(_state.copyWith(
          eventComments: _state.eventComments
              .where((item) => item.commentId != commentId)
              .toList()));
    }
    return ok;
  }

  Future<bool> loadEventReactions(String eventId) async {
    final session = ref.read(currentAuthSessionProvider);
    if (session == null) return false;
    final epoch = ++_epoch;
    try {
      final values = await _repository.listGroupEventReactions(eventId);
      if (!_current(epoch, session.userId)) return false;
      _publish(_state.copyWith(
          eventReactions: values, eventReactionsEventId: eventId));
      return true;
    } on Object catch (e) {
      if (_current(epoch, session.userId))
        _publish(_state.copyWith(errorMessage: _message(e)));
      return false;
    }
  }

  Future<bool> setReaction(String eventId, String reaction) async {
    final ok = await _contentVoid(() => _repository.setGroupEventReaction(
        eventId: eventId, reaction: reaction));
    if (ok) await loadEventReactions(eventId);
    return ok;
  }

  Future<bool> removeReaction(String eventId, String reaction) async {
    final ok = await _contentVoid(() => _repository.removeGroupEventReaction(
        eventId: eventId, reaction: reaction));
    if (ok) await loadEventReactions(eventId);
    return ok;
  }

  Future<bool> reportContent({
    required String targetType,
    required String targetId,
    required String reason,
  }) =>
      _contentVoid(() => _repository.reportGroupContent(
          targetType: targetType, targetId: targetId, reason: reason));

  Future<bool> _contentVoid(Future<void> Function() action) async {
    final session = ref.read(currentAuthSessionProvider);
    if (session == null) return false;
    final epoch = ++_epoch;
    _publish(_state.copyWith(mutating: true, clearError: true));
    try {
      await action();
      if (!_current(epoch, session.userId)) return false;
      _publish(_state.copyWith(mutating: false));
      return true;
    } on Object catch (e) {
      if (_current(epoch, session.userId))
        _publish(_state.copyWith(mutating: false, errorMessage: _message(e)));
      return false;
    }
  }

  Future<bool> searchGroupAvailability(
      {required String groupId,
      required List<String> memberIds,
      required DateTime rangeStart,
      required DateTime rangeEnd,
      required int minimumDurationMinutes}) async {
    final session = ref.read(currentAuthSessionProvider);
    if (session == null) return false;
    final epoch = ++_epoch;
    _publish(_state.copyWith(
        loading: true, clearError: true, availabilityWindows: const []));
    try {
      final result = await _repository.findGroupAvailability(
          groupId: groupId,
          memberIds: memberIds,
          rangeStart: rangeStart,
          rangeEnd: rangeEnd,
          minimumDurationMinutes: minimumDurationMinutes);
      if (!_current(epoch, session.userId)) return false;
      if (!await _repository.validateGroupAvailability(
          groupId: groupId,
          memberIds: memberIds,
          generation: result.generation)) {
        throw const PermissionError('メンバー構成が変わったため、空き時間を再検索してください。');
      }
      if (!_current(epoch, session.userId)) return false;
      final rows = result.rows
          .map((row) => VisibleEventProjection(
              eventId: '${row.memberId}:${row.startAt.toIso8601String()}',
              ownerUserId: row.memberId,
              startAt: row.startAt,
              endAt: row.endAt,
              visibilityLevel: VisibilityLevel.busyOnly))
          .toList(growable: false);
      final windows = FreeTimeSearchService().findCommonFreeWindows(
          rangeStart: rangeStart,
          rangeEnd: rangeEnd,
          visibleEvents: rows,
          minimumDuration: Duration(minutes: minimumDurationMinutes));
      _publish(_state.copyWith(
          availabilityResult: result,
          availabilityWindows: windows,
          loading: false));
      Future<void>.delayed(const Duration(seconds: 60), () {
        if (!_disposed &&
            _state.availabilityResult?.queryId == result.queryId) {
          _publish(_state.copyWith(clearAvailability: true));
        }
      });
      return true;
    } on Object catch (e) {
      if (_current(epoch, session.userId)) {
        _publish(_state.copyWith(loading: false, errorMessage: _message(e)));
      }
      return false;
    }
  }

  void clearAvailability() {
    _publish(_state.copyWith(clearAvailability: true));
  }

  Future<bool> cancelEvent(String eventId, int version) async =>
      _voidMutation(() => _repository.cancelGroupEvent(eventId, version),
          retainSelection: true);

  Future<bool> updateEvent(
      {required String eventId,
      required String title,
      required DateTime startAt,
      required DateTime endAt,
      String? location,
      String? description,
      required int expectedVersion}) async {
    final session = ref.read(currentAuthSessionProvider);
    if (session == null) return false;
    final epoch = ++_epoch;
    _publish(_state.copyWith(mutating: true, clearError: true));
    try {
      final event = await _repository.updateGroupEvent(
          eventId: eventId,
          title: title,
          startAt: startAt,
          endAt: endAt,
          location: location,
          description: description,
          expectedVersion: expectedVersion);
      if (!_current(epoch, session.userId)) return false;
      _publish(_state.copyWith(
          events: _state.events
              .map((e) => e.eventId == event.eventId ? event : e)
              .toList(),
          clearEventDraft: true,
          mutating: false));
      return true;
    } on Object catch (e) {
      if (_current(epoch, session.userId)) {
        _publish(_state.copyWith(
            mutating: false,
            errorMessage: _message(e),
            eventDraft: GroupEventDraft(
                eventId: eventId,
                title: title,
                startAt: startAt,
                endAt: endAt,
                location: location,
                description: description)));
        if (e is ConflictError && _state.selected != null) {
          await open(_state.selected!.id);
        }
      }
      return false;
    }
  }

  Future<bool> changeRole(String groupId, String userId, GroupRole role) async {
    return _voidMutation(
      () => _repository.changeMemberRole(groupId, userId, role),
      retainSelection: true,
    );
  }

  Future<bool> transferOwnership(String groupId, String userId) async {
    return _voidMutation(
      () => _repository.transferOwnership(groupId, userId),
      retainSelection: true,
    );
  }

  Future<bool> removeMember(String groupId, String userId) async {
    return _voidMutation(
      () => _repository.removeMember(groupId, userId),
      retainSelection: true,
    );
  }

  Future<bool> _voidMutation(
    Future<void> Function() action, {
    bool retainSelection = false,
  }) async {
    final session = ref.read(currentAuthSessionProvider);
    if (session == null) return false;
    final epoch = ++_epoch;
    _publish(_state.copyWith(mutating: true, clearError: true));
    try {
      await action();
      if (!_current(epoch, session.userId)) return false;
      _publish(_state.copyWith(
        mutating: false,
        clearSelected: !retainSelection,
      ));
      if (retainSelection && _state.selected != null) {
        await open(_state.selected!.id);
      } else {
        await refresh();
      }
      return true;
    } on Object catch (e) {
      if (_current(epoch, session.userId))
        _publish(_state.copyWith(mutating: false, errorMessage: _message(e)));
      return false;
    }
  }

  GroupState get _state => state.valueOrNull ?? const GroupState();
  void _publish(GroupState value) {
    if (!_disposed) state = AsyncData(value);
  }

  bool _current(int epoch, String? userId) =>
      !_disposed &&
      epoch == _epoch &&
      userId != null &&
      ref.read(currentAuthSessionProvider)?.userId == userId;
  bool _previewCurrent(int epoch, String? initialSession) =>
      !_disposed &&
      epoch == _epoch &&
      ref.read(currentAuthSessionProvider)?.userId == initialSession;
  String _message(Object e) =>
      e is AppError ? e.message : 'グループ操作に失敗しました。通信と権限を確認してください。';
  String _digestToken(String token) =>
      sha256.convert(utf8.encode(token.toLowerCase())).toString();
}
