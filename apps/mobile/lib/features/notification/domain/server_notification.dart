class ServerNotification {
  const ServerNotification({
    required this.id,
    required this.type,
    required this.groupId,
    required this.createdAt,
    this.eventId,
    this.invitationId,
    this.readAt,
  });

  final String id;
  final String type;
  final String groupId;
  final String? eventId;
  final String? invitationId;
  final DateTime createdAt;
  final DateTime? readAt;

  factory ServerNotification.fromJson(Map<String, dynamic> json) {
    return ServerNotification(
      id: _requiredUuid(json['inbox_id'], 'inbox_id'),
      type: _notificationType(json['notification_type']),
      groupId: _requiredUuid(json['group_id'], 'group_id'),
      eventId: _optionalUuid(json['event_id'], 'event_id'),
      invitationId: _optionalUuid(json['invitation_id'], 'invitation_id'),
      createdAt: DateTime.parse(json['created_at'] as String).toUtc(),
      readAt: (json['read_at'] as String?)?.let(DateTime.parse)?.toUtc(),
    );
  }
}

class TargetedGroupInvitation {
  const TargetedGroupInvitation({
    required this.id,
    required this.groupId,
    required this.groupName,
    required this.inviterName,
    required this.createdAt,
    required this.expiresAt,
  });

  final String id;
  final String groupId;
  final String groupName;
  final String inviterName;
  final DateTime createdAt;
  final DateTime expiresAt;

  factory TargetedGroupInvitation.fromJson(Map<String, dynamic> json) =>
      TargetedGroupInvitation(
        id: _requiredUuid(json['invitation_id'], 'invitation_id'),
        groupId: _requiredUuid(json['group_id'], 'group_id'),
        groupName: json['group_name'] as String,
        inviterName: json['inviter_display_name'] as String,
        createdAt: DateTime.parse(json['created_at'] as String).toUtc(),
        expiresAt: DateTime.parse(json['expires_at'] as String).toUtc(),
      );
}

const _uuidPattern =
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$';

String _requiredUuid(Object? value, String field) {
  if (value is! String || !RegExp(_uuidPattern).hasMatch(value)) {
    throw FormatException('Invalid $field in server notification response.');
  }
  return value;
}

String? _optionalUuid(Object? value, String field) =>
    value == null ? null : _requiredUuid(value, field);

String _notificationType(Object? value) {
  if (value is String &&
      const {
        'group_invitation',
        'group_event_created',
        'group_event_updated',
        'group_comment',
      }.contains(value)) {
    return value;
  }
  throw const FormatException('Unknown server notification type.');
}

extension<T> on T {
  R? let<R>(R Function(T value) action) => this == null ? null : action(this);
}
