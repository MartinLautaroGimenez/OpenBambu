import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../services/background.dart';
import '../services/notifications.dart';
import '../state/app_state.dart';
import '../widgets/common.dart';
import 'setup_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Ajustes')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          const SectionTitle('Servidor'),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: Icon(
                    Icons.dns_rounded,
                    color: s.conn == ConnState.connected ? const Color(0xFF2EC27E) : t.colorScheme.outline,
                  ),
                  title: Text(s.store.serverUrl, style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text(switch (s.conn) {
                    ConnState.connected => 'Conectado · ${s.printers.length} impresora(s)',
                    ConnState.connecting => 'Conectando…',
                    ConnState.disconnected => s.connError ?? 'Desconectado',
                  }),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SetupScreen())),
                ),
              ],
            ),
          ),
          const SectionTitle('Notificaciones'),
          Card(
            child: Column(
              children: [
                if (BackgroundMonitor.supported)
                  SwitchListTile(
                    secondary: const Icon(Icons.notifications_active_rounded),
                    title: const Text('Monitoreo en segundo plano'),
                    subtitle: const Text('Barra de progreso y alertas aunque la app esté cerrada'),
                    value: s.store.backgroundMonitor,
                    onChanged: (v) => s.setBackgroundMonitor(v),
                  )
                else
                  const ListTile(
                    leading: Icon(Icons.info_outline_rounded),
                    title: Text('Alertas con la app cerrada'),
                    subtitle: Text(
                      'En iOS configurá ntfy en el servidor para recibir avisos push. '
                      'Las Live Activities llegan en una próxima versión.',
                    ),
                  ),
                ListTile(
                  leading: const Icon(Icons.verified_user_outlined),
                  title: const Text('Permitir notificaciones'),
                  onTap: () async {
                    final ok = await Notifications.requestPermission();
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(ok ? 'Notificaciones habilitadas' : 'Permiso no concedido')),
                      );
                    }
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.send_rounded),
                  title: const Text('Enviar notificación de prueba'),
                  subtitle: const Text('También llega por ntfy si está configurado'),
                  onTap: () => s.api?.testNotification(),
                ),
              ],
            ),
          ),
          const SectionTitle('Cuenta'),
          Card(
            child: ListTile(
              leading: const Icon(Icons.logout_rounded, color: Color(0xFFF0564A)),
              title: const Text('Desconectar servidor', style: TextStyle(color: Color(0xFFF0564A))),
              onTap: () async {
                if (await confirm(
                  context,
                  title: '¿Desconectar?',
                  message: 'Vas a tener que ingresar el servidor y token de nuevo.',
                  ok: 'Desconectar',
                  danger: true,
                )) {
                  await s.logout();
                  if (context.mounted) Navigator.popUntil(context, (r) => r.isFirst);
                }
              },
            ),
          ),
          const SizedBox(height: 24),
          Center(
            child: Text(
              'OpenBambu 0.1.0 · software libre, no afiliado a Bambu Lab',
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}
