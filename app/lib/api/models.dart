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
  final String? printErrorText;

  Job.fromJson(Map<String, dynamic> j)
    : name = j['name'],
      progress = _i(j['progress']),
      layer = _i(j['layer']),
      totalLayers = _i(j['total_layers']),
      remainingMin = _i(j['remaining_min']),
      eta = j['eta'] == null ? null : DateTime.fromMillisecondsSinceEpoch((_d(j['eta']) * 1000).round()),
      printError = _i(j['print_error']),
      printErrorText = j['print_error_text'];
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
  final String? description;

  Hms.fromJson(Map<String, dynamic> j)
    : code = j['code'] ?? '',
      severity = j['severity'] ?? 'info',
      url = j['url'] ?? '',
      description = j['description'];
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
  final List<int> skippedObjects;

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
      wifi = j['wifi_signal'],
      skippedObjects = [for (final x in (j['skipped_objects'] as List? ?? [])) _i(x)];

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

// ---- Etapa 2: biblioteca, SD y cola --------------------------------------

class FileFilament {
  final int id;
  final String type;
  final String? color;
  final double? usedG;

  FileFilament.fromJson(Map<String, dynamic> j)
    : id = _i(j['id']),
      type = j['type'] ?? 'PLA',
      color = j['color'],
      usedG = j['used_g'] == null ? null : _d(j['used_g']);
}

class Plate {
  final int index;
  final bool thumbnail;
  final int? predictionS;
  final double? weightG;
  final List<FileFilament> filaments;

  Plate.fromJson(Map<String, dynamic> j)
    : index = _i(j['index'], 1),
      thumbnail = j['thumbnail'] == true,
      predictionS = j['prediction_s'] == null ? null : _i(j['prediction_s']),
      weightG = j['weight_g'] == null ? null : _d(j['weight_g']),
      filaments = [for (final f in (j['filaments'] as List? ?? [])) FileFilament.fromJson(f)];
}

class LibraryItem {
  final String id;
  final String name;
  final String filename;
  final int size;
  final DateTime added;
  final String source;
  final bool sliced;
  final String? format;
  final String? catalogImage;
  final List<Plate> plates;
  final List<ProjectPlate> projectPlates;

  LibraryItem.fromJson(Map<String, dynamic> j)
    : id = j['id'],
      name = j['name'] ?? '',
      filename = j['filename'] ?? '',
      size = _i(j['size']),
      added = DateTime.fromMillisecondsSinceEpoch((_d(j['added']) * 1000).round()),
      source = j['source'] ?? 'upload',
      sliced = (j['meta'] ?? const {})['sliced'] == true,
      format = (j['meta'] ?? const {})['format'],
      catalogImage = ((j['meta'] ?? const {})['catalog'] ?? const {})['image'],
      plates = [for (final p in ((j['meta'] ?? const {})['plates'] as List? ?? [])) Plate.fromJson(p)],
      projectPlates = [
        for (final p in ((j['meta'] ?? const {})['project_plates'] as List? ?? [])) ProjectPlate.fromJson(p),
      ];
}

class SdFile {
  final String name;
  final String path;
  final bool isDir;
  final int size;
  final DateTime? modified;
  final bool printable;

  SdFile.fromJson(Map<String, dynamic> j)
    : name = j['name'] ?? '',
      path = j['path'] ?? '',
      isDir = j['is_dir'] == true,
      size = _i(j['size']),
      modified = j['modified'] == null ? null : DateTime.fromMillisecondsSinceEpoch((_d(j['modified']) * 1000).round()),
      printable = j['printable'] == true;
}

class TrayAssignment {
  final int filamentId;
  int? tray;
  final String reason;

  TrayAssignment(this.filamentId, this.tray, [this.reason = '']);

  TrayAssignment.fromJson(Map<String, dynamic> j)
    : filamentId = _i(j['filament_id']),
      tray = j['tray'] == null ? null : _i(j['tray']),
      reason = j['reason'] ?? '';

