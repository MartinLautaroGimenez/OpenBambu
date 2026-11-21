#!/usr/bin/env bash
# Instalador de OpenBambu para Raspberry Pi (Raspberry Pi OS 64 bits).
#
#   curl -fsSL https://raw.githubusercontent.com/MartinLautaroGimenez/OpenBambu/ccr-4386d231-oij6be/scripts/instalar-rpi.sh | bash
#
# Se puede volver a ejecutar para actualizar: conserva la configuración.
set -euo pipefail

REPO="https://github.com/MartinLautaroGimenez/OpenBambu.git"
BRANCH="${OB_BRANCH:-ccr-4386d231-oij6be}"
DIR="${OB_DIR:-$HOME/openbambu}"

verde() { printf '\033[1;32m%s\033[0m\n' "$*"; }
amarillo() { printf '\033[1;33m%s\033[0m\n' "$*"; }
rojo() { printf '\033[1;31m%s\033[0m\n' "$*"; }

# El script puede venir por "curl | bash": leer respuestas desde la terminal
preguntar() { # preguntar "Texto" variable [valor_por_defecto]
  local prompt="$1" var="$2" def="${3:-}" resp
  if [ -n "$def" ]; then prompt="$prompt [$def]"; fi
  read -r -p "$prompt: " resp </dev/tty
  printf -v "$var" '%s' "${resp:-$def}"
}

verde "== Instalador de OpenBambu =="

arch="$(uname -m)"
if [ "$arch" != "aarch64" ] && [ "$arch" != "x86_64" ]; then
  rojo "Arquitectura $arch: se necesita Raspberry Pi OS de 64 bits (aarch64)."
  rojo "Reinstalá el sistema eligiendo 'Raspberry Pi OS (64-bit)'."
  exit 1
fi

# 1. Docker
if ! command -v docker >/dev/null 2>&1; then
  verde "-> Instalando Docker (tarda unos minutos)…"
  curl -fsSL https://get.docker.com | sudo sh
  sudo usermod -aG docker "$USER" || true
fi
sudo systemctl enable --now docker >/dev/null 2>&1 || true
if ! sudo docker compose version >/dev/null 2>&1; then
  sudo apt-get update -q && sudo apt-get install -y -q docker-compose-plugin
fi
command -v git >/dev/null 2>&1 || sudo apt-get install -y -q git

# 2. Código
if [ -d "$DIR/.git" ]; then
  verde "-> Actualizando OpenBambu en $DIR…"
  git -C "$DIR" fetch -q origin "$BRANCH"
  git -C "$DIR" checkout -q "$BRANCH"
  git -C "$DIR" reset -q --hard "origin/$BRANCH"
else
  verde "-> Descargando OpenBambu en $DIR…"
  git clone -q -b "$BRANCH" "$REPO" "$DIR"
fi
cd "$DIR"
mkdir -p data

# 3. Configuración inicial (solo la primera vez). Las impresoras se agregan
#    desde la app: Impresora → Agregar impresora (detecta las de la red).
if [ ! -f data/config.yaml ]; then
  echo
  preguntar "Topic de ntfy para notificaciones push (vacío = no usar)" topic
  cat > data/config.yaml <<CFG
# Las impresoras se agregan desde la app (se guardan en data/printers.json).
notifications:
  progress_step: 25
  ntfy:
    enabled: $([ -n "$topic" ] && echo true || echo false)
    url: https://ntfy.sh
    topic: "$topic"
CFG
  chmod 600 data/config.yaml
  verde "-> Configuración guardada en $DIR/data/config.yaml"
else
  amarillo "-> Se mantiene la configuración existente (data/config.yaml)"
fi

# 4. Levantar el servidor
verde "-> Construyendo e iniciando el servidor (la primera vez tarda ~5 min)…"
sudo docker compose build --build-arg WEB_BUST="$(date +%s)"
sudo docker compose up -d

echo -n "Esperando al servidor"
for _ in $(seq 1 60); do
  if curl -fs http://127.0.0.1:8787/api/health >/dev/null 2>&1; then break; fi
  echo -n "."; sleep 2
done
echo

token="$(sudo cat data/api_token 2>/dev/null || true)"
ip_pi="$(hostname -I | awk '{print $1}')"

echo
verde "=============================================="
verde " OpenBambu está corriendo"
verde "=============================================="
echo  " En la app ingresá estos datos y después agregá tu impresora"
echo  " (Impresora → Agregar impresora: aparece sola si está en la misma red):"
echo  "   Servidor: $ip_pi:8787"
echo  "   Dashboard web: http://$ip_pi:8787 (desde cualquier navegador)"
echo  "   Token:    ${token:-(ver: sudo docker compose -f $DIR/docker-compose.yml logs | grep -i token)}"
echo
echo  " Logs:        sudo docker compose -f $DIR/docker-compose.yml logs -f"
echo  " Actualizar:  volvé a ejecutar este instalador"
echo  " Editar:      nano $DIR/data/config.yaml && sudo docker compose -f $DIR/docker-compose.yml restart"
