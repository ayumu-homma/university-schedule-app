import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:go_router/go_router.dart';

import '../core/config/app_config.dart';

class NormalizedDeepLink {
  const NormalizedDeepLink.location(this.location) : isAuthCallback = false;

  const NormalizedDeepLink.authCallback()
      : location = null,
        isAuthCallback = true;

  final String? location;
  final bool isAuthCallback;
}

class EmailAuthorizationCallbackParameters {
  const EmailAuthorizationCallbackParameters({
    required this.requestedConnectionId,
    required this.correlationId,
  });

  final String requestedConnectionId;
  final String correlationId;

  static EmailAuthorizationCallbackParameters? fromInternalUri(Uri uri) {
    if (uri.path != '/settings/email-import' || uri.fragment.isNotEmpty) {
      return null;
    }
    final query = uri.queryParametersAll;
    if (query.keys.toSet().difference(_internalKeys).isNotEmpty ||
        _internalKeys.difference(query.keys.toSet()).isNotEmpty ||
        query.values.any((values) => values.length != 1)) {
      return null;
    }
    final requestedConnectionId = query['oauth_connection_id']!.single;
    final correlationId = query['oauth_correlation_id']!.single;
    if (!_uuidPattern.hasMatch(requestedConnectionId) ||
        !_uuidPattern.hasMatch(correlationId)) {
      return null;
    }
    return EmailAuthorizationCallbackParameters(
      requestedConnectionId: requestedConnectionId,
      correlationId: correlationId,
    );
  }

  static const _internalKeys = {
    'oauth_connection_id',
    'oauth_correlation_id',
  };

  static final _uuidPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    caseSensitive: false,
  );
}

class DeepLinkNormalizer {
  const DeepLinkNormalizer(this.config);

  final AppConfig config;

  NormalizedDeepLink? normalize(Uri uri) {
    final isAppScheme =
        uri.scheme.toLowerCase() == config.deepLinkScheme.toLowerCase();
    if (isAppScheme && uri.host.toLowerCase() == 'email-import-callback') {
      return _normalizeEmailImportCallback(uri);
    }
    if (isAppScheme && uri.host.toLowerCase() == 'auth-callback') {
      return const NormalizedDeepLink.authCallback();
    }
    if (isAppScheme && uri.host.toLowerCase() == 'today') {
      return _normalizeToday(uri);
    }
    if (isAppScheme && uri.hasQuery) {
      final notification = _normalizeOrdinaryNotification(uri);
      if (notification != null) return notification;
    }
    if (uri.fragment.isNotEmpty || uri.hasQuery) return null;
    if (isAppScheme) {
      return _normalizeCustomScheme(uri);
    }
    if (uri.scheme == 'https' || uri.scheme == 'http') {
      return _normalizeWebLink(uri);
    }
    return null;
  }

  NormalizedDeepLink? _normalizeToday(Uri uri) {
    if (uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.hasFragment ||
        uri.path.isNotEmpty) {
      return null;
    }
    if (!uri.hasQuery) {
      return const NormalizedDeepLink.location('/today');
    }
    if (uri.query != 'source=morning-alarm') return null;
    final query = uri.queryParametersAll;
    if (query.length != 1 ||
        query['source']?.length != 1 ||
        query['source']?.single != 'morning-alarm') {
      return null;
    }
    return const NormalizedDeepLink.location(
      '/today?source=morning-alarm',
    );
  }

  NormalizedDeepLink? _normalizeEmailImportCallback(Uri uri) {
    if (uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.fragment.isNotEmpty ||
        uri.pathSegments.isNotEmpty) {
      return null;
    }
    final query = uri.queryParametersAll;
    if (query.values.any((values) => values.length != 1)) return null;
    final outcome = query['email_import']?.single;
    final correlationId = query['correlation_id']?.single;
    final requestedConnectionId = query['connection_id']?.single;
    if ((outcome != 'connected' && outcome != 'failed') ||
        correlationId == null ||
        !_uuid.hasMatch(correlationId) ||
        requestedConnectionId == null ||
        !_uuid.hasMatch(requestedConnectionId)) {
      return null;
    }
    if (outcome == 'connected') {
      if (query.keys.toSet().difference(const {
        'email_import',
        'correlation_id',
        'connection_id',
      }).isNotEmpty) {
        return null;
      }
    } else {
      if (query.keys.toSet().difference(const {
            'email_import',
            'correlation_id',
            'connection_id',
            'category',
          }).isNotEmpty ||
          !_safeEmailCallbackCategories.contains(query['category']?.single)) {
        return null;
      }
    }
    // Only opaque UUIDs survive normalization. The settings screen consumes
    // them once at the authenticated check boundary and removes the query.
    return NormalizedDeepLink.location(
      Uri(
        path: '/settings/email-import',
        queryParameters: {
          'oauth_connection_id': requestedConnectionId,
          'oauth_correlation_id': correlationId,
        },
      ).toString(),
    );
  }