  Map<String, dynamic> toJson() => {'filament_id': filamentId, 'tray': tray};
}

class QueueJob {
  final int id;
  final String libraryId;
  final String name;
  final int plate;
  final String status;
  final String? error;
  final double? uploadProgress;
  final DateTime created;
  final DateTime? finished;
  final DateTime? startAfter;

  QueueJob.fromJson(Map<String, dynamic> j)
    : id = _i(j['id']),
      libraryId = j['library_id'] ?? '',
      name = j['name'] ?? '',
      plate = _i(j['plate'], 1),
      status = j['status'] ?? 'queued',
      error = j['error'],
      uploadProgress = j['upload_progress'] == null ? null : _d(j['upload_progress']),
      created = DateTime.fromMillisecondsSinceEpoch((_d(j['created']) * 1000).round()),
      startAfter = j['start_after'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch((_d(j['start_after']) * 1000).round()),
      finished = j['finished'] == null ? null : DateTime.fromMillisecondsSinceEpoch((_d(j['finished']) * 1000).round());

  bool get isQueued => status == 'queued';
  bool get isScheduled => isQueued && startAfter != null && startAfter!.isAfter(DateTime.now());
  bool get isActive => status == 'uploading' || status == 'starting' || status == 'printing';
  bool get isHistory => !isQueued && !isActive;

  String get statusLabel => switch (status) {
    'queued' => 'En cola',
    'uploading' => 'Subiendo',
    'starting' => 'Iniciando',
    'printing' => 'Imprimiendo',
    'done' => 'Terminado',
    'failed' => 'Falló',
    'cancelled' => 'Cancelado',
    _ => status,
  };
}

class QueueState {
  final bool paused;
  final bool bedClear;
  final bool waitingBedClear;
  final List<QueueJob> jobs;

  QueueState.fromJson(Map<String, dynamic> j)
    : paused = j['paused'] == true,
      bedClear = j['bed_clear'] == true,
      waitingBedClear = j['waiting_bed_clear'] == true,
      jobs = [for (final x in (j['jobs'] as List? ?? [])) QueueJob.fromJson(x)];

  QueueState.empty() : paused = false, bedClear = false, waitingBedClear = false, jobs = const [];

  List<QueueJob> get pending => jobs.where((j) => !j.isHistory).toList();
  List<QueueJob> get history => jobs.where((j) => j.isHistory).toList();
}

// ---- Etapa 3: laminado ---------------------------------------------------

class ProcessProfile {
  final String name;
  final String label;
  final double? layerHeight;

  ProcessProfile.fromJson(Map<String, dynamic> j)
    : name = j['name'],
      label = j['label'] ?? j['name'],
      layerHeight = j['layer_height'] == null ? null : _d(j['layer_height']);
}

class FilamentProfile {
  final String name;
  final String label;
  final String type;
  final String vendor;

  FilamentProfile.fromJson(Map<String, dynamic> j)
    : name = j['name'],
      label = j['label'] ?? j['name'],
      type = j['type'] ?? 'PLA',
      vendor = j['vendor'] ?? '';
}

class TrayFilament {
  final int tray;
  final String? type;
  final String? color;
  final String? profile;

  TrayFilament.fromJson(Map<String, dynamic> j)
    : tray = _i(j['tray']),
      type = j['type'],
      color = j['color'],
      profile = j['profile'];
}

class SlicerProfiles {
  final String machine;
  final List<ProcessProfile> processes;
  final List<FilamentProfile> filaments;
  final String? defaultProcess;
  final String? defaultFilament;
  final List<TrayFilament> trayFilaments;

