import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

typedef ExternalUriLauncher = Future<bool> Function(Uri uri);

final externalUriLauncherProvider = Provider<ExternalUriLauncher>((ref) {
  return (uri) => launchUrl(uri, mode: LaunchMode.externalApplication);
});
