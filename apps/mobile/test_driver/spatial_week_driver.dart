import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() async {
  final destination = Platform.environment['SPATIAL_REPORT_PATH'];
  if (destination == null || destination.isEmpty) {
    throw StateError('Set SPATIAL_REPORT_PATH to a local test report file.');
  }
  await integrationDriver(
    timeout: const Duration(minutes: 10),
    writeResponseOnFailure: true,
    responseDataCallback: (data) async {
      await File(destination).writeAsString(
        const JsonEncoder.withIndent('  ').convert(data),
      );
    },
  );
}
