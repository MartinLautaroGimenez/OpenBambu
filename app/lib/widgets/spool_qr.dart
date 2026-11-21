import 'package:material_ui/material_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../state/app_state.dart';
import '../theme.dart';

/// Escanea el QR de una etiqueta de carrete y devuelve el carrete.
Future<Spool?> scanSpool(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  final api = context.read<AppState>().api;
  final code = await Navigator.push<String>(context, MaterialPageRoute(builder: (_) => const _ScannerScreen()));
  if (code == null || api == null) return null;
  if (parseSpoolCode(code) == null) {
    messenger.showSnackBar(
      const SnackBar(content: Text('Ese código no es una etiqueta de OpenBambu'), backgroundColor: AppColors.danger),
    );
    return null;
  }
  try {
    return await api.spoolByCode(code);
  } on ApiException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message), backgroundColor: AppColors.danger));
    return null;
  }
}

/// Escanea un carrete y lo asigna a la bandeja [tray] de la impresora.
Future<void> scanSpoolIntoTray(BuildContext context, String printerId, int tray, String trayName) async {
  final s = context.read<AppState>();
  final messenger = ScaffoldMessenger.of(context);
  final spool = await scanSpool(context);
  if (spool == null || s.api == null) return;
  try {
    await s.api!.updateSpool(spool.id, {'printer_id': printerId, 'tray': tray});
    await s.refreshSpools();
    messenger.showSnackBar(SnackBar(content: Text('${spool.label} asignado a $trayName')));
  } on ApiException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message), backgroundColor: AppColors.danger));
  }
}

/// Muestra la etiqueta para imprimir (62 mm de ancho; también sirve en papel).
void showSpoolLabel(BuildContext context, Spool spool) {
  final api = context.read<AppState>().api;
  if (api == null) return;
  final url = api.spoolLabel(spool.id);
  showDialog(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Etiqueta del carrete'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.network(url, fit: BoxFit.contain),
            ),
            const SizedBox(height: 12),
            const Text(
              'Imprimila y pegala en el carrete. Después, desde el AMS tocá una bandeja → '
              '"Escanear etiqueta" para asignarlo sin buscarlo en la lista.',
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cerrar')),
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
          onPressed: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
          icon: const Icon(Icons.print_rounded),
          label: const Text('Abrir para imprimir'),
        ),
      ],
    ),
  );
}

class _ScannerScreen extends StatefulWidget {
  const _ScannerScreen();

  @override
  State<_ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<_ScannerScreen> {
  final _ctrl = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _done = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Escanear etiqueta'),
        actions: [
          IconButton(
            tooltip: 'Linterna',
            onPressed: () => _ctrl.toggleTorch(),
            icon: const Icon(Icons.flashlight_on_rounded),
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _ctrl,
            onDetect: (capture) {
              final code = capture.barcodes.map((b) => b.rawValue).whereType<String>().firstOrNull;
              if (code == null || _done) return;
              _done = true;
              Navigator.pop(context, code);
            },
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'No se pudo abrir la cámara (${error.errorCode.name}). Revisá el permiso de cámara.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ),
          ),
          Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.accent, width: 3),
                borderRadius: BorderRadius.circular(24),
              ),
            ),
          ),
          const Positioned(
            left: 24,
            right: 24,
            bottom: 48,
            child: Text(
              'Apuntá al código QR de la etiqueta del carrete',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
