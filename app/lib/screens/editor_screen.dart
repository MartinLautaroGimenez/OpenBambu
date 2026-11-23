import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/editor/editor_view.dart';
import 'slice_screen.dart';

/// Editor 3D de la placa: mover, rotar, escalar, duplicar, apoyar, acomodar y placas.
class EditorScreen extends StatelessWidget {
  final String printerId;
  final LibraryItem item;
  final int plate;
  const EditorScreen({super.key, required this.printerId, required this.item, this.plate = 0});

  static bool canEdit(LibraryItem item) =>
      !item.sliced && ['3mf', 'stl', 'obj'].contains((item.format ?? '3mf').toLowerCase());

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppState>();
    final api = s.api;
    if (api == null) return const Scaffold(body: Center(child: Text('Sin conexión con el servidor')));
    final dark = Theme.of(context).brightness == Brightness.dark;
    final url = Uri.parse('${api.baseUrl}/editor/').replace(
      queryParameters: {
        'lid': item.id,
        'token': api.token,
        'printer': printerId,
        if (plate > 0) 'plate': '$plate',
        'theme': dark ? 'dark' : 'light',
      },
    );
    return Scaffold(
      backgroundColor: dark ? const Color(0xFF101214) : const Color(0xFFF7F8F7),
      body: SafeArea(
        bottom: false,
        child: EditorView(
          url: url,
          onMessage: (raw) async {
            Map<String, dynamic> msg;
            try {
              msg = jsonDecode(raw) as Map<String, dynamic>;
            } catch (_) {
              return;
            }
            if (!context.mounted) return;
            if (msg['type'] == 'close') {
              Navigator.pop(context);
            } else if (msg['type'] == 'saved' && msg['id'] is String) {
              final messenger = ScaffoldMessenger.of(context);
              try {
                final saved = await api.libraryItem(msg['id'] as String);
                if (!context.mounted) return;
                Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(
                    builder: (_) => SliceScreen(printerId: printerId, item: saved),
                  ),
                );
              } catch (e) {
                messenger.showSnackBar(SnackBar(content: Text('$e'), backgroundColor: AppColors.danger));
              }
            }
          },
        ),
      ),
    );
  }
}
