# DTW-Drift bei Pausen begrenzen (Bugfix, Phase 3)

Status: Design abgestimmt am 2026-08-06, bereit für Implementierungsplan.

## Kontext

Beim ersten realen Test auf dem Telefon (KaraFun-Karaoke: isolierte Lead-Stimme als
Referenz, ~61s; eigener Gesang darüber, ~61s) lieferte die neue Bewertungs-Engine
(Phase 4) unbrauchbare Ergebnisse — extreme Cent-Abweichungen (teils über eine Oktave)
und eine Verfehlt-Quote von bis zu 90%. Systematisches Debugging (Diagnose-Dump der
tatsächlichen Request-Daten, siehe Session-Verlauf) fand die Ursache **nicht** in der
Bewertungs-Engine selbst, sondern in der DTW-Ausrichtung aus Phase 3
(`backend/sync/align.py`), die bereits gemergt und produktiv ist:

Die Differenz `aligned_t - t` (wie weit der Ausrichtungspfad einen Gesangs-Frame
verschiebt) wuchs über die ersten 35 Sekunden der Aufnahme nahezu linear von ~0s auf
**+18,7 Sekunden**. Diese Drift-Phase deckt sich exakt mit einer ~20-Sekunden-Lücke
(t=35–55s) ohne jeden stimmhaften Gesangs-Frame — vermutlich ein Instrumentalteil im
Song, in dem nicht gesungen wurde. Nach der Lücke sprang die Differenz abrupt auf
nahe 0 zurück. Das ist das bekannte Verhalten von unbegrenztem (globalem) DTW: in
Abschnitten mit wenig Onset-Signal (Stille, Pausen) hat der Ausrichtungspfad kaum
Kostendruck, der ihn auf der Diagonale hält, und kann frei "wegwandern", bis ein
markanter Onset auf der anderen Seite ihn wieder einfängt.

Dieses Verhalten wurde von Phase 3s eigener Validierung nie erkannt, weil die einzige
Test-Fixture (`tests/fixtures/generate_fixtures.py`) eine kurze, pausenlose 5-Noten-
Melodie (5 Sekunden, jede Note direkt an die nächste anschließend) ist — es gibt dort
nie eine längere stille Phase, die dieses Fehlverhalten auslösen könnte.

Mit einer derart verschobenen Zeitachse landen in Phase 4s Noten-Zuordnung
(`backend/scoring/notes.py::attribute_sung_frames`, bucketiert nach `aligned_t`)
falsche Gesangsabschnitte in den Zeitfenstern der Zielnoten — daher die absurden
Cent-Werte und die hohe Verfehlt-Quote. Die Bewertungs-Engine rechnet korrekt, bekommt
aber kaputte Eingabedaten. Dies ist also ein **Phase-3-Bug**, der erst durch Phase 4s
neue Anzeige sichtbar wurde.

## Architektur & Fix

`librosa.sequence.dtw` unterstützt bereits eine Sakoe-Chiba-Bandbegrenzung, die bisher
ungenutzt war (`global_constraints` steht per Default auf `False`; `band_rad` (Default
`0.25`) wird ohne `global_constraints=True` komplett ignoriert — beide Parameter
müssen zusammen gesetzt werden). Der Bandradius ist ein Bruchteil der kürzeren der
beiden Kurvenlängen: `radius_frames = int(band_rad * min(len(X), len(Y)))`. Da beide
Kurven mit derselben Frame-Rate (100Hz) abgetastet werden, skaliert die
Band-*Zeit*-Breite automatisch proportional zur Aufnahmedauer — bei einer 60s-Aufnahme
ergäbe `band_rad=0.1` ein Band von ±6 Sekunden um die Diagonale, bei der bestehenden
5s-Testfixture entsprechend nur ±0,5s.

In `backend/sync/align.py::align_curves` wird der bestehende Aufruf

```python
librosa.sequence.dtw(X=x, Y=y, metric="euclidean", subseq=False, backtrack=True)
```

um `global_constraints=True, band_rad=DTW_BAND_RADIUS` ergänzt (neue Konstante in
`backend/config.py`, analog zu den bestehenden DTW-Konstanten `MAX_DURATION_RATIO`
etc.). Reine Backend-Änderung, keine Mobile-/API-Auswirkung — `band_rad` ist intern in
`align_curves()`.

**Bewusste Grenze:** Ein Band verhindert zwar unbegrenztes Wegdriften, kann aber auch
eine *legitime* große Zeitverschiebung (z.B. Nutzer beginnt die eigene Aufnahme
mehrere Sekunden vor dem tatsächlichen Songbeginn) nicht über die Bandbreite hinaus
korrigieren. Das ist ein bekannter, akzeptierter Kompromiss von Banded-DTW — der
gewählte Radius muss großzügig genug für plausible reale Abweichungen sein, aber eng
genug, um pathologisches Driften (wie beobachtet) zu verhindern.

## Kalibrierung des Bandradius

Der exakte Wert (Kandidat: zwischen 0.1 und 0.2) wird gegen zwei Fixtures kalibriert:

1. **Bestehende 5s-Fixture** (`tests/fixtures/generate_fixtures.py`): der bestehende
   End-to-End-Test (`tests/test_e2e_phase3.py`) muss weiterhin die absichtlich
   eingebaute 150ms-zu-früh-Korrektur bei Note 2 nachweisen — reiner
   Regressionsschutz für Phase 3, kein neues Verhalten.
2. **Neue Fixture mit eingebauter Pause**: eine längere synthetische Melodie
   (Größenordnung 20–30s) mit einer eingebauten stillen Lücke von 10–15s in der
   *gesungenen* Spur (nicht in der Zielspur), die den real beobachteten Fall
   nachbildet. Validiert, dass `aligned_t - t` auch während/nach der Pause innerhalb
   einer plausiblen Grenze bleibt (einstellige Sekundenzahl, nicht die beobachteten
   ~19s).

## Tests

- Neue Fixture-Generierungsfunktion (Erweiterung von
  `tests/fixtures/generate_fixtures.py` oder eine neue, dedizierte Datei — wird im
  Implementierungsplan entschieden) für den Pausen-Fall.
- Neuer End-to-End-Test (analog zu `test_e2e_phase3.py`), der gegen die neue Fixture
  prüft, dass die Drift begrenzt bleibt.
- Bestehender `test_e2e_phase3.py` muss unverändert grün bleiben (Regressionsschutz).
- Bestehende `tests/test_sync.py`-Unit-Tests für `align_curves` (synthetische
  Kurzkurven) müssen ebenfalls weiterhin grün bleiben — hier ggf. prüfen, ob eines der
  bestehenden Tests implizit von unbegrenztem DTW abhängt.

## Out of Scope (bewusst nicht Teil dieses Fixes)

- Keine Erkennung/Anzeige von "unsicherer Ausrichtung" in der Mobile-App — mit
  Nutzer abgestimmt, bewusst nur die Drift-Begrenzung selbst, keine UI-Änderung.
- Keine Segmentierung der Aufnahme an Pausen oder andere aufwändigere
  Alignment-Strategien — Banded DTW ist der gewählte, einfachere Ansatz.
- Keine Änderung an `duration_ratio_exceeds_limit`/`MAX_DURATION_RATIO` — dieser Guard
  schützt vor grob unterschiedlichen Gesamtdauern, ist orthogonal zu dieser
  Drift-innerhalb-einer-Aufnahme-Problematik und bleibt unverändert.
