"""Startet den lokalen Server und oeffnet automatisch den Standardbrowser.

Bindet bewusst nur an 127.0.0.1 (nicht 0.0.0.0): die App soll ausschliesslich
lokal erreichbar sein, nicht im Netzwerk (siehe Datenschutz-Leitplanke).
"""

import threading
import time
import webbrowser

import uvicorn

HOST = "127.0.0.1"
PORT = 8000


def _open_browser_when_ready() -> None:
    time.sleep(1.2)
    webbrowser.open(f"http://{HOST}:{PORT}/")


if __name__ == "__main__":
    threading.Thread(target=_open_browser_when_ready, daemon=True).start()
    uvicorn.run("backend.main:app", host=HOST, port=PORT, reload=False)
