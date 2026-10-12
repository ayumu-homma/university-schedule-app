import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../application/notification_device_registration.dart';

class FirebaseNotificationDeviceTokenSource
    implements NotificationDeviceTokenSource {
  FirebaseNotificationDeviceTokenSource({
    TargetPlatform? platform,
    bool isWeb = kIsWeb,
    FirebaseMessaging? messaging,
    FirebaseOptions? options,
  })  : _platform = platform ?? defaultTargetPlatform,
        _isWeb = isWeb,
        _messagingOverride = messaging,
        _optionsOverride = options;

  final TargetPlatform _platform;
  final bool _isWeb;
  final FirebaseMessaging? _messagingOverride;
  final FirebaseOptions? _optionsOverride;
  FirebaseMessaging? _messaging;
  bool _initialized = false;

  bool get _supportedPlatform =>
      !_isWeb &&
      (_platform == TargetPlatform.android || _platform == TargetPlatform.iOS);

  @override
  Future<bool> initialize() async {
    if (_initialized) return true;
    if (!_supportedPlatform) return false;
    try {
      if (_messagingOverride == null && Firebase.apps.isEmpty) {
        final options = _optionsOverride ?? _optionsForBuild();
        if (options == null) return false;
        // Native Firebase configuration is optional. A missing app config is
        // treated as push-unavailable, not as an app bootstrap failure.
        await Firebase.initializeApp(options: options);
      }
      _messaging = _messagingOverride ?? FirebaseMessaging.instance;
      _initialized = true;
      return true;
    } on Object {
      _messaging = null;
      _initialized = false;
      return false;
    }
  }

  @override
  Stream<String> get tokenRefreshes =>
      _initialized ? _messaging!.onTokenRefresh : const Stream<String>.empty();

  @override
  Future<String?> currentTokenIfAuthorized() async {
    final messaging = _messaging;
    if (!_initialized || messaging == null) return null;
    try {
      final settings = await messaging.getNotificationSettings();
      if (settings.authorizationStatus != AuthorizationStatus.authorized &&
          settings.authorizationStatus != AuthorizationStatus.provisional) {
        return null;
      }
      if (_platform == TargetPlatform.iOS &&
          await messaging.getAPNSToken() == null) {
        return null;
      }
      return await messaging.getToken();
    } on Object {
      return null;
    }
  }

  @override
  Future<void> deleteToken() async {
    if (!_initialized || _messaging == null) return;
    await _messaging!.deleteToken();
  }

  FirebaseOptions? _optionsForBuild() {
    const commonApiKey = String.fromEnvironment('FCM_API_KEY');
    const commonSenderId = String.fromEnvironment('FCM_SENDER_ID');
    const commonProjectId = String.fromEnvironment('FCM_PROJECT_ID');
    final isAndroid = _platform == TargetPlatform.android;
    final apiKey = isAndroid
        ? const String.fromEnvironment('FCM_ANDROID_API_KEY',
            defaultValue: commonApiKey)
        : const String.fromEnvironment('FCM_IOS_API_KEY',
            defaultValue: commonApiKey);
    final appId = isAndroid
        ? const String.fromEnvironment('FCM_ANDROID_APP_ID')
        : const String.fromEnvironment('FCM_IOS_APP_ID');
    final senderId = isAndroid
        ? const String.fromEnvironment('FCM_ANDROID_SENDER_ID',
            defaultValue: commonSenderId)
        : const String.fromEnvironment('FCM_IOS_SENDER_ID',
            defaultValue: commonSenderId);
    final projectId = isAndroid
        ? const String.fromEnvironment('FCM_ANDROID_PROJECT_ID',
            defaultValue: commonProjectId)
        : const String.fromEnvironment('FCM_IOS_PROJECT_ID',
            defaultValue: commonProjectId);
    final iosBundleId = _platform == TargetPlatform.iOS
        ? const String.fromEnvironment('FCM_IOS_BUNDLE_ID')
        : null;
    if (apiKey.isEmpty ||
        appId.isEmpty ||
        senderId.isEmpty ||
        projectId.isEmpty ||
        (_platform == TargetPlatform.iOS && iosBundleId!.isEmpty)) {
      return null;
    }
    return FirebaseOptions(
      apiKey: apiKey,
      appId: appId,
      messagingSenderId: senderId,
      projectId: projectId,
      iosBundleId: iosBundleId,
    );
  }
}
