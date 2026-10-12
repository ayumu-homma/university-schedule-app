import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_schedule_mobile/core/config/app_config.dart';
import 'package:university_schedule_mobile/core/config/app_config_provider.dart';
import 'package:university_schedule_mobile/features/auth/application/auth_providers.dart';
import 'package:university_schedule_mobile/features/auth/data/fake_auth_repository.dart';
import 'package:university_schedule_mobile/features/auth/presentation/sign_in_screen.dart';

void main() {
  testWidgets('OAuth disclosure explains app use before provider actions', (
    tester,
  ) async {
    final repository = FakeAuthRepository(autoAuthenticateEmail: false);
    addTearDown(repository.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appConfigProvider.overrideWithValue(AppConfig.demoForTesting()),
          authRepositoryProvider.overrideWithValue(repository),
        ],
        child: const MaterialApp(home: SignInScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final disclosure = find.byKey(const Key('sign-in-oauth-disclosure'));
    final googleButton = find.byKey(const Key('sign-in-google-button'));
    final appleButton = find.byKey(const Key('sign-in-apple-button'));

    expect(disclosure, findsOneWidget);
    expect(
      find.text(
        'Google または Apple の認証画面を開き、認証後にこのアプリへ戻ります。'
        'アプリはSupabase Authから受け取るユーザーIDでアカウントを識別し、'
        'メールアドレスがある場合は設定画面のアカウント表示にも使用します。',
      ),
      findsOneWidget,
    );
    expect(googleButton, findsOneWidget);
    expect(appleButton, findsOneWidget);
    expect(tester.getTopLeft(disclosure).dy,
        lessThan(tester.getTopLeft(googleButton).dy));
    expect(tester.getTopLeft(disclosure).dy,
        lessThan(tester.getTopLeft(appleButton).dy));
    expect(repository.lastOAuthProvider, isNull);
  });
}
