import 'package:material_ui/material_ui.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Editor dentro de un WebView. Los mensajes llegan por el canal JavaScript `OpenBambu`.
class EditorView extends StatefulWidget {
  final Uri url;
  final ValueChanged<String> onMessage;
  const EditorView({super.key, required this.url, required this.onMessage});

  @override
  State<EditorView> createState() => _EditorViewState();
}

class _EditorViewState extends State<EditorView> {
  late final WebViewController _ctrl = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..setBackgroundColor(const Color(0xFF101214))
    ..addJavaScriptChannel('OpenBambu', onMessageReceived: (m) => widget.onMessage(m.message))
    ..loadRequest(widget.url);

  @override
  Widget build(BuildContext context) => WebViewWidget(controller: _ctrl);
}
