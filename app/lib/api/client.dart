import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'models.dart';

class ApiException implements Exception {
  final int? status;
  final String message;
  ApiException(this.message, [this.status]);
  @override
  String toString() => message;
}

/// Cliente HTTP del servidor OpenBambu.
class ApiClient {
  final String baseUrl;
  final String token;
  final http.Client _http;

  ApiClient(String baseUrl, this.token, {http.Client? client})
    : baseUrl = normalizeUrl(baseUrl),
      _http = client ?? http.Client();

  static String normalizeUrl(String url) {
    var u = url.trim();
    if (u.isEmpty) return u;
    if (!u.startsWith('http://') && !u.startsWith('https://')) u = 'http://$u';
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }

  Map<String, String> get headers => {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'};

  Uri uri(String path, [Map<String, String>? query]) => Uri.parse('$baseUrl/api$path').replace(queryParameters: query);

  Uri get wsUri {
    final u = Uri.parse(baseUrl);
    return u.replace(scheme: u.scheme == 'https' ? 'wss' : 'ws', path: '/api/ws', queryParameters: {'token': token});
  }

  Future<dynamic> _req(String method, String path, {Object? body, Map<String, String>? query}) async {
    final req = http.Request(method, uri(path, query))..headers.addAll(headers);
    if (body != null) req.body = jsonEncode(body);
    late http.Response res;
    try {
      res = await http.Response.fromStream(await _http.send(req).timeout(const Duration(seconds: 12)));
    } on TimeoutException {
      throw ApiException('El servidor no responde');
    } catch (e) {
      throw ApiException('No se pudo conectar al servidor');
    }
    final text = utf8.decode(res.bodyBytes);
    if (res.statusCode >= 400) {
      String msg = 'Error ${res.statusCode}';
      try {
        final d = jsonDecode(text)['detail'];
        msg = d is String ? d : (d is List && d.isNotEmpty ? '${d.first['msg']}' : msg);
      } catch (_) {}
      if (res.statusCode == 401) msg = 'Token inválido';
      throw ApiException(msg, res.statusCode);
    }
    return text.isEmpty ? null : jsonDecode(text);
  }

  Future<Map<String, dynamic>> health() async => (await _req('GET', '/health')) as Map<String, dynamic>;

  Future<List<Printer>> printers() async => [
    for (final p in (await _req('GET', '/printers')) as List) Printer.fromJson(p),
  ];

  Future<List<PrinterEvent>> events({int after = 0}) async => [
    for (final e in (await _req('GET', '/events', query: {'after': '$after'})) as List) PrinterEvent.fromJson(e),
  ];

  Future<void> post(String printerId, String path, [Object? body]) =>
      _req('POST', '/printers/$printerId$path', body: body ?? const {});

  // ---- control --------------------------------------------------------
  Future<void> pause(String id) => post(id, '/print/pause');
  Future<void> resume(String id) => post(id, '/print/resume');
  Future<void> stop(String id) => post(id, '/print/stop');
  Future<void> speed(String id, int level) => post(id, '/speed', {'level': level});
  Future<void> temperature(String id, String target, int value) =>
      post(id, '/temperature', {'target': target, 'value': value});
  Future<void> fan(String id, String fan, int percent) => post(id, '/fan', {'fan': fan, 'percent': percent});
  Future<void> light(String id, bool on) => post(id, '/light', {'on': on});
  Future<void> home(String id) => post(id, '/home');
  Future<void> move(String id, String axis, double distance) => post(id, '/move', {'axis': axis, 'distance': distance});
  Future<void> extrude(String id, double distance) => post(id, '/extrude', {'distance': distance});
  Future<void> gcode(String id, String gcode) => post(id, '/gcode', {'gcode': gcode});
  Future<void> refresh(String id) => post(id, '/refresh');

  // ---- AMS ------------------------------------------------------------
  Future<void> amsLoad(String id, int tray) => post(id, '/ams/load', {'tray': tray});
  Future<void> amsUnload(String id) => post(id, '/ams/unload');
  Future<void> amsControl(String id, String action) => post(id, '/ams/control', {'action': action});
  Future<void> amsFilament(String id, int tray, String type, String color) =>
      post(id, '/ams/filament', {'tray': tray, 'type': type, 'color': color});

  Future<void> testNotification() => _req('POST', '/notifications/test');

  // ---- biblioteca -----------------------------------------------------
  Future<List<LibraryItem>> library() async => [
    for (final x in (await _req('GET', '/library')) as List) LibraryItem.fromJson(x),
  ];

  Uri thumbnail(String libraryId, int plate) =>
      uri('/library/$libraryId/plates/$plate/thumbnail.png', {'token': token});

  Future<void> deleteLibraryItem(String id) => _req('DELETE', '/library/$id');

  /// Sube un archivo a la biblioteca enviando el contenido en streaming.
  Future<LibraryItem> uploadLibrary(
    String filename,
    int length,
    Stream<List<int>> data, {
    void Function(double progress)? onProgress,
  }) async {
    final req = http.StreamedRequest('PUT', uri('/library', {'filename': filename}))
      ..headers['Authorization'] = 'Bearer $token'
      ..headers['Content-Type'] = 'application/octet-stream'
      ..contentLength = length;
    var sent = 0;
    data.listen(
      (chunk) {
        req.sink.add(chunk);
        sent += chunk.length;
        if (length > 0) onProgress?.call(sent / length);
      },
      onDone: req.sink.close,
      onError: req.sink.addError,
      cancelOnError: true,
    );
    final res = await http.Response.fromStream(await _http.send(req));
    final text = utf8.decode(res.bodyBytes);
    if (res.statusCode >= 400) {
      String msg = 'Error ${res.statusCode}';
      try {
        msg = jsonDecode(text)['detail'];
      } catch (_) {}
      throw ApiException(msg, res.statusCode);
    }
    return LibraryItem.fromJson(jsonDecode(text));
  }

  Future<List<TrayAssignment>> suggestMapping(String libraryId, String printerId, int plate) async => [
    for (final x in (await _req(
      'GET',
      '/library/$libraryId/mapping',
      query: {'printer_id': printerId, 'plate': '$plate'},
    )) as List)
      TrayAssignment.fromJson(x),
  ];

  // ---- laminado -------------------------------------------------------
  Future<bool> slicerAvailable() async => ((await _req('GET', '/slicer')) as Map)['available'] == true;

  /// Estado del laminador: disponible y funciones que soporta el servidor.
  Future<({bool available, Set<String> features})> slicerStatus() async {
    final m = (await _req('GET', '/slicer')) as Map;
    return (available: m['available'] == true, features: {for (final f in (m['features'] as List? ?? [])) '$f'});
  }

  Future<SlicerProfiles> slicerProfiles(String printerId) async =>
      SlicerProfiles.fromJson(await _req('GET', '/slicer/profiles', query: {'printer_id': printerId}));

  Future<SliceJob> slice(
    String libraryId, {
    required String printerId,
    required String? process,
    required List<String> filaments,
    required Map<String, dynamic> overrides,
    int copies = 1,
    int plate = 0,
  }) async => SliceJob.fromJson(
    await _req(
      'POST',
      '/library/$libraryId/slice',
      body: {
        'printer_id': printerId,
        'process': process,
        'filaments': filaments,
        'overrides': overrides,
        'copies': copies,
        'plate': plate,
      },
    ),
  );

  Future<ProjectInfo> projectInfo(String libraryId) async =>
      ProjectInfo.fromJson(await _req('GET', '/library/$libraryId/project'));

  Future<SliceJob> sliceJob(String id) async => SliceJob.fromJson(await _req('GET', '/slicer/jobs/$id'));

  Future<LibraryItem> libraryItem(String id) async => LibraryItem.fromJson(await _req('GET', '/library/$id'));

  // ---- catálogo -------------------------------------------------------
  Future<List<CatalogSource>> catalogSources() async => [
    for (final x in (await _req('GET', '/catalog/sources')) as List) CatalogSource.fromJson(x),
  ];

  Future<List<CatalogItem>> catalogBrowse({String query = '', String? source, int page = 0}) async {
    final d = await _req('GET', '/catalog', query: {'q': query, 'page': '$page', 'limit': '24', 'source': ?source});
    return [for (final x in (d['items'] as List)) CatalogItem.fromJson(x)];
  }

  /// Imagen del catálogo achicada por el servidor (ahorra datos y evita CORS en web).
  String catalogImage(String url, {int width = 480}) =>
      uri('/catalog/image', {'url': url, 'w': '$width', 'token': token}).toString();

  /// Inicia sesión en MakerWorld. Devuelve true si falta el código del email.
  Future<bool> makerWorldLogin({String email = '', String password = '', String code = '', String token = ''}) async {
    final r = await _req(
      'POST',
      '/catalog/makerworld/login',
      body: {'email': email, 'password': password, 'code': code, 'token': token},
    );
    return r['needs_code'] == true;
  }

  Future<void> makerWorldLogout() => _req('DELETE', '/catalog/makerworld/login');

  Future<CatalogDetail> catalogDetail(String source, String id) async =>
      CatalogDetail.fromJson(await _req('GET', '/catalog/$source/$id'));

  Future<List<LibraryItem>> catalogDownload(String source, String id, List<String> fileIds) async => [
    for (final x in (await _req('POST', '/catalog/$source/$id/download', body: {'file_ids': fileIds})) as List)
      LibraryItem.fromJson(x),
  ];

  // ---- historial e inventario -----------------------------------------
  Future<List<PrintRecord>> history({String? printerId, int offset = 0, int? projectId, bool unrated = false}) async =>
      [
        for (final x in (await _req(
          'GET',
          '/history',
          query: {
            'printer_id': ?printerId,
            'offset': '$offset',
            'limit': '30',
            if (projectId != null) 'project_id': '$projectId',
            if (unrated) 'unrated': 'true',
          },
        )) as List)
          PrintRecord.fromJson(x),
      ];

  Future<PrintRecord> ratePrint(int id, String? rating, {String? reason}) async =>
      PrintRecord.fromJson(await _req('POST', '/history/$id/rating', body: {'rating': rating, 'reason': reason}));

  Future<PrintRecord> setPrintProject(int id, int? projectId) async =>
      PrintRecord.fromJson(await _req('PATCH', '/history/$id', body: {'project_id': projectId}));

  // ---- proyectos -------------------------------------------------------
  Future<List<Project>> projects({bool archived = false}) async => [
    for (final x in (await _req('GET', '/projects', query: {if (archived) 'archived': 'true'})) as List)
      Project.fromJson(x),
  ];

  Future<Project> saveProject(Map<String, dynamic> data, {int? id}) async => Project.fromJson(
    await _req(id == null ? 'POST' : 'PATCH', id == null ? '/projects' : '/projects/$id', body: data),
  );

  Future<void> deleteProject(int id) => _req('DELETE', '/projects/$id');

  // ---- mantenimiento -----------------------------------------------------
  Future<List<MaintenanceOverview>> maintenanceAll() async => [
    for (final x in (await _req('GET', '/maintenance')) as List) MaintenanceOverview.fromJson(x),
  ];

  Future<MaintenanceOverview> maintenance(String printerId) async =>
      MaintenanceOverview.fromJson(await _req('GET', '/printers/$printerId/maintenance'));

  Future<MaintenanceOverview> saveMaintenanceTask(String printerId, Map<String, dynamic> data, {int? id}) async =>
      MaintenanceOverview.fromJson(
        await _req(
          id == null ? 'POST' : 'PATCH',
          id == null ? '/printers/$printerId/maintenance' : '/printers/$printerId/maintenance/$id',
          body: data,
        ),
      );

  Future<MaintenanceOverview> deleteMaintenanceTask(String printerId, int id) async =>
      MaintenanceOverview.fromJson(await _req('DELETE', '/printers/$printerId/maintenance/$id'));

  Future<MaintenanceOverview> maintenanceDone(String printerId, int id, {String notes = ''}) async =>
      MaintenanceOverview.fromJson(
        await _req('POST', '/printers/$printerId/maintenance/$id/done', body: {'notes': notes}),
      );

  Future<PrintStats> stats({String? printerId}) async =>
      PrintStats.fromJson(await _req('GET', '/history/stats', query: {'printer_id': ?printerId}));

  String historySnapshot(int id) => uri('/history/$id/snapshot.jpg', {'token': token}).toString();

  Future<void> deleteHistory(int id) => _req('DELETE', '/history/$id');

  String historyTimelapse(int id) => uri('/history/$id/timelapse.mp4', {'token': token}).toString();

  Future<Map<String, dynamic>> timelapseConfig() async =>
      (await _req('GET', '/timelapse/config')) as Map<String, dynamic>;

  Future<Map<String, dynamic>> saveTimelapseConfig(Map<String, dynamic> data) async =>
      (await _req('PUT', '/timelapse/config', body: data)) as Map<String, dynamic>;

  Future<List<Spool>> spools() async => [for (final x in (await _req('GET', '/spools')) as List) Spool.fromJson(x)];

  Future<Spool> addSpool(Map<String, dynamic> data) async => Spool.fromJson(await _req('POST', '/spools', body: data));

  Future<Spool> updateSpool(int id, Map<String, dynamic> data) async =>
      Spool.fromJson(await _req('PATCH', '/spools/$id', body: data));

  String spoolLabel(int id) => uri('/spools/$id/label.png', {'token': token}).toString();

  Future<Spool> spoolByCode(String code) async =>
      Spool.fromJson(await _req('GET', '/spools/by-code', query: {'code': code}));

  Future<void> deleteSpool(int id) => _req('DELETE', '/spools/$id');

  // ---- energía (Home Assistant) --------------------------------------
  Future<Map<String, dynamic>> powerConfig() async => (await _req('GET', '/power/config')) as Map<String, dynamic>;

  Future<Map<String, dynamic>> savePowerConfig(Map<String, dynamic> data) async =>
      (await _req('PUT', '/power/config', body: data)) as Map<String, dynamic>;

  Future<List<Map<String, dynamic>>> powerEntities({String kind = 'switch'}) async => [
    for (final x in (await _req('GET', '/power/entities', query: {'kind': kind})) as List) x as Map<String, dynamic>,
  ];

  Future<Map<String, dynamic>> powerStatus(String printerId) async =>
      (await _req('GET', '/printers/$printerId/power')) as Map<String, dynamic>;

  Future<Map<String, dynamic>> setPower(String printerId, bool on, {bool force = false}) async =>
      (await _req('POST', '/printers/$printerId/power', body: {'on': on, 'force': force})) as Map<String, dynamic>;

  // ---- administración de impresoras -----------------------------------
  Future<List<AdminPrinter>> adminPrinters() async => [
    for (final x in (await _req('GET', '/admin/printers')) as List) AdminPrinter.fromJson(x),
  ];

  Future<AdminPrinter> savePrinter(Map<String, dynamic> data, {String? id}) async => AdminPrinter.fromJson(
    await _req(id == null ? 'POST' : 'PUT', id == null ? '/admin/printers' : '/admin/printers/$id', body: data),
  );

  Future<void> deletePrinter(String id) => _req('DELETE', '/admin/printers/$id');

  Future<({bool ok, String message})> testPrinter(String host, String serial, String code, {String? id}) async {
    final r = await _req(
      'POST',
      '/admin/printers/test',
      body: {'host': host, 'serial': serial, 'access_code': code, 'printer_id': ?id},
    );
    return (ok: r['ok'] == true, message: '${r['message']}');
  }

  Future<({List<DiscoveredPrinter> printers, String? error})> discover() async {
    final r = await _req('GET', '/admin/discovery');
    return (
      printers: [for (final x in (r['printers'] as List)) DiscoveredPrinter.fromJson(x)],
      error: r['error'] as String?,
    );
  }

  // ---- tarjeta SD -----------------------------------------------------
  Future<List<SdFile>> sdFiles(String printerId, String path) async => [
    for (final x in (await _req('GET', '/printers/$printerId/files', query: {'path': path})) as List)
      SdFile.fromJson(x),
  ];

  Future<void> deleteSdFile(String printerId, String path) =>
      _req('DELETE', '/printers/$printerId/files', query: {'path': path});

  Future<LibraryItem> importSdFile(String printerId, String path) async =>
      LibraryItem.fromJson(await _req('POST', '/printers/$printerId/files/import', body: {'path': path}));

  // ---- cola -----------------------------------------------------------
  Future<QueueState> queue(String printerId) async =>
      QueueState.fromJson(await _req('GET', '/printers/$printerId/queue'));

  Future<QueueState> addJob(
    String printerId, {
    required String libraryId,
    required int plate,
    required List<TrayAssignment> mapping,
    required Map<String, bool> options,
    int copies = 1,
    bool startNow = false,
    bool bedClear = false,
    DateTime? startAfter,
    int? projectId,
  }) async => QueueState.fromJson(
    await _req(
      'POST',
      '/printers/$printerId/queue',
      body: {
        'library_id': libraryId,
        'plate': plate,
        'mapping': [for (final m in mapping) m.toJson()],
        'options': options,
        'copies': copies,
        'start_now': startNow,
        'bed_clear': bedClear,
        if (startAfter != null) 'start_after': startAfter.millisecondsSinceEpoch / 1000,
        'project_id': ?projectId,
      },
    ),
  );

  Future<QueueState> deleteJob(String printerId, int jobId) async =>
      QueueState.fromJson(await _req('DELETE', '/printers/$printerId/queue/$jobId'));

  Future<QueueState> reorderQueue(String printerId, List<int> ids) async =>
      QueueState.fromJson(await _req('POST', '/printers/$printerId/queue/reorder', body: {'ids': ids}));

  Future<QueueState> bedClear(String printerId) async =>
      QueueState.fromJson(await _req('POST', '/printers/$printerId/queue/bed-clear'));

  Future<QueueState> pauseQueue(String printerId, bool paused) async =>
      QueueState.fromJson(await _req('POST', '/printers/$printerId/queue/pause', body: {'paused': paused}));

  Future<QueueState> clearHistory(String printerId) async =>
      QueueState.fromJson(await _req('DELETE', '/printers/$printerId/queue'));

  // ---- cámara ---------------------------------------------------------
  Uri cameraStream(String id) => uri('/printers/$id/camera/stream.mjpg');

  Future<Uint8List> snapshot(String id) async {
    final res = await _http
        .get(uri('/printers/$id/camera/snapshot.jpg'), headers: headers)
        .timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) {
      String msg = 'Cámara no disponible';
      try {
        msg = jsonDecode(res.body)['detail'];
      } catch (_) {}
      throw ApiException(msg, res.statusCode);
    }
    return res.bodyBytes;
  }

