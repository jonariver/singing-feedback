# Claude-generiertes Feedback (Phase 6)

Status: Design abgestimmt am 2026-08-06, bereit für Implementierungsplan.

## Kontext

Phase 4 "Kernpaket" (`backend/scoring/`) berechnet bereits `problem_tags`
(feste Werte: `timingprobleme`, `absinkende_phrasenenden`,
`instabile_lange_toene`, `unsaubere_einsaetze` — ein fünfter Tag,
`haeufiges_hineingleiten`, existiert im Katalog, wird aber noch nicht
erzeugt, da Glide-Erkennung Teil eines zurückgestellten Phase-4-Restpunkts
ist). `backend/exercises/catalog.yaml` existiert bereits mit fünf
kuratierten Einträgen (`id`, `problem`, `technik`, `uebung`) und trägt
selbst den Kommentar, dass Claude bevorzugt aus diesen Einträgen wählen
soll statt Übungen frei zu erfinden. `anthropic` (SDK) und `pyyaml` stehen
bereits in `requirements.txt`, `ANTHROPIC_API_KEY` ist bereits in
`backend/config.py` vorgesehen (zentrale Backend-Konfiguration, kein
Nutzer-Login) — all das wurde für genau diese Phase vorbereitet, aber
`backend/feedback/` ist noch komplett leer.

PLAN.md beschreibt Phase 6 so: kuratierter Übungskatalog (✓ vorhanden),
Prompt-Aufbau mit klarer Trennung Messwert/Interpretation/Vermutung,
serverseitiger Anthropic-API-Aufruf, Parsing zu max. 3 priorisierten
Punkten inkl. Übung und optionaler Wiederholungsaufgabe.

## Architektur / Datenfluss

Neuer, eigenständiger Endpunkt `POST /api/feedback` — nicht Teil von
`/api/score`. `score()` bleibt lokal und schnell; `/api/feedback` ruft
einen externen, langsameren und kostenpflichtigen Dienst auf und bekommt
dafür eine eigene UI-Ladephase. Der Mobile-Client schickt das `ScoreResult`,
das er bereits von `/api/score` erhalten hat, unverändert als Body mit —
keine Neuberechnung, keine Zielkurve/Gesangskurve nötig.

Neues Backend-Modul `backend/feedback/`, im selben Stil wie
`backend/scoring/` (mehrere kleine, fokussierte Dateien plus ein
Orchestrator):
- `catalog.py` — lädt `exercises/catalog.yaml`, liefert die Liste aller
  IDs (für das Tool-Schema) und einen Lookup nach ID.
- `prompt.py` — extrahiert aus einem `ScoreResult` die "Messwerte" für den
  Prompt: die `summary`-Zahlen plus eine kompakte Liste nur der
  auffälligen Noten (verfehlt, `cents_deviation.classification == "red"`,
  oder timing-/stabilitäts-/drift-geflaggt) — unauffällige Noten werden
  nicht mitgeschickt, um Tokens zu sparen und Claude nicht mit
  Nicht-Problemen abzulenken. Baut daraus den eigentlichen Prompt-Text,
  der explizit zwischen den übergebenen Messwerten (Fakten) und der
  Aufgabe an Claude (daraus priorisierte Punkte ableiten, keine
  Vermutungen über nicht gemessene Dinge) trennt.
- `client.py` — kapselt den eigentlichen Anthropic-API-Aufruf per Tool-Use
  (siehe unten), liefert die rohen, noch unvalidierten Punkte zurück.
- `generate.py` — Orchestrator (Analogie zu `scoring/score.py`):
  API-Key-Check, `problem_tags`-Leerfall, Katalog laden, Prompt bauen,
  `client.py` aufrufen, Ergebnis gegen den Katalog validieren/anreichern,
  strukturiertes Ergebnis zurückgeben. Einzige öffentliche Funktion, die
  `routes.py` aufruft.

## Strukturierte Antwort & Übungskatalog

Der Anthropic-Aufruf erzwingt Tool-Use mit einem festen JSON-Schema:
eine Liste von maximal drei Punkten, je mit `problem` (kurzer Text),
`uebung_id` (Enum, beschränkt auf die tatsächlichen Katalog-IDs) und
optional `wiederholungsaufgabe` (Text). Weil `uebung_id` im Schema selbst
als Enum auf die Katalog-IDs beschränkt ist, kann Claude technisch keine
erfundene Übungs-ID zurückgeben — das ersetzt fragiles
Nachträglich-Validieren durch eine Garantie auf API-Ebene.

