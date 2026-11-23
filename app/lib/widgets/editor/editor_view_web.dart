import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:material_ui/material_ui.dart';
import 'package:web/web.dart' as web;

/// Editor en un iframe (dashboard web). Los mensajes llegan con `window.postMessage`.
class EditorView extends StatefulWidget {
  final Uri url;
  final ValueChanged<String> onMessage;
  const EditorView({super.key, required this.url, required this.onMessage});

  @override
  State<EditorView> createState() => _EditorViewState();
}

class _EditorViewState extends State<EditorView> {
  static int _seq = 0;
  late final String _viewType = 'openbambu-editor-${_seq++}';
  StreamSubscription<web.MessageEvent>? _sub;

  @override
  void initState() {
    super.initState();
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int id) {
      final frame = web.HTMLIFrameElement()
        ..src = widget.url.toString()
        ..style.border = '0'
        ..style.width = '100%'
        ..style.height = '100%'
        ..allow = 'fullscreen';
      return frame;
    });
    _sub = web.window.onMessage.listen((e) {
      final data = e.data.dartify();
      if (data is Map && data['source'] == 'openbambu-editor') {
        widget.onMessage(jsonEncode(data));
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => HtmlElementView(viewType: _viewType);
}
