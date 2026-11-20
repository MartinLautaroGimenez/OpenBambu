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
