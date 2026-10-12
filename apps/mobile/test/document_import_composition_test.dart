import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/core/config/app_config.dart';
import 'package:university_schedule_mobile/core/config/app_config_provider.dart';
import 'package:university_schedule_mobile/features/document_import/application/document_import_controller.dart';
import 'package:university_schedule_mobile/features/document_import/data/document_import_gateway.dart';
import 'package:university_schedule_mobile/features/document_import/domain/document_import_models.dart';

void main() {
  group('document import composition', () {
    test(
      'disabled feature fails closed without reading the Supabase client',
      () async {
        final container = ProviderContainer(
          overrides: [
            appConfigProvider.overrideWithValue(
              AppConfig.validated(
                environment: 'local',
                demoMode: false,
                supabaseUrl: 'http://127.0.0.1:54321',
                supabasePublishableKey: 'local-public-client-key',
                documentImportEnabled: false,
              ),
            ),
            supabaseClientProvider.overrideWith(
              (ref) => throw StateError(
                'A disabled feature must not compose a Supabase gateway.',
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        expect(container.read(documentImportAvailableProvider), isFalse);
        final gateway = container.read(documentImportGatewayProvider);

        await expectLater(
          gateway.analyze(_fixtureFile()),
          throwsA(
            isA<DocumentImportFailure>().having(
              (error) => error.category,
              'category',
              DocumentImportErrorCategory.configurationMissing,
            ),
          ),
        );
      },
    );

    test('demo mode alone composes the deterministic fake gateway', () async {
      final container = ProviderContainer(
        overrides: [
          appConfigProvider.overrideWithValue(AppConfig.demoForTesting()),
          documentImportOwnerIdProvider.overrideWithValue('owner-a'),
          supabaseClientProvider.overrideWith(
            (ref) => throw StateError(
              'Demo composition must not read the Supabase client.',
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(documentImportAvailableProvider), isTrue);
      final gateway = container.read(documentImportGatewayProvider);
      expect(gateway, isA<FakeDocumentImportGateway>());

      final first = await gateway.analyze(_fixtureFile());
      final replay = await gateway.analyze(_fixtureFile());

      expect(first.batch.sourceId, replay.batch.sourceId);
      expect(
        first.batch.candidates.map((candidate) => candidate.candidateId),
        orderedEquals(
          replay.batch.candidates.map((candidate) => candidate.candidateId),
        ),
      );
      expect(first.batch.candidates, hasLength(3));
    });

    test('staging and release configurations reject demo composition', () {
      expect(
        () => AppConfig.validated(
          environment: 'staging',
          demoMode: true,
          webBaseUrl: 'https://staging.example.edu',
        ),
        throwsA(isA<AppConfigException>()),
      );
      expect(
        () => AppConfig.validated(
          environment: 'local',
          demoMode: true,
          isReleaseMode: true,
        ),
        throwsA(isA<AppConfigException>()),
      );
    });
  });
}

DocumentSelectedFile _fixtureFile() {
  final bytes = Uint8List.fromList(utf8.encode('deterministic demo fixture'));
  return DocumentSelectedFile.validate(
    extension: 'txt',
    declaredSize: bytes.length,
    bytes: bytes,
  );
}
