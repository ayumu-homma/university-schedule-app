import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_schedule_mobile/core/config/app_config.dart';
import 'package:university_schedule_mobile/core/config/app_config_provider.dart';
import 'package:university_schedule_mobile/features/auth/application/auth_providers.dart';
import 'package:university_schedule_mobile/features/auth/data/fake_auth_repository.dart';
import 'package:university_schedule_mobile/features/auth/domain/auth_models.dart';
import 'package:university_schedule_mobile/features/auth/presentation/sign_in_screen.dart';

void main() {
  testWidgets('sign-in screen exposes all supported authentication boundaries',
      (
    tester,
  ) async {
    final repository = FakeAuthRepository(autoAuthenticateEmail: false);
    addTearDown(repository.dispose);
    await tester.pumpWidget(_testApp(repository));
    await tester.pumpAndSettle();

    expect(find.text('ログイン'), findsOneWidget);
    expect(find.text('メールで続ける'), findsOneWidget);
    expect(find.text('Google で続ける'), findsOneWidget);
    expect(find.text('Apple で続ける'), findsOneWidget);
  });

  testWidgets('email sign-in validates input and reports magic-link delivery', (
    tester,
  ) async {
    final repository = FakeAuthRepository(autoAuthenticateEmail: false);
    addTearDown(repository.dispose);
    await tester.pumpWidget(_testApp(repository));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('sign-in-email-button')));
    await tester.pump();
    expect(find.text('メールアドレスを入力してください'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('sign-in-email')),
      'student@example.edu',
    );
    await tester.tap(find.byKey(const Key('sign-in-email-button')));
    await tester.pumpAndSettle();

    expect(
      find.text('確認リンクを送信しました。メールを確認してください。'),
      findsOneWidget,
    );
  });

  testWidgets('OAuth launch cancellation remains on the sign-in screen', (
    tester,
  ) async {
    final repository = FakeAuthRepository(autoAuthenticateOAuth: false)
      ..setOAuthResult(
        AppAuthProvider.google,
        OAuthLaunchResult.cancelled,
      );
    addTearDown(repository.dispose);
    await tester.pumpWidget(_testApp(repository));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('sign-in-google-button')));
    await tester.tap(find.byKey(const Key('sign-in-google-button')));
    await tester.pumpAndSettle();

    expect(
      find.text('ログイン画面を開けませんでした。もう一度お試しください。'),
      findsOneWidget,
    );
    expect(find.byType(SignInScreen), findsOneWidget);
  });
}

Widget _testApp(FakeAuthRepository repository) {
  return ProviderScope(
    overrides: [
      appConfigProvider.overrideWithValue(AppConfig.demoForTesting()),
      authRepositoryProvider.overrideWithValue(repository),
    ],
    child: const MaterialApp(home: SignInScreen()),
  );
}
