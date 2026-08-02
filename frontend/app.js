// Phase-1-Frontend: nur Upload -> Spurwahl -> Aufnahme-Upload -> rohe Kurven-Gegenueberstellung.
// Keine DTW-Ausrichtung, keine Farbkodierung, kein Claude-Feedback (kommt in spaeteren Phasen).

const state = {
  midiSessionId: null,
  selectedTrackIndex: null,
  targetCurve: null, // [{t, hz, midi_note}]
  sungCurve: null,   // [{t, hz, voiced, confidence}]
};

const midiInput = document.getElementById("midi-input");
const midiStatus = document.getElementById("midi-status");
const trackList = document.getElementById("track-list");
const audioSection = document.getElementById("audio-section");
const audioHint = document.getElementById("audio-hint");
const audioInput = document.getElementById("audio-input");
const audioStatus = document.getElementById("audio-status");
const canvas = document.getElementById("pitch-canvas");
const ctx = canvas.getContext("2d");

function setStatus(el, message, kind) {
  el.textContent = message;
  el.className = "status" + (kind ? " " + kind : "");
}

midiInput.addEventListener("change", async () => {
  const file = midiInput.files[0];
  if (!file) return;

  setStatus(midiStatus, "Lade und analysiere MIDI-Datei…", "");
  trackList.innerHTML = "";
  audioSectionReset();

  const formData = new FormData();
  formData.append("file", file);

  try {
    const res = await fetch("/api/midi/upload", { method: "POST", body: formData });
    const data = await res.json();
    if (!res.ok) throw new Error(data.detail || "Unbekannter Fehler beim MIDI-Upload.");

    state.midiSessionId = data.session_id;
    if (!data.has_plausible_vocal_track) {
      setStatus(
        midiStatus,
        "Warnung: Diese MIDI-Datei enthält wahrscheinlich keine eigene Gesangsmelodie. " +
        "Bitte prüfe die Spuren unten sorgfältig oder besorge eine passendere Datei.",
        "error"
      );
    } else {
      setStatus(midiStatus, `${data.candidates.length} Spur(en) gefunden. Bitte eine auswählen.`, "ok");
    }
    renderTrackList(data.candidates);
  } catch (err) {
    setStatus(midiStatus, "Fehler: " + err.message, "error");
  }
});

function renderTrackList(candidates) {
  trackList.innerHTML = "";
  for (const c of candidates) {
    const card = document.createElement("div");
    card.className = "track-card";
    card.dataset.index = c.index;

    const info = document.createElement("div");
    const range = (c.pitch_min_name && c.pitch_max_name) ? `${c.pitch_min_name}–${c.pitch_max_name}` : "–";
    info.innerHTML = `
      <strong>${escapeHtml(c.name)}</strong>
      <div class="meta">
        Noten: ${c.note_count} · Tonumfang: ${range} · Dauer: ${c.duration_seconds}s ·
        ${c.monophonic ? "monophon" : "polyphon"} ${c.name_hint_match ? "· Namenstreffer" : ""}
      </div>
      ${c.warnings.length ? `<div class="warnings">${c.warnings.map(escapeHtml).join(" ")}</div>` : ""}
    `;

    const button = document.createElement("button");
    button.textContent = "Auswählen & anhören";
    button.disabled = c.note_count === 0;
    button.addEventListener("click", () => selectTrack(c.index, card));

    card.appendChild(info);
    card.appendChild(button);
    trackList.appendChild(card);
  }
}

async function selectTrack(index, cardEl) {
  document.querySelectorAll(".track-card").forEach((el) => el.classList.remove("selected"));
  cardEl.classList.add("selected");
  state.selectedTrackIndex = index;

  setStatus(midiStatus, "Lade Zielmelodie der gewählten Spur…", "");
  try {
    const res = await fetch(`/api/midi/${state.midiSessionId}/track-curve?track_index=${index}&transpose=0`);
    const data = await res.json();
    if (!res.ok) throw new Error(data.detail || "Spur konnte nicht geladen werden.");

    state.targetCurve = data.curve;
    setStatus(midiStatus, "Spur ausgewählt. Jetzt eine Gesangsaufnahme hochladen.", "ok");
    audioSection.classList.remove("disabled");
    audioHint.style.display = "none";
    audioInput.disabled = false;
    drawChart();
  } catch (err) {
    setStatus(midiStatus, "Fehler: " + err.message, "error");
  }
}

