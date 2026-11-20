import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';

/// Vista en vivo de la cámara. Usa el stream MJPEG del servidor y, en web
/// (donde el streaming HTTP no está disponible), capturas periódicas.
class CameraView extends StatefulWidget {
  final String printerId;
  final BoxFit fit;
  const CameraView({super.key, required this.printerId, this.fit = BoxFit.cover});

  @override
  State<CameraView> createState() => _CameraViewState();
}

class _CameraViewState extends State<CameraView> {
  Uint8List? _frame;
  String? _error;
  StreamSubscription? _sub;
  Timer? _timer;
  Timer? _retry;
  DateTime _lastFrame = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(CameraView old) {
    super.didUpdateWidget(old);
    if (old.printerId != widget.printerId) {
      _stop();
      _frame = null;
      _start();
    }
  }

  void _start() {
    final api = context.read<AppState>().api;
    if (api == null) return;
    if (kIsWeb) {
      _poll();
      _timer = Timer.periodic(const Duration(milliseconds: 1200), (_) => _poll());
      return;
    }
    _sub = api
        .mjpeg(widget.printerId)
        .listen(
          (f) {
            if (!mounted) return;
            _lastFrame = DateTime.now();
            setState(() {
              _frame = f;
              _error = null;
            });
          },
          onError: (e) => _fail('$e'),
          onDone: () => _fail('Stream de cámara cerrado'),
          cancelOnError: true,
        );
  }

  Future<void> _poll() async {
    final api = context.read<AppState>().api;
    if (api == null) return;
    try {
      final f = await api.snapshot(widget.printerId);
      if (!mounted) return;
      _lastFrame = DateTime.now();
      setState(() {
        _frame = f;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _fail(String e) {
    if (!mounted) return;
    setState(() => _error = e);
    _stop();
    _retry = Timer(const Duration(seconds: 4), () {
      if (mounted) _start();
    });
  }

  void _stop() {
    _sub?.cancel();
    _timer?.cancel();
    _retry?.cancel();
    _sub = null;
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final stale = DateTime.now().difference(_lastFrame).inSeconds > 10;
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(color: const Color(0xFF07080A)),
        if (_frame != null)
          Image.memory(_frame!, fit: widget.fit, gaplessPlayback: true, filterQuality: FilterQuality.medium),
        if (_frame == null || (_error != null && stale))
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_error == null)
                  const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.5))
                else
                  const Icon(Icons.videocam_off_rounded, color: Colors.white54, size: 34),
                const SizedBox(height: 10),
                Text(
                  _error == null ? 'Conectando cámara…' : 'Cámara no disponible',
                  style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w600),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
                    child: Text(
                      _error!,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white38, fontSize: 12),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
