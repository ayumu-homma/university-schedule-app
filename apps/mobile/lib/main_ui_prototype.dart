import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'features/ui_prototype/ui_prototype_app.dart';

void main() {
  if (kReleaseMode) {
    runApp(const _UnavailablePrototype());
    return;
  }
  runApp(const ProviderScope(child: UiPrototypeApp()));
}

class _UnavailablePrototype extends StatelessWidget {
  const _UnavailablePrototype();

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: Scaffold(
        body: Center(
          child: Text('UI比較試作はリリースビルドでは利用できません。'),
        ),
      ),
    );
  }
}
