import os

# Los tests no descargan nada de internet al iniciar el servidor
os.environ.setdefault("OB_OFFLINE", "1")
