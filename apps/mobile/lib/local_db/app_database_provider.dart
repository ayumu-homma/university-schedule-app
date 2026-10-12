import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_database.dart';

final appDatabaseProvider = Provider<AppDatabase>((ref) {
  throw StateError(
    'AppDatabase must be prepared and injected by application bootstrap.',
  );
});

final appDatabasePathProvider = Provider<String>((ref) {
  throw StateError(
    'AppDatabase path must be prepared and injected by application bootstrap.',
  );
});
