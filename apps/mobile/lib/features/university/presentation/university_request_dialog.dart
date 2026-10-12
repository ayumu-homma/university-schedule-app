import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/app_error.dart';
import '../application/university_settings_providers.dart';
import '../domain/university_settings_models.dart';

/// Opens the authenticated, bounded university-request flow.
///
/// The repository binds the request to the current authenticated user, so this
/// dialog can be used both before and after onboarding has completed.
Future<String?> showUniversityRequestDialog(BuildContext context) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const _UniversityRequestDialog(),
  );
}

class UniversityRequestTile extends StatelessWidget {
  const UniversityRequestTile({required this.request, super.key});

  final UniversityRequestRecord request;

  @override
  Widget build(BuildContext context) {
    final date = request.createdAt.toLocal();
    final location = request.prefecture;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.pending_actions_outlined),
      title: Text(request.name),
      subtitle: Text(
        '${date.year}/${date.month.toString().padLeft(2, '0')}/'
        '${date.day.toString().padLeft(2, '0')}'
        '${location == null ? '' : ' ・ $location'}',
      ),
      trailing: Text(request.status.label),
    );
  }
}

class _UniversityRequestDialog extends ConsumerStatefulWidget {
  const _UniversityRequestDialog();

  @override
  ConsumerState<_UniversityRequestDialog> createState() =>
      _UniversityRequestDialogState();
}

class _UniversityRequestDialogState
    extends ConsumerState<_UniversityRequestDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _prefectureController = TextEditingController();
  final _urlController = TextEditingController();
  bool _submitting = false;
  String? _submissionError;

  @override
  void dispose() {
    _nameController.dispose();
    _prefectureController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('未登録大学を申請'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                key: const Key('university-request-name'),
                controller: _nameController,
                autofocus: true,
                enabled: !_submitting,
                maxLength: 120,
                decoration: const InputDecoration(labelText: '大学名（必須）'),
                validator: (value) {
                  final length = value?.trim().length ?? 0;
                  return length < 2 ? '大学名を2文字以上で入力してください' : null;
                },
              ),
              TextFormField(
                key: const Key('university-request-prefecture'),
                controller: _prefectureController,
                enabled: !_submitting,
                maxLength: 50,
                decoration: const InputDecoration(labelText: '都道府県'),
              ),
              TextFormField(
                key: const Key('university-request-url'),
                controller: _urlController,
                enabled: !_submitting,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: '公式サイトURL',
                  hintText: 'https://…',
                ),
                validator: (value) {
                  final text = value?.trim() ?? '';
                  if (text.isEmpty) return null;
                  final uri = Uri.tryParse(text);
                  return uri != null &&
                          uri.scheme == 'https' &&
                          uri.host.isNotEmpty
                      ? null
                      : 'HTTPSの公式URLを入力してください';
                },
              ),
              if (_submissionError != null) ...[
                const SizedBox(height: 8),
                Text(
                  _submissionError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          key: const Key('submit-university-request-button'),
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('申請する'),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    if (_formKey.currentState?.validate() != true) return;
    setState(() {
      _submitting = true;
      _submissionError = null;
    });
    final input = UniversityRequestInput(
      name: _nameController.text,
      prefecture: _prefectureController.text,
      officialUrl: _urlController.text,
    ).normalized();
    try {
      final requestId = await ref
          .read(universitySettingsRepositoryProvider)
          .submitRequest(input);
      if (!mounted) return;
      Navigator.pop(context, requestId);
    } on AppError catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _submissionError = error.message;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _submissionError = '大学追加申請を送信できませんでした';
      });
    }
  }
}