  bool isSafeInternalLocation(String location) {
    final uri = Uri.tryParse(location);
    if (uri == null ||
        uri.isAbsolute ||
        uri.hasAuthority ||
        uri.hasFragment ||
        !uri.path.startsWith('/')) {
      return false;
    }
    final segments = uri.pathSegments;
    if (!_hasSafeInternalQuery(uri)) return false;
    if (segments.isEmpty) return uri.path == '/';
    return switch (segments.first) {
      'today' => uri.path == '/today',
      'timetable' || 'calendar' => segments.length == 1,
      'shared' => segments.length == 1 ||
          (segments.length == 2 && segments[1] == 'scan') ||
          (segments.length == 3 &&
              segments[1] == 'invite' &&
              segments[2] == 'qr'),
      'availability' ||
      'visibility' ||
      'notifications' ||
      'widgets' ||
      'university' =>
        segments.length == 1,
      'settings' => segments.length == 1 ||
          (segments.length == 2 && segments.last == 'email-import'),
      'assignments' || 'exams' => segments.length == 1 ||
          (segments.length == 2 && segments.last == 'new'),
      'course' => (segments.length == 2 ||
              (segments.length == 3 && segments.last == 'edit')) &&
          _isSafeSegment(segments[1]),
      'assignment' => (segments.length == 2 && _isSafeSegment(segments[1])) ||
          (segments.length == 3 &&
              segments.last == 'edit' &&
              _isSafeSegment(segments[1])),
      'exam' ||
      'event' ||
      'routine' =>
        (segments.length == 2 && _isSafeSegment(segments[1])) ||
            (segments.length == 3 &&
                segments.last == 'edit' &&
                _isSafeSegment(segments[1])),
      'group' => segments.length == 2 && _isSafeSegment(segments[1]),
      'courses' => segments.length == 2 &&
          (segments.last == 'search' || segments.last == 'manual'),
      'events' => segments.length == 2 && segments.last == 'new',
      'invite' => segments.length == 3 &&
          (segments[1] == 'group' || segments[1] == 'friend') &&
          _isSafeSegment(segments[2]),
      _ => false,
    };
  }

  NormalizedDeepLink? _normalizeCustomScheme(Uri uri) {
    final host = uri.host.toLowerCase();
    final segments = uri.pathSegments;
    if (!segments.every(_isSafeSegment)) return null;
    String? location;
    switch (host) {
      case 'home':
        if (segments.isEmpty) location = '/';
      case 'timetable':
        if (segments.isEmpty) location = '/timetable';
      case 'course':
        if (segments.length == 1) location = '/course/${segments.single}';
      case 'course-new':
        if (segments.length == 2) {
          final weekday = int.tryParse(segments[0]);
          final period = int.tryParse(segments[1]);
          if (weekday != null &&
              weekday >= DateTime.monday &&
              weekday <= DateTime.friday &&
              period != null &&
              period >= 1 &&
              period <= 5) {
            location = Uri(
              path: '/courses/manual',
              queryParameters: {
                'weekday': '$weekday',
                'period': '$period',
              },
            ).toString();
          }
        }
      case 'assignment':
        if (segments.length == 1) {
          location = '/assignment/${segments.single}/edit';
        }
      case 'exam':
        if (segments.length == 1) {
          location = '/exam/${segments.single}/edit';
        }
      case 'event':
        if (segments.length == 1) {
          location = '/event/${segments.single}/edit';
        }
      case 'routine':
        if (segments.length == 1) {
          location = '/routine/${segments.single}/edit';
        }
      case 'group':
        if (segments.length == 1) location = '/group/${segments.single}';
      case 'invite':
        if (segments.length == 2 &&
            (segments.first == 'group' || segments.first == 'friend')) {
          location = '/invite/${segments.first}/${segments.last}';
        }
      case 'settings':
        if (segments.length == 1 && segments.single == 'visibility') {
          location = '/visibility';
        }
    }
    return location == null ? null : NormalizedDeepLink.location(location);
  }

  /// The native notification tap carries a validated target plus opaque
  /// plan/fingerprint markers.  Strip those markers before routing so they
  /// cannot become router query parameters, while retaining enough shape to
  /// reject hand-crafted ordinary-notification links at this boundary.
  NormalizedDeepLink? _normalizeOrdinaryNotification(Uri uri) {
    if (uri.userInfo.isNotEmpty || uri.hasPort || uri.fragment.isNotEmpty) {
      return null;
    }
    final host = uri.host.toLowerCase();
    const hosts = {'course', 'assignment', 'exam', 'event', 'routine'};
    if (!hosts.contains(host) || uri.pathSegments.length != 1) return null;
    final id = uri.pathSegments.single;
    if (!_isSafeSegment(id)) return null;
    final query = uri.queryParametersAll;
    if (!query.keys.toSet().containsAll(const {
          'notification',
          'plan',
          'fingerprint',
        }) ||
        query.keys.length != 3 ||
        query.values.any((values) => values.length != 1)) {
      return null;
    }
    final plan = query['plan']!.single;
    final fingerprint = query['fingerprint']!.single;
    final identity = query['notification']!.single;
    if (!_planIdPattern.hasMatch(plan) ||
        !_fingerprintPattern.hasMatch(fingerprint) ||
        identity.length > 1024 ||
        !identity.startsWith('v1|') ||
        !identity.contains('|id=$plan|') ||
        !identity.contains('|k=${host == 'course' ? 'course' : host}|')) {
      return null;
    }
    final location = switch (host) {
      'course' => '/course/$id',
      'assignment' => '/assignment/$id',
      'exam' => '/exam/$id',
      'event' => '/event/$id',
      _ => '/routine/$id',
    };
    return NormalizedDeepLink.location(location);
  }

