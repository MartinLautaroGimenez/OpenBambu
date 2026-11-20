# Servidor OpenBambu + OrcaSlicer (amd64 y arm64 / Raspberry Pi 4-5)
FROM ubuntu:24.04

ARG ORCA_VERSION=2.5.1
# WITH_SLICER=0 construye una imagen liviana sin laminador
ARG WITH_SLICER=1

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    OB_DATA_DIR=/data \
    LC_ALL=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-venv ca-certificates curl tzdata \
    && if [ "$WITH_SLICER" = "1" ]; then apt-get install -y --no-install-recommends \
        xvfb xauth libgtk-3-0t64 libwebkit2gtk-4.1-0 libsoup-3.0-0 libsecret-1-0 \
        libegl1 libgl1 libglu1-mesa libgles2 libgl1-mesa-dri libosmesa6 \
        libgstreamer1.0-0 libgstreamer-plugins-base1.0-0 gstreamer1.0-plugins-base \
        libfuse2t64 fonts-dejavu-core ; fi \
    && rm -rf /var/lib/apt/lists/*

# OrcaSlicer: AppImage oficial extraído en /opt/orca (no necesita FUSE)
RUN if [ "$WITH_SLICER" = "1" ]; then \
        arch="$(dpkg --print-architecture)"; \
        case "$arch" in amd64) suffix="";; arm64) suffix="_aarch64";; *) echo "Arquitectura no soportada: $arch"; exit 1;; esac; \
        curl -fsSL -o /tmp/orca.AppImage \
          "https://github.com/OrcaSlicer/OrcaSlicer/releases/download/v${ORCA_VERSION}/OrcaSlicer_Linux_AppImage_Ubuntu2404${suffix}_V${ORCA_VERSION}.AppImage" \
        && chmod +x /tmp/orca.AppImage && cd /opt \
        && /tmp/orca.AppImage --appimage-extract >/dev/null \
        && mv squashfs-root orca && rm /tmp/orca.AppImage \
        && echo "$ORCA_VERSION" > /opt/orca/VERSION; \
    fi

WORKDIR /app
COPY pyproject.toml ./
COPY openbambu ./openbambu
RUN python3 -m venv /opt/venv && /opt/venv/bin/pip install --no-cache-dir . && mkdir -p /data
ENV PATH="/opt/venv/bin:$PATH"

VOLUME /data
EXPOSE 8787
HEALTHCHECK --interval=30s --timeout=5s CMD python3 -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:8787/api/health')"
CMD ["openbambu"]
