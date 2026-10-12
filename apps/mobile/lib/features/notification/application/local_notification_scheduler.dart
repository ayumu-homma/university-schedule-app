class NotificationRequest {
  const NotificationRequest({
    required this.id,
    required this.title,
    required this.body,
    required this.scheduledAt,
    this.deepLink,
  });

  final String id;
  final String title;
  final String body;
  final DateTime scheduledAt;
  final String? deepLink;
}

abstract interface class LocalNotificationScheduler {
  Future<void> schedule(NotificationRequest request);

  Future<void> cancel(String id);
}
