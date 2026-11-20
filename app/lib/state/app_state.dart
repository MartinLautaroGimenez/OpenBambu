import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../services/background.dart';
import '../services/notifications.dart';
import '../services/settings_store.dart';

enum ConnState { disconnected, connecting, connected }

/// Estado global: conexión con el servidor, impresoras y eventos en vivo.
class AppState extends ChangeNotifier with WidgetsBindingObserver {
  final SettingsStore store;
  ApiClient? api;

  AppState(this.store) {
    WidgetsBinding.instance.addObserver(this);
    if (store.configured) _connect();
  }

  ConnState conn = ConnState.disconnected;
  String? connError;
  final Map<String, Printer> printers = {};
  final List<PrinterEvent> events = [];
  final Map<String, QueueState> queues = {};
  List<Spool> spools = [];

  /// Se incrementa cuando cambia el historial (para recargar pantallas).
  int historyVersion = 0;
  final Map<String, bool> _queueLoading = {};
  String? selectedId;

  /// Último evento recibido en vivo (para mostrarlo como aviso en pantalla).
  final _eventCtrl = StreamController<PrinterEvent>.broadcast();
  Stream<PrinterEvent> get liveEvents => _eventCtrl.stream;

  WebSocketChannel? _ws;
  StreamSubscription? _wsSub;
  Timer? _reconnect;
  Timer? _ping;
  int _backoff = 1;
  bool _foreground = true;

  Printer? get selected => printers[selectedId] ?? (printers.isEmpty ? null : printers.values.first);

  // ---- configuración ---------------------------------------------------
  Future<void> configure(String url, String token) async {
    final client = ApiClient(url, token);
    await client.health();
    await client.printers(); // valida el token
    await store.setServer(client.baseUrl, token);
    await store.setLastEventId(0);
    _disconnect();
    printers.clear();
    events.clear();
    _connect();
    if (store.backgroundMonitor) await BackgroundMonitor.start();
  }

  Future<void> logout() async {
    await BackgroundMonitor.stop();
    _disconnect();
    await store.clear();
    printers.clear();
    events.clear();
    queues.clear();
    api = null;
    notifyListeners();
  }

  void select(String id) {
    selectedId = id;
    store.setSelectedPrinter(id);
    notifyListeners();
  }

  Future<void> setBackgroundMonitor(bool on) async {
    await store.setBackgroundMonitor(on);
    on ? await BackgroundMonitor.start() : await BackgroundMonitor.stop();
    notifyListeners();
  }

  // ---- conexión --------------------------------------------------------
  Future<void> _connect() async {
    _reconnect?.cancel();
    api ??= ApiClient(store.serverUrl, store.token);
    conn = ConnState.connecting;
    notifyListeners();
    try {
      final list = await api!.printers();
      for (final p in list) {
        printers[p.id] = p;
      }
      selectedId ??= store.selectedPrinter;
      final evs = await api!.events();
      events
        ..clear()
        ..addAll(evs.reversed);

      final ws = WebSocketChannel.connect(api!.wsUri);
      await ws.ready.timeout(const Duration(seconds: 10));
      _ws = ws;
      _wsSub = ws.stream.listen(_onMessage, onDone: _onWsClosed, onError: (_) => _onWsClosed());
      _ping = Timer.periodic(const Duration(seconds: 20), (_) => _ws?.sink.add('ping'));
      conn = ConnState.connected;
      connError = null;
      _backoff = 1;
      for (final id in printers.keys) {
        refreshQueue(id);
      }
      refreshSpools();
    } catch (e) {
      connError = e is ApiException ? e.message : 'No se pudo conectar al servidor';
      conn = ConnState.disconnected;
      _scheduleReconnect();
    }
    notifyListeners();
  }

  void _onMessage(dynamic raw) {
    final msg = jsonDecode(raw as String) as Map<String, dynamic>;
    switch (msg['type']) {
      case 'status':
        final p = printers[msg['printer_id']];
        if (p != null) {
          p.status = PrinterStatus.fromJson(msg['data']);
          notifyListeners();
        }
      case 'queue':
        refreshQueue(msg['printer_id']);
      case 'history':
        historyVersion++;
        refreshSpools();
      case 'event':
        final e = PrinterEvent.fromJson(msg['data']);
        events.insert(0, e);
        if (events.length > 300) events.removeLast();
        _eventCtrl.add(e);
        // En iOS (sin servicio en segundo plano) avisamos mientras la app viva
        if (!_foreground && !BackgroundMonitor.supported && e.type != 'progress') {
          Notifications.showEvent(e);
        }
        notifyListeners();
    }
  }

  void _onWsClosed() {
    if (conn == ConnState.disconnected) return;
    _cleanupWs();
    conn = ConnState.disconnected;
    connError = 'Conexión perdida';
    notifyListeners();
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    _reconnect?.cancel();
    if (!store.configured || !_foreground) return;
    _reconnect = Timer(Duration(seconds: _backoff), _connect);
    _backoff = (_backoff * 2).clamp(1, 30);
  }

  void retryNow() {
    _backoff = 1;
    _connect();
  }

  void _cleanupWs() {
    _ping?.cancel();
    _wsSub?.cancel();
    _ws?.sink.close();
    _ws = null;
  }

  void _disconnect() {
    _reconnect?.cancel();
    _cleanupWs();
    conn = ConnState.disconnected;
    api?.close();
    api = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final fg = state == AppLifecycleState.resumed;
    if (fg == _foreground) return;
    _foreground = fg;
    if (fg && store.configured && conn == ConnState.disconnected) retryNow();
  }

  // ---- cola -------------------------------------------------------------
  QueueState queueOf(String printerId) => queues[printerId] ?? QueueState.empty();

  Future<void> refreshQueue(String printerId) async {
    final a = api;
    if (a == null || _queueLoading[printerId] == true) return;
    _queueLoading[printerId] = true;
    try {
      queues[printerId] = await a.queue(printerId);
      notifyListeners();
    } catch (_) {
      // se reintenta con el próximo aviso del servidor
    } finally {
      _queueLoading[printerId] = false;
    }
  }

  Future<void> refreshSpools() async {
    final a = api;
    if (a == null) return;
    try {
      spools = await a.spools();
      notifyListeners();
    } catch (_) {}
  }

  Spool? spoolInTray(String printerId, int tray) =>
      spools.where((s) => s.printerId == printerId && s.tray == tray).firstOrNull;

  void setQueue(String printerId, QueueState q) {
    queues[printerId] = q;
    notifyListeners();
  }

  // ---- acciones --------------------------------------------------------
  /// Ejecuta una acción contra la API y devuelve el error (o null si salió bien).
  Future<String?> run(Future<void> Function(ApiClient api, String printerId) action) async {
    final a = api, p = selected;
    if (a == null || p == null) return 'Sin conexión';
    try {
      await action(a, p.id);
      return null;
    } on ApiException catch (e) {
      return e.message;
    } catch (e) {
      return '$e';
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _disconnect();
    _eventCtrl.close();
    super.dispose();
  }
}
