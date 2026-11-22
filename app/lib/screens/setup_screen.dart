import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../state/app_state.dart';
import '../theme.dart';

/// Primera configuración: dirección del servidor y token.
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  // En el dashboard web la app la sirve el mismo servidor: usar esa dirección
  late final _url = TextEditingController(
    text: context.read<AppState>().store.serverUrl.isNotEmpty
        ? context.read<AppState>().store.serverUrl
        : (kIsWeb ? Uri.base.origin : ''),
  );
  late final _token = TextEditingController(text: context.read<AppState>().store.token);
  bool _busy = false;
  bool _showToken = false;
  String? _error;

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<AppState>().configure(_url.text, _token.text.trim());
      if (mounted && Navigator.canPop(context)) Navigator.pop(context);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'No se pudo conectar: revisá la dirección');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      appBar: Navigator.canPop(context) ? AppBar(title: const Text('Servidor')) : null,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: ListView(
              padding: const EdgeInsets.all(24),
              shrinkWrap: true,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    width: 72,
                    height: 72,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(colors: [AppColors.accent, Color(0xFF1B8F5C)]),
                      borderRadius: BorderRadius.circular(22),
                    ),
                    child: const Icon(Icons.print_rounded, color: Colors.white, size: 38),
                  ),
                ),
                const SizedBox(height: 24),
                Text('Conectá tu servidor', style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                Text(
                  'OpenBambu se conecta a tu servidor (Docker en una PC, NAS o Raspberry Pi), '
                  'que es el que habla con la impresora por la red local.',
                  style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 28),
                TextField(
                  controller: _url,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Dirección del servidor',
                    hintText: '192.168.1.10:8787',
                    prefixIcon: Icon(Icons.dns_rounded),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _token,
                  obscureText: !_showToken,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: 'Token de acceso',
                    helperText: 'Aparece en los logs: docker logs openbambu',
                    prefixIcon: const Icon(Icons.key_rounded),
                    suffixIcon: IconButton(
                      icon: Icon(_showToken ? Icons.visibility_off_rounded : Icons.visibility_rounded),
                      onPressed: () => setState(() => _showToken = !_showToken),
                    ),
                  ),
                  onSubmitted: (_) => _submit(),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.danger.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.error_outline_rounded, color: AppColors.danger),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(_error!, style: const TextStyle(color: AppColors.danger)),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _busy ? null : _submit,
                  child: _busy
                      ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                      : const Text('Conectar'),
                ),
                const SizedBox(height: 20),
                Text(
                  'Fuera de casa: usá una VPN como Tailscale o WireGuard y poné la IP del servidor en esa red.',
                  textAlign: TextAlign.center,
                  style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