  SlicerProfiles.fromJson(Map<String, dynamic> j)
    : machine = j['machine'] ?? '',
      processes = [for (final p in (j['processes'] as List? ?? [])) ProcessProfile.fromJson(p)],
      filaments = [for (final f in (j['filaments'] as List? ?? [])) FilamentProfile.fromJson(f)],
      defaultProcess = j['default_process'],
      defaultFilament = j['default_filament'],
      trayFilaments = [for (final t in (j['tray_filaments'] as List? ?? [])) TrayFilament.fromJson(t)];
}

class SliceJob {
  final String id;
  final String name;
  final String status;
  final String? error;
  final String? resultId;
  final double elapsed;
  final List<String> logTail;

  SliceJob.fromJson(Map<String, dynamic> j)
    : id = j['id'],
      name = j['name'] ?? '',
      status = j['status'] ?? 'queued',
      error = j['error'],
      resultId = j['result_id'],
      elapsed = _d(j['elapsed']),
      logTail = [for (final l in (j['log_tail'] as List? ?? [])) '$l'];

  bool get finished => status == 'done' || status == 'failed';
}

// ---- Catálogo --------------------------------------------------------------

class CatalogSource {
  final String id;
  final String label;
  final bool enabled;
  final bool canDownload;

  CatalogSource.fromJson(Map<String, dynamic> j)
    : id = j['id'],
      label = j['label'] ?? j['id'],
      enabled = j['enabled'] == true,
      canDownload = j['can_download'] == true;
}

class CatalogItem {
  final String source;
  final String id;
  final String title;
  final String? image;
  final String? author;
  final int likes;
  final int downloads;
  final String? url;

  CatalogItem.fromJson(Map<String, dynamic> j)
    : source = j['source'],
      id = '${j['id']}',
      title = j['title'] ?? '',
      image = j['image'],
      author = j['author'],
      likes = _i(j['likes']),
      downloads = _i(j['downloads']),
      url = j['url'];
}

class CatalogFile {
  final String id;
  final String name;
  final String kind;
  final int? size;
  final String? printer;
  final int? predictionS;
  final double? weightG;
  final List<FileFilament> filaments;
  final String? image;
  final List<ProjectPlate> plates;
  final List<String> pictures;
  final String description;

  CatalogFile.fromJson(Map<String, dynamic> j)
    : id = '${j['id']}',
      name = j['name'] ?? '',
      kind = j['kind'] ?? 'stl',
      size = j['size'] == null ? null : _i(j['size']),
      printer = j['printer'],
      predictionS = j['prediction_s'] == null ? null : _i(j['prediction_s']),
      weightG = j['weight_g'] == null ? null : _d(j['weight_g']),
      filaments = [
        for (final (i, f) in ((j['filaments'] as List? ?? []).indexed))
          FileFilament.fromJson({'id': i + 1, ...(f as Map<String, dynamic>)}),
      ],
      image = j['image'],
      plates = [
        for (final p in (j['plates'] as List? ?? []))
          ProjectPlate.fromJson({...(p as Map<String, dynamic>), 'image': p['thumbnail'], 'thumbnail': false}),
      ],
      pictures = [for (final x in (j['pictures'] as List? ?? [])) '$x'],
      description = j['description'] ?? '';
}

/// Placa de un proyecto sin laminar (o de un perfil de MakerWorld).
class ProjectPlate {
  final int index;
  final String name;

  /// El .3mf trae miniatura propia de la placa.
  final bool thumbnail;

  /// Foto de la placa en MakerWorld.
  final String? image;
  final int objects;
  final int? predictionS;
  final double? weightG;
  final List<FileFilament> filaments;

  ProjectPlate.fromJson(Map<String, dynamic> j)
    : index = _i(j['index'], 1),
      name = j['name'] ?? '',
      thumbnail = j['thumbnail'] == true,
      image = j['image'],
      objects = _i(j['objects']),
      predictionS = j['prediction_s'] == null ? null : _i(j['prediction_s']),
      weightG = j['weight_g'] == null ? null : _d(j['weight_g']),
      filaments = [
        for (final (i, f) in ((j['filaments'] as List? ?? []).indexed))
          FileFilament.fromJson({'id': i + 1, ...(f as Map<String, dynamic>)}),
      ];

