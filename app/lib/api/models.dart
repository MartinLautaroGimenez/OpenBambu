// Modelos que reflejan la API del servidor OpenBambu.

double _d(dynamic v) => v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
int _i(dynamic v, [int def = 0]) => v is num ? v.toInt() : int.tryParse('$v') ?? def;

class Capabilities {
  final int maxNozzleTemp;
  final int maxBedTemp;
  final bool hasAuxFan;
  final bool hasChamberFan;
  final bool hasChamberTemp;
  final String camera;

  Capabilities.fromJson(Map<String, dynamic> j)
    : maxNozzleTemp = _i(j['max_nozzle_temp'], 300),
      maxBedTemp = _i(j['max_bed_temp'], 100),
      hasAuxFan = j['has_aux_fan'] == true,
      hasChamberFan = j['has_chamber_fan'] == true,
      hasChamberTemp = j['has_chamber_temp'] == true,
      camera = j['camera'] ?? 'tcp_jpeg';
}

class Printer {
  final String id;
  final String name;
  final String model;
  final String mode;
  final Capabilities caps;
  PrinterStatus status;

  Printer.fromJson(Map<String, dynamic> j)
    : id = j['id'],
      name = j['name'] ?? j['id'],
      model = j['model'] ?? 'A1',
      mode = j['mode'] ?? 'lan',
      caps = Capabilities.fromJson(j['capabilities'] ?? const {}),
      status = PrinterStatus.fromJson(j['status'] ?? const {});

  String get modelLabel => model == 'A1MINI' ? 'A1 mini' : model;
}

class Job {
  final String? name;
  final int progress;
  final int layer;
  final int totalLayers;
  final int remainingMin;
  final DateTime? eta;
  final int printError;

  Job.fromJson(Map<String, dynamic> j)
    : name = j['name'],
      progress = _i(j['progress']),
      layer = _i(j['layer']),
      totalLayers = _i(j['total_layers']),
      remainingMin = _i(j['remaining_min']),
      eta = j['eta'] == null ? null : DateTime.fromMillisecondsSinceEpoch((_d(j['eta']) * 1000).round()),
      printError = _i(j['print_error']);
}

class Temps {
  final double nozzle, nozzleTarget, bed, bedTarget;
  final double? chamber;

  Temps.fromJson(Map<String, dynamic> j)
    : nozzle = _d(j['nozzle']),
      nozzleTarget = _d(j['nozzle_target']),
      bed = _d(j['bed']),
      bedTarget = _d(j['bed_target']),
      chamber = j['chamber'] == null ? null : _d(j['chamber']);
}

class Fans {
  final int part;
  final int? aux, chamber;
  final int heatbreak;

  Fans.fromJson(Map<String, dynamic> j)
    : part = _i(j['part']),
      aux = j['aux'] == null ? null : _i(j['aux']),
      chamber = j['chamber'] == null ? null : _i(j['chamber']),
      heatbreak = _i(j['heatbreak']);
}

class Tray {
  final int id;
  final int globalId;
  final bool loaded;
  final String? type;
  final String? name;
  final String? color;
  final int remain;
  final int? tempMin, tempMax;
  final bool active;

  Tray.fromJson(Map<String, dynamic> j)
    : id = _i(j['id']),
      globalId = _i(j['global_id']),
      loaded = j['loaded'] == true,
      type = j['type'],
      name = j['name'],
      color = j['color'],
      remain = _i(j['remain'], -1),
      tempMin = j['nozzle_temp_min'] == null ? null : _i(j['nozzle_temp_min']),
      tempMax = j['nozzle_temp_max'] == null ? null : _i(j['nozzle_temp_max']),
      active = j['active'] == true;
}

class AmsUnit {
  final int id;
  final int humidity;
  final List<Tray> trays;

  AmsUnit.fromJson(Map<String, dynamic> j)
    : id = _i(j['id']),
      humidity = _i(j['humidity'], -1),
      trays = [for (final t in (j['trays'] as List? ?? [])) Tray.fromJson(t)];
}

class Hms {
  final String code;
  final String severity;
  final String url;

  Hms.fromJson(Map<String, dynamic> j)
    : code = j['code'] ?? '',
      severity = j['severity'] ?? 'info',
      url = j['url'] ?? '';
}

class PrinterStatus {
  final bool connected;
  final String state;
  final String stateLabel;
  final int stage;
  final String stageLabel;
  final Job job;
  final Temps temps;
  final Fans fans;
  final int speedLevel;
  final int speedPercent;
  final bool light;
  final List<AmsUnit> ams;
  final Tray? externalSpool;
  final List<Hms> hms;
  final String? wifi;

  PrinterStatus.fromJson(Map<String, dynamic> j)
    : connected = j['connected'] == true,
      state = j['state'] ?? 'OFFLINE',
      stateLabel = j['state_label'] ?? 'Desconectada',
      stage = _i(j['stage'], -1),
      stageLabel = j['stage_label'] ?? '',
      job = Job.fromJson(j['job'] ?? const {}),
      temps = Temps.fromJson(j['temps'] ?? const {}),
      fans = Fans.fromJson(j['fans'] ?? const {}),
      speedLevel = _i((j['speed'] ?? const {})['level'], 2),
      speedPercent = _i((j['speed'] ?? const {})['percent'], 100),
      light = j['light'] == true,
      ams = [for (final u in ((j['ams'] ?? const {})['units'] as List? ?? [])) AmsUnit.fromJson(u)],
      externalSpool = (j['ams'] ?? const {})['external'] == null ? null : Tray.fromJson((j['ams'] as Map)['external']),
      hms = [for (final h in (j['hms'] as List? ?? [])) Hms.fromJson(h)],
      wifi = j['wifi_signal'];

  bool get isPrinting => state == 'RUNNING' || state == 'PREPARE';
  bool get isPaused => state == 'PAUSE';
  bool get isActive => isPrinting || isPaused;
  bool get isOffline => !connected || state == 'OFFLINE';
}

class PrinterEvent {
  final int id;
  final String printerId;
  final String printerName;
  final String type;
  final String title;
  final String message;
  final String severity;
  final int? progress;
  final DateTime time;

  PrinterEvent.fromJson(Map<String, dynamic> j)
    : id = _i(j['id']),
      printerId = j['printer_id'] ?? '',
      printerName = j['printer_name'] ?? '',
      type = j['type'] ?? '',
      title = j['title'] ?? '',
      message = j['message'] ?? '',
      severity = j['severity'] ?? 'info',
      progress = j['progress'] == null ? null : _i(j['progress']),
      time = DateTime.fromMillisecondsSinceEpoch((_d(j['ts']) * 1000).round());
}
