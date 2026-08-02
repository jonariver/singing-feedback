import sys
from pathlib import Path

# Erlaubt "import backend...." und "from fixtures import ..." ohne Paket-Installation.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
