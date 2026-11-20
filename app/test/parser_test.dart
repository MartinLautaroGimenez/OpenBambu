import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openbambu/api/client.dart';
import 'package:openbambu/api/models.dart';

List<int> fakeJpeg(int n) => [0xFF, 0xD8, ...List.filled(n, 0x11), 0xFF, 0xD9];

void main() {
  test('MjpegParser extrae frames partidos en varios chunks', () async {
    List<int> part(List<int> j) => [...'--b\r\nContent-Type: image/jpeg\r\n\r\n'.codeUnits, ...j, 13, 10];
    final all = [...part(fakeJpeg(50)), ...part(fakeJpeg(80)), ...part(fakeJpeg(10))];
    // trocear en pedazos de 7 bytes
    final chunks = <List<int>>[for (var i = 0; i < all.length; i += 7) all.sublist(i, (i + 7).clamp(0, all.length))];
    final frames = await MjpegParser().bind(Stream.fromIterable(chunks)).toList();
    expect(frames.map((f) => f.length), [54, 84, 14]);
    expect(frames.first.sublist(0, 2), Uint8List.fromList([0xFF, 0xD8]));
  });

  test('normaliza URL del servidor', () {
    expect(ApiClient.normalizeUrl('192.168.1.5:8787/'), 'http://192.168.1.5:8787');
    expect(ApiClient.normalizeUrl('https://x.ts.net'), 'https://x.ts.net');
    expect(ApiClient('x:1', 't').wsUri.toString(), 'ws://x:1/api/ws?token=t');
  });

  test('parsea el estado de la impresora', () {
    final p = Printer.fromJson({
      'id': 'a1',
      'name': 'A1',
      'model': 'A1',
      'capabilities': {'max_bed_temp': 100},
      'status': {
        'connected': true,
        'state': 'RUNNING',
        'job': {'name': 'Benchy', 'progress': 40, 'eta': 1700000000.5},
        'ams': {
          'units': [
            {
              'id': 0,
              'trays': [
                {'id': 0, 'global_id': 0, 'loaded': true, 'color': '#FF0000', 'active': true},
              ],
            },
          ],
          'external': null,
        },
      },
    });
    expect(p.status.isPrinting, isTrue);
    expect(p.status.job.progress, 40);
    expect(p.status.ams.single.trays.single.active, isTrue);
    expect(p.caps.maxBedTemp, 100);
  });
}