function audioSectionReset() {
  state.sungCurve = null;
  audioSection.classList.add("disabled");
  audioHint.style.display = "";
  audioInput.disabled = true;
  audioInput.value = "";
  setStatus(audioStatus, "", "");
}

audioInput.addEventListener("change", async () => {
  const file = audioInput.files[0];
  if (!file) return;

  setStatus(audioStatus, "Analysiere Tonhöhe der Aufnahme…", "");
  const formData = new FormData();
  formData.append("file", file);

  try {
    const res = await fetch("/api/audio/analyze", { method: "POST", body: formData });
    const data = await res.json();
    if (!res.ok) throw new Error(data.detail || "Unbekannter Fehler bei der Tonhöhenerkennung.");

    state.sungCurve = data.curve;
    setStatus(audioStatus, "Analyse fertig.", "ok");
    drawChart();
  } catch (err) {
    setStatus(audioStatus, "Fehler: " + err.message, "error");
  }
});

// --- Chart ---

function hzToMidiNote(hz) {
  return 69 + 12 * Math.log2(hz / 440);
}

function drawChart() {
  const target = state.targetCurve || [];
  const sung = state.sungCurve || [];

  ctx.clearRect(0, 0, canvas.width, canvas.height);

  const targetNotes = target.filter((p) => p.hz).map((p) => hzToMidiNote(p.hz));
  const sungNotes = sung.filter((p) => p.hz).map((p) => hzToMidiNote(p.hz));
  const allNotes = targetNotes.concat(sungNotes);

  if (allNotes.length === 0) {
    ctx.fillStyle = "#9ca3af";
    ctx.font = "14px system-ui";
    ctx.fillText("Noch keine Daten. Bitte MIDI-Spur und Aufnahme hochladen.", 20, canvas.height / 2);
    return;
  }

  const maxTime = Math.max(
    target.length ? target[target.length - 1].t : 0,
    sung.length ? sung[sung.length - 1].t : 0,
    1
  );
  const minNote = Math.floor(Math.min(...allNotes)) - 2;
  const maxNote = Math.ceil(Math.max(...allNotes)) + 2;

  const padding = { left: 46, right: 12, top: 12, bottom: 28 };
  const plotWidth = canvas.width - padding.left - padding.right;
  const plotHeight = canvas.height - padding.top - padding.bottom;

  const xForT = (t) => padding.left + (t / maxTime) * plotWidth;
  const yForNote = (n) => padding.top + (1 - (n - minNote) / (maxNote - minNote)) * plotHeight;

  // Gitternetz: Oktavlinien (alle 12 Halbtoene) mit Notennamen.
  ctx.strokeStyle = "#9ca3af33";
  ctx.fillStyle = "#9ca3af";
  ctx.font = "11px system-ui";
  for (let n = Math.ceil(minNote / 12) * 12; n <= maxNote; n += 12) {
    const y = yForNote(n);
    ctx.beginPath();
    ctx.moveTo(padding.left, y);
    ctx.lineTo(canvas.width - padding.right, y);
    ctx.stroke();
    ctx.fillText(midiNoteName(n), 4, y + 4);
  }

  // Zeitachse (Sekunden).
  const secondStep = maxTime > 30 ? 5 : 2;
  for (let s = 0; s <= maxTime; s += secondStep) {
    const x = xForT(s);
    ctx.fillText(`${s}s`, x - 8, canvas.height - 8);
  }

  drawCurve(target.map((p) => ({ t: p.t, hz: p.hz })), xForT, yForNote, "#2563eb");
  drawCurve(sung.map((p) => ({ t: p.t, hz: p.voiced ? p.hz : null })), xForT, yForNote, "#ea580c");
}

function drawCurve(points, xForT, yForNote, color) {
  ctx.strokeStyle = color;
  ctx.lineWidth = 2;
  ctx.beginPath();
  let drawing = false;
  for (const p of points) {
    if (p.hz === null || p.hz === undefined) {
      drawing = false;
      continue;
    }
    const x = xForT(p.t);
    const y = yForNote(hzToMidiNote(p.hz));
    if (!drawing) {
      ctx.moveTo(x, y);
      drawing = true;
    } else {
      ctx.lineTo(x, y);
    }
  }
  ctx.stroke();
}

const NOTE_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"];
function midiNoteName(n) {
  const name = NOTE_NAMES[((n % 12) + 12) % 12];
  const octave = Math.floor(n / 12) - 1;
  return `${name}${octave}`;
}

function escapeHtml(str) {
  const div = document.createElement("div");
  div.textContent = str;
  return div.innerHTML;
}
