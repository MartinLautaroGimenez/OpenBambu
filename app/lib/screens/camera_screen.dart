import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../widgets/camera_view.dart';
import '../widgets/common.dart';

/// Cámara a pantalla completa con zoom y controles rápidos.
class CameraScreen extends StatefulWidget {
  final String printerId;
  const CameraScreen({super.key, required this.printerId});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppState>().printers[widget.printerId];
    final s = p?.status;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              maxScale: 5,
              child: CameraView(printerId: widget.printerId, fit: BoxFit.contain),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  IconButton(
                    style: IconButton.styleFrom(backgroundColor: Colors.black45),
                    icon: const Icon(Icons.close_rounded, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                  ),
                  const SizedBox(width: 8),
                  if (s != null && s.isActive)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
                      child: Text(
                        '${s.job.progress}% · capa ${s.job.layer}/${s.job.totalLayers} · ${formatDuration(s.job.remainingMin)}',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                      ),
                    ),
                  const Spacer(),
                  if (s != null)
                    IconButton(
                      style: IconButton.styleFrom(backgroundColor: Colors.black45),
                      icon: Icon(
                        s.light ? Icons.lightbulb_rounded : Icons.lightbulb_outline_rounded,
                        color: s.light ? const Color(0xFFFFD54F) : Colors.white,
                      ),
                      onPressed: () => act(context, (api, id) => api.light(id, !s.light)),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