  String get label => name.isNotEmpty ? name : 'Placa $index';
}

class ProjectInfo {
  final List<ProjectPlate> plates;
  final List<FileFilament> filaments;
  final String? printer;

  ProjectInfo.fromJson(Map<String, dynamic> j)
    : plates = [for (final p in (j['project_plates'] as List? ?? [])) ProjectPlate.fromJson(p)],
      filaments = [for (final f in (j['project_filaments'] as List? ?? [])) FileFilament.fromJson(f)],
      printer = j['project_printer'];
}

class CatalogDetail {
  final CatalogItem item;
  final String description;
  final List<String> images;
  final List<CatalogFile> files;
  final String? license;
  final bool downloadable;
  final String? note;

  CatalogDetail.fromJson(Map<String, dynamic> j)
    : item = CatalogItem.fromJson(j),
      description = j['description'] ?? '',
      images = [for (final i in (j['images'] as List? ?? [])) '$i'],
      files = [for (final f in (j['files'] as List? ?? [])) CatalogFile.fromJson(f)],
      license = j['license'],
      downloadable = j['downloadable'] != false,
      note = j['note'];
}

// ---- Historial, estadísticas e inventario ------------------------------------

class PrintFilament {
  final int? tray;
  final String? type;
  final String? color;
  final double? usedG;
  final double? consumedG;
  final double? cost;

  PrintFilament.fromJson(Map<String, dynamic> j)
    : tray = j['tray'] == null ? null : _i(j['tray']),
      type = j['type'],
      color = j['color'],
      usedG = j['used_g'] == null ? null : _d(j['used_g']),
      consumedG = j['consumed_g'] == null ? null : _d(j['consumed_g']),
      cost = j['cost'] == null ? null : _d(j['cost']);
}

class PrintRecord {
  final int id;
  final String printerId;
  final String name;
  final String? libraryId;
  final int plate;
  final String status;
  final DateTime started;
  final DateTime? finished;
  final int progress;
  final double? weightG;
  final double? cost;
  final List<PrintFilament> filaments;
  final String? error;
  final bool snapshot;
  final bool reprintable;
  final bool timelapse;
  final double? energyKwh;
  final double? energyCost;
  final String? rating; // good | bad
  final String? ratingReason;
  final int? projectId;

  PrintRecord.fromJson(Map<String, dynamic> j)
    : id = _i(j['id']),
      printerId = j['printer_id'] ?? '',
      name = j['name'] ?? '',
      libraryId = j['library_id'],
      plate = _i(j['plate'], 1),
      status = j['status'] ?? 'printing',
      started = DateTime.fromMillisecondsSinceEpoch((_d(j['started']) * 1000).round()),
      finished = j['finished'] == null ? null : DateTime.fromMillisecondsSinceEpoch((_d(j['finished']) * 1000).round()),
      progress = _i(j['progress']),
      weightG = j['weight_g'] == null ? null : _d(j['weight_g']),
      cost = j['cost'] == null ? null : _d(j['cost']),
      filaments = [for (final f in (j['filaments'] as List? ?? [])) PrintFilament.fromJson(f)],
      error = j['error'],
      snapshot = j['snapshot'] == true,
      reprintable = j['reprintable'] == true,
      timelapse = j['timelapse'] == true,
      energyKwh = j['energy_kwh'] == null ? null : _d(j['energy_kwh']),
      energyCost = j['energy_cost'] == null ? null : _d(j['energy_cost']),
      rating = j['rating'],
      ratingReason = j['rating_reason'],
      projectId = j['project_id'] == null ? null : _i(j['project_id']);

  bool get needsRating => status == 'done' && rating == null;
  double? get totalCost => cost == null && energyCost == null ? null : (cost ?? 0) + (energyCost ?? 0);

  Duration get duration => (finished ?? DateTime.now()).difference(started);

