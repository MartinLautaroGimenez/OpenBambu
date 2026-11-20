"""Capacidades por modelo de impresora y tablas de referencia."""

from __future__ import annotations

from dataclasses import asdict, dataclass


@dataclass(frozen=True)
class Capabilities:
    max_nozzle_temp: int
    max_bed_temp: int
    has_aux_fan: bool
    has_chamber_fan: bool
    has_chamber_temp: bool
    has_enclosure: bool
    # "tcp_jpeg" = A1/P1 (puerto 6000) | "rtsp" = X1 (puerto 322, no soportado aún)
    camera: str
    bed_size: tuple[int, int, int]

    def to_dict(self) -> dict:
        return asdict(self)


CAPABILITIES: dict[str, Capabilities] = {
    "A1": Capabilities(300, 100, False, False, False, False, "tcp_jpeg", (256, 256, 256)),
    "A1MINI": Capabilities(300, 80, False, False, False, False, "tcp_jpeg", (180, 180, 180)),
    "P1P": Capabilities(300, 100, True, False, False, False, "tcp_jpeg", (256, 256, 256)),
    "P1S": Capabilities(300, 100, True, True, False, True, "tcp_jpeg", (256, 256, 256)),
    "X1C": Capabilities(300, 110, True, True, True, True, "rtsp", (256, 256, 256)),
    "X1E": Capabilities(320, 120, True, True, True, True, "rtsp", (256, 256, 256)),
}

# Niveles de velocidad (spd_lvl)
SPEED_LEVELS = {1: "Silencioso", 2: "Estándar", 3: "Sport", 4: "Ludicrous"}

# Etapa actual de impresión (stg_cur)
STAGES = {
    -1: "Inactiva",
    0: "Imprimiendo",
    1: "Nivelación automática de cama",
    2: "Precalentando cama",
    3: "Barrido de vibración XY",
    4: "Cambiando filamento",
    5: "Pausa M400",
    6: "Pausada: se terminó el filamento",
    7: "Calentando boquilla",
    8: "Calibrando extrusión",
    9: "Escaneando superficie de la cama",
    10: "Inspeccionando primera capa",
    11: "Identificando tipo de placa",
    12: "Calibrando Micro Lidar",
    13: "Haciendo home del cabezal",
    14: "Limpiando la punta de la boquilla",
    15: "Verificando temperatura del extrusor",
    16: "Pausada por el usuario",
    17: "Pausada: tapa frontal caída",
    18: "Calibrando Micro Lidar",
    19: "Calibrando flujo de extrusión",
    20: "Pausada: falla de temperatura de boquilla",
    21: "Pausada: falla de temperatura de cama",
    22: "Descargando filamento",
    23: "Pausa por salto de pasos",
    24: "Cargando filamento",
    25: "Calibración de ruido de motores",
    26: "Pausada: se perdió el AMS",
    27: "Pausada: ventilador del heatbreak lento",
    28: "Pausada: error de temperatura de cámara",
    29: "Enfriando cámara",
    30: "Pausada por G-code del usuario",
    31: "Prueba de ruido de motores",
    32: "Pausada: boquilla cubierta de filamento",
    33: "Pausada: error del cortador",
    34: "Pausada: error en primera capa",
    35: "Pausada: boquilla obstruida",
    255: "Inactiva",
}

# Perfiles de filamento genéricos de Bambu (tray_info_idx)
GENERIC_FILAMENTS = {
    "PLA": ("GFL99", 190, 240),
    "PLA-CF": ("GFL98", 210, 240),
    "PETG": ("GFG99", 220, 260),
    "ABS": ("GFB99", 240, 270),
    "ASA": ("GFB98", 240, 270),
    "TPU": ("GFU99", 200, 250),
    "PA": ("GFN99", 260, 290),
    "PC": ("GFC99", 260, 280),
    "PVA": ("GFS99", 190, 240),
}

GCODE_STATES = {
    "IDLE": "Inactiva",
    "PREPARE": "Preparando",
    "RUNNING": "Imprimiendo",
    "PAUSE": "Pausada",
    "FINISH": "Terminada",
    "FAILED": "Fallida",
    "SLICING": "Laminando",
    "INIT": "Iniciando",
    "OFFLINE": "Desconectada",
}