  NormalizedDeepLink? _normalizeWebLink(Uri uri) {
    final base = config.webBaseUrl;
    if (uri.scheme != base.scheme ||
        uri.host.toLowerCase() != base.host.toLowerCase() ||
        uri.port != base.port) {
      return null;
    }
    final baseSegments = base.pathSegments.where((value) => value.isNotEmpty);
    final incoming = uri.pathSegments;
    final prefix = baseSegments.toList();
    if (incoming.length < prefix.length) return null;
    for (var index = 0; index < prefix.length; index++) {
      if (incoming[index] != prefix[index]) return null;
    }
    final relative = incoming.skip(prefix.length).toList();
    if (relative.length != 3 ||
        relative.first != 'invite' ||
        (relative[1] != 'group' && relative[1] != 'friend') ||
        !_isSafeSegment(relative[2])) {
      return null;
    }
    return NormalizedDeepLink.location('/invite/${relative[1]}/${relative[2]}');
  }

  static bool _isSafeSegment(String value) {
    return value.isNotEmpty &&
        value.length <= 256 &&
        RegExp(r'^[A-Za-z0-9._~-]+$').hasMatch(value);
  }

  static final _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    caseSensitive: false,
  );

  static final _planIdPattern = RegExp(r'^local-[0-9a-f]{64}$');
  static final _fingerprintPattern = RegExp(r'^[0-9a-f]{64}$');

  static const _safeEmailCallbackCategories = {
    'authorization_revoked',
    'cursor_expired',
    'rate_limited',
    'timeout',
    'network_unavailable',
    'provider_unavailable',
    'configuration_missing',
    'malformed_content',
    'oversized_content',
    'unsafe_content',
    'invalid_extraction',
    'unsupported_schema',
    'unsafe_url',
    'validation_failed',
    'internal_error',
  };

  static bool _hasSafeInternalQuery(Uri uri) {
    if (uri.path == '/today') {
      if (!uri.hasQuery) return true;
      if (uri.query != 'source=morning-alarm') return false;
      final query = uri.queryParametersAll;
      return query.length == 1 &&
          query['source']?.length == 1 &&
          query['source']?.single == 'morning-alarm';
    }
    if (!uri.hasQuery) return true;
    if (uri.path == '/settings/email-import') {
      return EmailAuthorizationCallbackParameters.fromInternalUri(uri) != null;
    }
    if (uri.path != '/courses/search' && uri.path != '/courses/manual') {
      return false;
    }
    for (final entry in uri.queryParametersAll.entries) {
      if ((entry.key != 'weekday' && entry.key != 'period') ||
          entry.value.length != 1) {
        return false;
      }
      final parsed = int.tryParse(entry.value.single);
      if (parsed == null) return false;
      if (entry.key == 'weekday' && (parsed < 1 || parsed > 7)) return false;
      if (entry.key == 'period' && (parsed < 1 || parsed > 9)) return false;
    }
    return uri.queryParametersAll.isNotEmpty;
  }
}

class DeepLinkController {
  DeepLinkController({
    required GoRouter router,
    required DeepLinkNormalizer normalizer,
    AppLinks? appLinks,
    void Function(String location)? onIncomingLocation,
  }) : this._(router, normalizer, appLinks ?? AppLinks(), onIncomingLocation);

  DeepLinkController._(
    this._router,
    this._normalizer,
    this._appLinks,
    this._onIncomingLocation,
  );

  final GoRouter _router;
  final DeepLinkNormalizer _normalizer;
  final AppLinks _appLinks;
  final void Function(String location)? _onIncomingLocation;
  StreamSubscription<Uri>? _subscription;

  void start() {
    if (_subscription != null) return;
    _subscription = _appLinks.uriLinkStream.listen(
      handleUri,
      onError: (_, __) {
        // Authentication and navigation errors are intentionally not logged
        // with their URI because callbacks can contain sensitive parameters.
      },
    );
    unawaited(_handleInitialLink());
  }

  Future<void> _handleInitialLink() async {
    try {
      final uri = await _appLinks.getInitialLink();
      if (_subscription != null && uri != null) handleUri(uri);
    } on Object {
      // Initial callback URIs can contain sensitive authentication parameters,
      // so failures are deliberately ignored without logging the URI.
    }
  }

  void handleUri(Uri uri) {
    final target = _normalizer.normalize(uri);
    if (target == null || target.isAuthCallback) return;
    final location = target.location;
    if (location != null) {
      _onIncomingLocation?.call(location);
      _router.go(location);
    }
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
  }
}
