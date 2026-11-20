import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../state/app_state.dart';
import '../theme.dart';

/// Ejecuta una acción y muestra un aviso si falla.
Future<bool> act(BuildContext context, Future<void> Function(ApiClient api, String id) fn, {String? success}) async {
  final messenger = ScaffoldMessenger.of(context);
  final err = await context.read<AppState>().run(fn);
  if (err != null) {
    messenger.showSnackBar(SnackBar(content: Text(err), backgroundColor: AppColors.danger, showCloseIcon: true));
    return false;
  }
  if (success != null) {
    messenger.showSnackBar(SnackBar(content: Text(success), duration: const Duration(seconds: 2)));
  }
  return true;
}

Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String message,
  String ok = 'Confirmar',
  bool danger = false,
}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
        FilledButton(
          style: danger
              ? FilledButton.styleFrom(backgroundColor: AppColors.danger, minimumSize: const Size(0, 44))
              : FilledButton.styleFrom(minimumSize: const Size(0, 44)),
          onPressed: () => Navigator.pop(c, true),
          child: Text(ok),
        ),
      ],
    ),
  );
  return r == true;
}

class SectionTitle extends StatelessWidget {
  final String text;
  final Widget? trailing;
  const SectionTitle(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 20, 4, 10),
    child: Row(
      children: [
        Expanded(
          child: Text(
            text.toUpperCase(),
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              letterSpacing: 1.2,
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        ?trailing,
      ],
    ),
  );
}

class StateChip extends StatelessWidget {
  final String state;
  final String label;
  const StateChip({super.key, required this.state, required this.label});

  @override
  Widget build(BuildContext context) {
    final c = stateColor(state);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(99)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: c, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(color: c, fontWeight: FontWeight.w700, fontSize: 12.5),
          ),
        ],
      ),
    );
  }
}

/// Valor con etiqueta, para las estadísticas del trabajo.
class Stat extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const Stat({super.key, required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: t.colorScheme.onSurfaceVariant),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(value, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

/// Banner cuando no hay conexión con el servidor o la impresora.
class ConnectionBanner extends StatelessWidget {
  const ConnectionBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final printer = s.selected;
    String? text;
    if (s.conn == ConnState.connecting && printer == null) return const SizedBox.shrink();
    if (s.conn != ConnState.connected) {
      text = s.conn == ConnState.connecting ? 'Conectando con el servidor…' : (s.connError ?? 'Sin conexión');
    } else if (printer != null && printer.status.isOffline) {
      text = 'El servidor no puede comunicarse con ${printer.name}';
    }
    if (text == null) return const SizedBox.shrink();
    return Material(
      color: AppColors.warning.withValues(alpha: 0.15),
      child: InkWell(
        onTap: s.conn == ConnState.disconnected ? s.retryNow : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              const Icon(Icons.cloud_off_rounded, size: 18, color: AppColors.warning),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  text,
                  style: const TextStyle(color: AppColors.warning, fontWeight: FontWeight.w600),
                ),
              ),
              if (s.conn == ConnState.disconnected)
                const Text(
                  'Reintentar',
                  style: TextStyle(color: AppColors.warning, fontWeight: FontWeight.w800),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

String formatDuration(int minutes) {
  if (minutes <= 0) return '—';
  final h = minutes ~/ 60, m = minutes % 60;
  return h > 0 ? '$h h ${m.toString().padLeft(2, '0')} m' : '$m min';
}

String formatClock(DateTime t) {
  final now = DateTime.now();
  final hm = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  if (t.day == now.day && t.month == now.month) return hm;
  if (t.difference(DateTime(now.year, now.month, now.day)).inDays == 1) return 'mañana $hm';
  return '${t.day}/${t.month} $hm';
}
