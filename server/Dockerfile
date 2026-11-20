FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 OB_DATA_DIR=/data
WORKDIR /app
COPY pyproject.toml ./
COPY openbambu ./openbambu
RUN pip install --no-cache-dir . && mkdir -p /data

VOLUME /data
EXPOSE 8787
HEALTHCHECK --interval=30s --timeout=5s CMD python -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:8787/api/health')"
CMD ["openbambu"]