  String get statusLabel => switch (status) {
    'done' => 'Terminada',
    'failed' => 'Falló',
    'cancelled' => 'Cancelada',
    _ => 'Imprimiendo',
  };
}

class MonthStat {
  final String month;
  final int prints;
  final double grams;
  final double hours;

  MonthStat.fromJson(Map<String, dynamic> j)
    : month = j['month'] ?? '',
      prints = _i(j['prints']),
      grams = _d(j['grams']),
      hours = _d(j['hours']);
}

class PrintStats {
  final int total, done, failed, cancelled;
  final int? successRate;
  final double hours, grams, cost;
  final List<MonthStat> months;
  final Map<String, double> materials;
  final int ratedGood, ratedBad, unrated, recentTotal;
  final int? recentSuccessRate;
  final double energyKwh, energyCost;
  final List<(String, int)> issues;

  PrintStats.fromJson(Map<String, dynamic> j)
    : total = _i(j['total']),
      done = _i(j['done']),
      failed = _i(j['failed']),
      cancelled = _i(j['cancelled']),
      successRate = j['success_rate'] == null ? null : _i(j['success_rate']),
      hours = _d(j['hours']),
      grams = _d(j['grams']),
      cost = _d(j['cost']),
      months = [for (final m in (j['months'] as List? ?? [])) MonthStat.fromJson(m)],
      materials = {for (final e in ((j['materials'] as Map?) ?? {}).entries) '${e.key}': _d(e.value)},
      ratedGood = _i(j['rated_good']),
      ratedBad = _i(j['rated_bad']),
      unrated = _i(j['unrated']),
      recentTotal = _i(j['recent_total']),
      recentSuccessRate = j['recent_success_rate'] == null ? null : _i(j['recent_success_rate']),
      energyKwh = _d(j['energy_kwh']),
      energyCost = _d(j['energy_cost']),
      issues = [for (final x in (j['issues'] as List? ?? [])) ('${x['reason']}', _i(x['count']))];
}

class Spool {
  final int id;
  final String brand;
  final String material;
  final String? color;
  final String colorName;
  final double weightG;
  final double remainingG;
  final double price;
  final String? printerId;
  final int? tray;
  final bool archived;
  final String notes;

  Spool.fromJson(Map<String, dynamic> j)
    : id = _i(j['id']),
      brand = j['brand'] ?? '',
      material = j['material'] ?? 'PLA',
      color = j['color'],
      colorName = j['color_name'] ?? '',
      weightG = _d(j['weight_g']),
      remainingG = _d(j['remaining_g']),
      price = _d(j['price']),
      printerId = j['printer_id'],
      tray = j['tray'] == null ? null : _i(j['tray']),
      archived = j['archived'] == true || j['archived'] == 1,
      notes = j['notes'] ?? '';

  String get label => [brand, material, colorName].where((s) => s.isNotEmpty).join(' ');
  double get fraction => weightG > 0 ? (remainingG / weightG).clamp(0, 1) : 0;
  double get pricePerGram => weightG > 0 ? price / weightG : 0;
}

// ---- Administración de impresoras ---------------------------------------------

class AdminPrinter {
  final String id;
  final String name;
  final String model;
  final String host;
  final String serial;
  final String mode;
  final bool hasAccessCode;
  final bool editable;
  final bool connected;

  AdminPrinter.fromJson(Map<String, dynamic> j)
    : id = j['id'],
      name = j['name'] ?? j['id'],
      model = j['model'] ?? 'A1',
      host = j['host'] ?? '',
      serial = j['serial'] ?? '',
      mode = j['mode'] ?? 'lan',
      hasAccessCode = j['has_access_code'] == true,
      editable = j['editable'] != false,
      connected = j['connected'] == true;
}

class DiscoveredPrinter {
  final String serial;
  final String host;
  final String name;
  final String? model;
  final String? connection;
  final bool added;

