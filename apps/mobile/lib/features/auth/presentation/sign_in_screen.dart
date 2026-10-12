import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/app_error.dart';
import '../application/auth_action_controller.dart';
import '../domain/auth_models.dart';

class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final action = ref.watch(authActionControllerProvider);
    final result = action.valueOrNull;
    final error = action.error;
    final isLoading = action.isLoading;

    return Scaffold(
      appBar: AppBar(title: const Text('ログイン')),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                '大学生活の予定を、ひとつのカレンダーに。',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              const Text('メールの確認リンク、または外部アカウントでログインできます。'),
              const SizedBox(height: 24),
              TextFormField(
                key: const Key('sign-in-email'),
                controller: _emailController,
                enabled: !isLoading,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                textInputAction: TextInputAction.done,
                autocorrect: false,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.mail_outline),
                  labelText: 'メールアドレス',
                  hintText: 'student@example.ac.jp',
                ),
                validator: AuthValidators.validateEmail,
                onFieldSubmitted: isLoading ? null : (_) => _sendMagicLink(),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                key: const Key('sign-in-email-button'),
                onPressed: isLoading ? null : _sendMagicLink,
                icon: isLoading
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.mail_outline),
                label: const Text('メールで続ける'),
              ),
              if (result == AuthActionResult.magicLinkSent) ...[
                const SizedBox(height: 12),
                const _StatusMessage(
                  icon: Icons.mark_email_read_outlined,
                  message: '確認リンクを送信しました。メールを確認してください。',
                ),
              ],
              if (result == AuthActionResult.oauthCancelled) ...[
                const SizedBox(height: 12),
                const _StatusMessage(
                  icon: Icons.info_outline,
                  message: 'ログイン画面を開けませんでした。もう一度お試しください。',
                ),
              ],
              if (error != null) ...[
                const SizedBox(height: 12),
                _StatusMessage(
                  icon: Icons.error_outline,
                  message: error is AppError
                      ? error.message
                      : '認証に失敗しました。もう一度お試しください。',
                  isError: true,
                ),
              ],
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Row(
                  children: [
                    Expanded(child: Divider()),
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      child: Text('または'),
                    ),
                    Expanded(child: Divider()),
                  ],
                ),
              ),
              const Text(
                'Google または Apple の認証画面を開き、認証後にこのアプリへ戻ります。'
                'アプリはSupabase Authから受け取るユーザーIDでアカウントを識別し、'
                'メールアドレスがある場合は設定画面のアカウント表示にも使用します。',
                key: Key('sign-in-oauth-disclosure'),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                key: const Key('sign-in-google-button'),
                onPressed: isLoading
                    ? null
                    : () => _signInWithOAuth(AppAuthProvider.google),
                icon: const Icon(Icons.g_mobiledata),
                label: const Text('Google で続ける'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const Key('sign-in-apple-button'),
                onPressed: isLoading
                    ? null
                    : () => _signInWithOAuth(AppAuthProvider.apple),
                icon: const Icon(Icons.apple),
                label: const Text('Apple で続ける'),
              ),
              const SizedBox(height: 20),
              const Text(
                '続行すると、利用規約とプライバシーポリシーに同意したものとみなされます。',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _sendMagicLink() {
    FocusScope.of(context).unfocus();
    if (_formKey.currentState?.validate() != true) return;
    ref
        .read(authActionControllerProvider.notifier)
        .sendMagicLink(_emailController.text);
  }

  void _signInWithOAuth(AppAuthProvider provider) {
    ref.read(authActionControllerProvider.notifier).signInWithOAuth(provider);
  }
}

class _StatusMessage extends StatelessWidget {
  const _StatusMessage({
    required this.icon,
    required this.message,
    this.isError = false,
  });

  final IconData icon;
  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final color = isError
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).colorScheme.primary;
    return Semantics(
      liveRegion: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message, style: TextStyle(color: color)),
          ),
        ],
      ),
    );
  }
}
