import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../state/app_state.dart';
import '../theme.dart';

/// Diálogo para vincular la cuenta Bambu Lab / MakerWorld (para poder descargar).
/// Devuelve true si quedó vinculada.
Future<bool> showMakerWorldLogin(BuildContext context) async {
  final r = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _LoginSheet(),
  );
  return r == true;
}

class _LoginSheet extends StatefulWidget {
  const _LoginSheet();

  @override
  State<_LoginSheet> createState() => _LoginSheetState();
}

class _LoginSheetState extends State<_LoginSheet> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();
  final _token = TextEditingController();
  bool _needsCode = false;
  bool _useToken = false;
  bool _busy = false;
  String? _error;

  Future<void> _submit() async {
    final api = context.read<AppState>().api;
    if (api == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final needsCode = await api.makerWorldLogin(
        email: _email.text.trim(),
        password: _password.text,
        code: _needsCode ? _code.text.trim() : '',
        token: _useToken ? _token.text.trim() : '',
      );
      if (!mounted) return;
      if (needsCode) {
        setState(() => _needsCode = true);
      } else {
        Navigator.pop(context, true);
      }
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(24, 0, 24, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Vincular MakerWorld', style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(
            'MakerWorld pide una cuenta para descargar. Usá tu cuenta de Bambu Lab: '
            'el servidor guarda solo el token de sesión, no tu contraseña.',
            style: TextStyle(color: t.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          if (_useToken)
            TextField(
              controller: _token,
              decoration: const InputDecoration(labelText: 'Token de MakerWorld', prefixIcon: Icon(Icons.key_rounded)),
            )
          else if (!_needsCode) ...[
            TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'Email', prefixIcon: Icon(Icons.mail_rounded)),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _password,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Contraseña', prefixIcon: Icon(Icons.lock_rounded)),
              onSubmitted: (_) => _submit(),
            ),
          ] else
            TextField(
              controller: _code,
              keyboardType: TextInputType.number,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Código que te llegó a ${_email.text}',
                prefixIcon: const Icon(Icons.pin_rounded),
              ),
              onSubmitted: (_) => _submit(),
            ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: const TextStyle(color: AppColors.danger)),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(_needsCode ? 'Confirmar código' : 'Vincular'),
          ),
          TextButton(
            onPressed: () => setState(() {
              _useToken = !_useToken;
              _needsCode = false;
              _error = null;
            }),
            child: Text(_useToken ? 'Usar email y contraseña' : 'Prefiero pegar el token'),
          ),
        ],
      ),
    );
  }
}