Trotzdem validiert `generate.py` jeden zurückgegebenen Punkt gegen den
geladenen Katalog (Verteidigung gegen unerwartete/leere Antworten) und
ersetzt `technik`/`uebung` im Ergebnis durch den kuratierten Text aus
`catalog.yaml` — nicht durch Claudes Freitext. Ein Punkt mit unbekannter
oder fehlender `uebung_id` wird verworfen statt einen Platzhalter
anzuzeigen.

## Endpunkt-Details & Fehlerbehandlung

`POST /api/feedback` nimmt `{"score": <ScoreResult>}` (dieselbe Form, die
`/api/score` unter dem Schlüssel `"score"` zurückgibt) und antwortet mit
`{"feedback": {"points": [...]}}` (leere Liste, wenn `problem_tags` leer
war — kein API-Aufruf nötig, wenn nichts Auffälliges vorliegt).

Nutzt denselben `enforce_upload_rate_limit`-Mechanismus wie `/score` & Co.
(gemeinsames 20-Requests/60s-Budget pro Client-IP, kein separates Limit).
Fehlt `ANTHROPIC_API_KEY` (leerer Default), antwortet der Endpunkt mit
HTTP 503 und einer klaren deutschen Fehlermeldung statt eines rohen
SDK-Fehlers. Schlägt der Anthropic-Aufruf fehl (Timeout, Netzwerkfehler,
Antwort ohne verwertbaren Tool-Use-Block), wird das ebenfalls als 503 mit
Fehlermeldung durchgereicht — der Fehler wird nicht verschluckt, aber auch
keine Stacktrace-Details an den Client durchgereicht. Ein `ScoreResult`
mit fehlenden/unerwarteten Feldern (Client schickt z.B. rohe Kurvendaten
statt eines echten `ScoreResult`) führt zu HTTP 400, analog zum
bestehenden Muster bei `/score`.

## Mobile UI

Neuer Abschnitt "5. Feedback" in `home_screen.dart`, nach "4. Bewertung",
sichtbar sobald ein `scoreResult` vorliegt. Button "Feedback anfordern"
(kein Auto-Trigger) startet den Aufruf; während der Anfrage läuft, zeigt
der Button einen Ladezustand (gleiches `_isBusy`-Guard-Muster wie
`PlaybackButton`/`ShareButton` — Doppel-Tap verhindert, `mounted`-Check vor
`setState` nach dem `await`). Bei Erfolg werden bis zu drei Karten
angezeigt (Problem, Technik, Übung, optionale Wiederholungsaufgabe); bei
leerem Ergebnis eine kurze "keine besonderen Probleme erkannt"-Meldung;
bei Fehler eine rote Fehlermeldung im bestehenden Stil
(`Colors.red.shade300`).

## Testing

**Backend:** Unit-Tests für `catalog.py` (Laden, Lookup, unbekannte ID),
`prompt.py` (Messwert-Extraktion aus einem Beispiel-`ScoreResult` —
auffällige vs. unauffällige Noten korrekt gefiltert), `generate.py`
(leere `problem_tags` → leere Punkteliste ohne API-Aufruf; unbekannte
`uebung_id` in einer simulierten Antwort → Punkt verworfen; fehlender
API-Key → `FeedbackUnavailableError`). Der eigentliche `client.py`-Aufruf
wird in Tests mit einem gefakten Anthropic-Client ersetzt — kein echter
API-Call in der Test-Suite. Endpunkt-Test für `/api/feedback` mit
gemocktem `generate_feedback`.

**Mobile:** Widget-Tests für den neuen Feedback-Bereich nach demselben
injizierbaren-Controller-Muster wie `ShareButton`/`PlaybackButton` (Fake
für den API-Aufruf, keine echte HTTP-Anfrage in Tests).

## Out of Scope (bewusst nicht Teil dieses Designs)

- Keine automatische Feedback-Anfrage nach jeder Bewertung — nur auf
  Nutzer-Wunsch per Button.
- Kein separates, engeres Rate-Limit nur für `/feedback` — teilt sich das
  bestehende Budget mit den anderen Endpunkten.
- Keine Erweiterung des Übungskatalogs oder der `problem_tags`-Menge
  (`haeufiges_hineingleiten` bleibt ungenutzt, bis Glide-Erkennung gebaut
  ist).
- Kein Caching/Wiederverwenden von Feedback über mehrere Aufrufe hinweg —
  jeder Button-Tap löst einen neuen Aufruf aus.
