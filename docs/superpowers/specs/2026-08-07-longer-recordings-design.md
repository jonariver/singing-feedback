# Design: Aufnahmen bis 300s + Kürzungs-Warnung

**Datum:** 2026-08-07
**Status:** Genehmigt, bereit für Plan

## Kontext

Live-Test auf dem Handy (echte 1:56-Aufnahme) zeigte: `MAX_AUDIO_SECONDS = 90`
(`backend/config.py`) schneidet jede Aufnahme (Gesang **und** Referenz) still auf 90s
ab — `backend/audio_io.py::load_audio_signal` macht einen harten Numpy-Array-Schnitt,
ohne Rückmeldung an Client oder Nutzer. `PLAN.md`s ursprüngliche Annahme ("kurze
Ausschnitte 20-60s zuerst") reicht nicht mehr für einen ganzen Song.

**Entdeckt während der Untersuchung, kein Implementierungsdetail, sondern eine echte
Grenze:** `librosa.sequence.dtw` legt trotz Sakoe-Chiba-Band (`band_rad`) immer eine
**volle dichte** Kosten-/Distanzmatrix an (`librosa/sequence.py:437`,
`D = np.ones(C.shape + ...) * np.inf`) — keine sparse/gebänderte Speicherstruktur. Bei
der bisherigen 100Hz-Hüllkurven-Frame-Rate würde ein 300s-Paar (~30.000×30.000-Matrix)
ca. 14-20 GB RAM belegen. Deshalb ist diese Spec **zwei** Änderungen: das Limit selbst,
und eine niedrigere, von der Pitch-Kurven-Rate entkoppelte Frame-Rate speziell für die
DTW-Hüllkurve.

## Architektur

### 1. Config-Limits (`backend/config.py`)

```python
MAX_AUDIO_SECONDS = 300  # war 90
MAX_AUDIO_UPLOAD_BYTES = 80 * 1024 * 1024  # war 40MB; 300s Stereo-44.1kHz-WAV ~53MB
MAX_SCORE_CURVE_FRAMES = 35000  # war 20000; muss 300s * 100Hz = 30000 abdecken
DTW_FRAME_RATE_HZ = 25.0  # neu
```

Bei 25Hz: 300s → 7500 Hüllkurven-Frames statt 30000 → DTW-Matrizen ~16x kleiner
(~1,3 GB statt ~14-20 GB). Pitch-Kurven (`target_curve`, `sung_curve`, fürs Chart/Scoring)
bleiben unverändert bei 100Hz — nur die DTW-Eingangs-Hüllkurve wird gröber.

### 2. DTW-Frame-Rate-Entkopplung (`backend/sync/align.py`, `backend/api/routes.py`)

`routes.py`s `/api/sync/align` ruft `onset_envelope_from_signal`/
`onset_envelope_from_midi_track` künftig mit `frame_rate_hz=DTW_FRAME_RATE_HZ` auf
(bisher implizit 100.0, identisch zur Kurven-Rate). Die Funktionen selbst ändern sich
nicht — sie sind schon parametrisiert.

`align_curves()` bekommt einen neuen Parameter `envelope_frame_rate_hz: float = 100.0`
(Default hält bestehende Aufrufer ohne den Parameter unverändert). Der DTW-Warping-Pfad
`wp` liefert Indexpaare `(i, j)` **in die Hüllkurve**, nicht mehr direkt verwendbar als
Kurven-Index (bisher galt implizit `envelope[i] == curve[i]`, weil beide dieselbe
Frame-Rate hatten). Neue Logik:

1. Für jedes `(i, j)` aus `wp`: `target_time = i / envelope_frame_rate_hz`,
   `sung_time = j / envelope_frame_rate_hz`. Bei mehreren `i` für dasselbe `j` gewinnt
   (wie bisher) der chronologisch letzte Treffer.
2. Daraus eine nach `sung_time` aufsteigend sortierte Liste von Ankerpunkten
   `(sung_time, target_time)` bauen (eindeutige `j`-Werte, aufsteigend).
3. Für jeden `sung_curve`-Frame (bei 100Hz, also feiner als die Anker) wird `aligned_t`
   **linear zwischen den beiden umschließenden Ankerpunkten interpoliert** — nicht mehr
   stufenweise wie bisher. Vor dem ersten Anker: `aligned_t = None` (wie bisher). Nach
   dem letzten Anker: der letzte Anker-Zielwert wird konstant fortgeschrieben (wie
   bisher das "last_known"-Verhalten).

**Bewusste Nebenwirkung, die über die reine 300s-Ermöglichung hinausgeht:** Da
`envelope_frame_rate_hz` standardmäßig weiterhin 100 ist, ändert sich für **alle**
Aufrufe (auch kurze, auch mit dem alten Default) das Verhalten von einer
Treppenfunktion zu echter linearer Interpolation — eine Genauigkeits-Verbesserung, kein
Nebeneffekt, der eigens abgeschaltet werden muss. Bei `envelope_frame_rate_hz == 100`
und `target_curve`/`sung_curve`, die mit `step = 1/100`-Zeitstempeln gebaut sind, ist
`i / envelope_frame_rate_hz` numerisch nahezu identisch zum bisherigen
`target_curve[i]["t"]` (nur Rundungsdifferenzen in der 3. Nachkommastelle) — die
bestehenden `test_sync.py`-Toleranz-Assertions (`abs(aligned_t - erwartet) < X`) sollten
unverändert bestehen bleiben, müssen aber im Zuge der Implementierung verifiziert
werden.

### 3. Kürzungs-Warnung (nur `/api/audio/analyze`)

Da `analyzeAudio()`/`analyzeReference()` (Mobile) immer **vor** `align()` läuft und
dieselben Bytes mit demselben `MAX_AUDIO_SECONDS` dekodiert — kürzt `analyze` nicht,
kürzt `align` auch nicht (deterministisch, gleiche Eingabe, gleiche Konstante). Ein
Signal an einer Stelle genügt, `align`/`SyncApi` bleiben unverändert.

- `load_audio_signal()` gibt zusätzlich die **ungekürzte** Originaldauer zurück (Tupel
  oder kleines Ergebnis-Objekt statt nur des Arrays — Implementierungsdetail für den
  Plan).
- `/api/audio/analyze` liefert `{"curve": [...], "original_duration_seconds": 116.2,
  "truncated": true}` — Felder immer vorhanden, `truncated=false` im Normalfall.
- Mobile: `AudioApi.analyzeAudio()` liefert künftig `AudioAnalysisResult{curve,
  truncated, originalDurationSeconds}` statt nackter `List<SungPoint>`. Beide
  Aufrufstellen (`analyzeAudio()`, `analyzeReference()` in `session_state.dart`)
  werden angepasst.
- `SessionState` bekommt `audioTruncated`/`referenceTruncated: bool` (Default `false`).
- `StatusBanner` bekommt einen neuen Zustand `LoadStatus.warning` (gelb/orange), der
  zusätzlich zur bestehenden ok-Nachricht angezeigt wird (ergänzt, nicht ersetzt), z. B.
  „Aufnahme analysiert (auf 5:00 gekürzt, Original war 6:20)" — `originalDurationSeconds`
  ist immer die längere, ungekürzte Zahl; `MAX_AUDIO_SECONDS` (5:00) ist die kürzere,
  tatsächlich verwendete. Exakter Wortlaut ist Implementierungsdetail.

## Testing

- `backend/sync/align.py`: `align_curves` mit `envelope_frame_rate_hz` ungleich der
  Kurven-Rate — interpoliert korrekt zwischen zwei Ankerpunkten (bekannter
  Zwischenwert bei bekannter Zeit); Frames vor dem ersten Anker `None`; Frames nach dem
  letzten Anker halten den letzten Wert; ein einzelner Anker (Grenzfall) crasht nicht.
  Bestehende `test_sync.py`-Tests laufen weiter (mit Default-Parameter, keine
  Änderung nötig, nur Verifikation).
- `backend/audio_io.py`: `load_audio_signal` liefert die korrekte **ungekürzte**
  Originaldauer, wenn tatsächlich gekürzt wurde, und `truncated=false`/Originaldauer
  == tatsächliche Dauer, wenn nicht.
- Endpoint-Verhalten (`truncated`-Feld in der `/api/audio/analyze`-Antwort) über
  Funktionsaufruf getestet (Projekt-Konvention, kein `TestClient`, siehe
  `docs/superpowers/specs/2026-08-07-track-scoring-and-preview-design.md`s
  entsprechende Entscheidung).
- Mobile: `AudioAnalysisResult`-Parsing (`fromJson`), `SessionState`-Truncation-Felder,
  `StatusBanner`-Warnzustand (neuer visueller Zustand, Text sichtbar).

## Out of Scope (bewusst nicht Teil dieser Spec)

- Kein Truncation-Signal für MIDI-Zielspuren (die sind nicht durch `MAX_AUDIO_SECONDS`
  gedeckelt, sondern durch `duration_ratio_exceeds_limit` gegen die Aufnahmedauer
  geschützt — unverändertes, bestehendes Verhalten).
- Kein Truncation-Signal auf `/api/sync/align` selbst — redundant, siehe Begründung
  oben.
- Keine UI zum manuellen Ändern des 300s-Limits durch den Nutzer — fester Server-Wert.
- Pausen/Atemstellen (Phase 4-Rest, letzter verbleibender Punkt) — unabhängige, spätere
  Spec.