  /// Abre el stream MJPEG y emite cada frame JPEG.
  Stream<Uint8List> mjpeg(String id) async* {
    final req = http.Request('GET', cameraStream(id))..headers.addAll(headers);
    final client = http.Client();
    try {
      final res = await client.send(req).timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) throw ApiException('Cámara no disponible', res.statusCode);
      yield* MjpegParser().bind(res.stream);
    } finally {
      client.close();
    }
  }

  void close() => _http.close();
}

/// Extrae frames JPEG de un stream multipart/x-mixed-replace.
class MjpegParser extends StreamTransformerBase<List<int>, Uint8List> {
  @override
  Stream<Uint8List> bind(Stream<List<int>> stream) async* {
    final buf = BytesBuilder(copy: false);
    var data = Uint8List(0);
    await for (final chunk in stream) {
      buf.add(data);
      buf.add(chunk);
      data = buf.takeBytes();
      while (true) {
        final start = _find(data, 0xD8, 0);
        if (start < 0) {
          data = Uint8List(0);
          break;
        }
        final end = _find(data, 0xD9, start + 2);
        if (end < 0) {
          data = Uint8List.sublistView(data, start);
          break;
        }
        yield Uint8List.fromList(Uint8List.sublistView(data, start, end + 2));
        data = Uint8List.sublistView(data, end + 2);
      }
      if (data.length > 8 * 1024 * 1024) data = Uint8List(0);
    }
  }

  static int _find(Uint8List d, int marker, int from) {
    for (var i = from; i < d.length - 1; i++) {
      if (d[i] == 0xFF && d[i + 1] == marker) return i;
    }
    return -1;
  }
}