  DiscoveredPrinter.fromJson(Map<String, dynamic> j)
    : serial = j['serial'],
      host = j['host'] ?? '',
      name = j['name'] ?? j['serial'],
      model = j['model'],
      connection = j['connection'],
      added = j['added'] == true;
}

// ---- Calificación, proyectos y mantenimiento ------------------------------------

/// Motivos de rechazo (los mismos que el servidor).
const rejectReasons = {
  'adhesion': 'Se despegó de la cama',
  'spaghetti': 'Spaghetti / se soltó',
  'layer_shift': 'Capas corridas',
  'under_extrusion': 'Falta de extrusión',
  'stringing': 'Hilos / stringing',
  'warping': 'Warping',
  'dimensions': 'Medidas incorrectas',
  'surface': 'Mala terminación',
  'other': 'Otro',
};

class Project {
  final int id;
  final String name;
  final String? color;
  final String notes;
  final int? target;
  final bool archived;
  final int prints, ok, failed, printing, queued;
  final double hours, grams, cost, energyKwh, energyCost;
  final int? progress;
  final DateTime? lastPrint;
  final int? thumbnailPrint;

  Project.fromJson(Map<String, dynamic> j)
    : id = _i(j['id']),
      name = j['name'] ?? '',
      color = j['color'],
      notes = j['notes'] ?? '',
      target = j['target'] == null ? null : _i(j['target']),
      archived = j['archived'] == true,
      prints = _i(j['prints']),
      ok = _i(j['ok']),
      failed = _i(j['failed']),
      printing = _i(j['printing']),
      queued = _i(j['queued']),
      hours = _d(j['hours']),
      grams = _d(j['grams']),
      cost = _d(j['cost']),
      energyKwh = _d(j['energy_kwh']),
      energyCost = _d(j['energy_cost']),
      progress = j['progress'] == null ? null : _i(j['progress']),
      lastPrint = j['last_print'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch((_d(j['last_print']) * 1000).round()),
      thumbnailPrint = j['thumbnail_print'] == null ? null : _i(j['thumbnail_print']);
}

class MaintenanceTask {
  final int id;
  final String name;
  final double intervalH;
  final String notes;
  final DateTime lastDone;
  final double hoursSince, hoursLeft, fraction;
  final bool due, soon;

  MaintenanceTask.fromJson(Map<String, dynamic> j)
    : id = _i(j['id']),
      name = j['name'] ?? '',
      intervalH = _d(j['interval_h']),
      notes = j['notes'] ?? '',
      lastDone = DateTime.fromMillisecondsSinceEpoch((_d(j['last_done']) * 1000).round()),
      hoursSince = _d(j['hours_since']),
      hoursLeft = _d(j['hours_left']),
      fraction = _d(j['fraction']),
      due = j['due'] == true,
      soon = j['soon'] == true;
}

class MaintenanceLog {
  final String name;
  final DateTime done;
  final double hours;
  final String notes;

  MaintenanceLog.fromJson(Map<String, dynamic> j)
    : name = j['name'] ?? '',
      done = DateTime.fromMillisecondsSinceEpoch((_d(j['done']) * 1000).round()),
      hours = _d(j['hours']),
      notes = j['notes'] ?? '';
}

class MaintenanceOverview {
  final String printerId;
  final double hours;
  final int due;
  final List<MaintenanceTask> tasks;
  final List<MaintenanceLog> log;

  MaintenanceOverview.fromJson(Map<String, dynamic> j)
    : printerId = j['printer_id'] ?? '',
      hours = _d(j['hours']),
      due = _i(j['due']),
      tasks = [for (final x in (j['tasks'] as List? ?? [])) MaintenanceTask.fromJson(x)],
      log = [for (final x in (j['log'] as List? ?? [])) MaintenanceLog.fromJson(x)];
}

/// Contenido del QR de las etiquetas de carretes.
int? parseSpoolCode(String code) {
  const prefix = 'openbambu:spool:';
  final c = code.trim();
  return c.startsWith(prefix) ? int.tryParse(c.substring(prefix.length)) : null;
}
