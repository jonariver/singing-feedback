# Einklappbare Abschnitte Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wrap each of `home_screen.dart`'s 5 numbered sections in a Flutter
`ExpansionTile` so the user can independently collapse/expand each one.

**Architecture:** Purely structural restructuring of `mobile/lib/screens/home_screen.dart`
— each section's existing `Text('N. Titel', ...)` header becomes an `ExpansionTile.title`,
and everything else that section already renders (unchanged) moves into
`ExpansionTile.children`. `initiallyExpanded: true` on all five tiles. No new
`SessionState` field, no persistence — Flutter's `ExpansionTile` manages its own
expand/collapse state locally.

**Tech Stack:** Dart/Flutter (`mobile/lib/screens`, `mobile/test`), `flutter_test`.

## Global Constraints

- No new `SessionState` field or method — this is a pure widget-tree restructuring.
- No persistence of expand/collapse state across app restarts (explicit spec decision).
- All five `ExpansionTile`s start with `initiallyExpanded: true`.
- The existing `const Divider(height: 32)` separators between sections stay, placed
  between the `ExpansionTile`s (i.e. as their own top-level `ListView` children, not
  inside any tile's `children`).
- Every existing conditional branch inside each section (e.g. the `if
  (session.referenceSource == ReferenceSource.midi) ... else ...` split in section 1,
  the `if (session.audioSectionEnabled) ...` transpose control, `if (session.scoreResult
  != null) ...`) must be preserved exactly as-is, just relocated into the tile's
  `children` list — no behavior change to what renders when.

---

### Task 1: Wrap all 5 sections in ExpansionTile + smoke test

**Files:**
- Modify: `mobile/lib/screens/home_screen.dart`
- Create: `mobile/test/home_screen_test.dart`

**Interfaces:**
- Consumes: nothing new — `HomeScreen` already reads `SessionState` via
  `context.watch<SessionState>()`; this task only changes how its own widget tree is
  structured, not what it reads.
- Produces: no new public interface — this is the final task of a 1-task plan.

- [ ] **Step 1: Read the current file to confirm exact content**

Read `mobile/lib/screens/home_screen.dart` in full before editing — other features may
have shifted exact line numbers since this plan was written. The structure to expect
(as of plan-writing time) is a single `ListView` with these top-level children in order:
`Text('1. Zielmelodie', ...)` header + its section-1 content + (conditional transpose
control) + `Divider`, then `Text('2. Gesangsaufnahme', ...)` header + its content +
`Divider`, then `Text('3. Tonhöhen-Vergleich', ...)` + content + `Divider`, then
`Text('4. Bewertung', ...)` + content + `Divider`, then `Text('5. Feedback', ...)` +
content (no trailing `Divider`).

- [ ] **Step 2: Write the failing test**

Create `mobile/test/home_screen_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:singing_feedback_mobile/api/api_client.dart';
import 'package:singing_feedback_mobile/api/audio_api.dart';
import 'package:singing_feedback_mobile/api/feedback_api.dart';
import 'package:singing_feedback_mobile/api/midi_api.dart';
import 'package:singing_feedback_mobile/api/score_api.dart';
import 'package:singing_feedback_mobile/api/sync_api.dart';
import 'package:singing_feedback_mobile/screens/home_screen.dart';
import 'package:singing_feedback_mobile/state/session_state.dart';
import 'package:singing_feedback_mobile/widgets/pitch_chart.dart';

SessionState _buildSession() {
  // Ein echter ApiClient reicht hier aus - dieser Test loest keinen Tap auf einen
  // netzwerkausloesenden Button aus (Aufnahme/Upload/Bewertung/Feedback), nur
  // Header-Taps zum Ein-/Ausklappen, also wird nie tatsaechlich ein HTTP-Aufruf
  // gefeuert. Gleiches Prinzip wie die injizierbaren *Api-Klassen ueberall sonst in
  // diesem Projekt, nur ohne Fake, weil hier keine Antwort gebraucht wird.
  final client = ApiClient();
  return SessionState(
    midiApi: MidiApi(client),
    audioApi: AudioApi(client),
    syncApi: SyncApi(client),
    scoreApi: ScoreApi(client),
    feedbackApi: FeedbackApi(client),
  );
}

Widget _wrap(SessionState session) {
  return ChangeNotifierProvider<SessionState>.value(
    value: session,
    child: const MaterialApp(home: HomeScreen()),
  );
}

void main() {
  testWidgets('alle fuenf Abschnitts-Titel sind initial sichtbar', (tester) async {
    await tester.pumpWidget(_wrap(_buildSession()));

    expect(find.text('1. Zielmelodie'), findsOneWidget);
    expect(find.text('2. Gesangsaufnahme'), findsOneWidget);
    expect(find.text('3. Tonhöhen-Vergleich'), findsOneWidget);
    expect(find.text('4. Bewertung'), findsOneWidget);
    expect(find.text('5. Feedback'), findsOneWidget);
  });

  testWidgets('Abschnitt 3 ist initial aufgeklappt (PitchChart sichtbar)', (tester) async {
    await tester.pumpWidget(_wrap(_buildSession()));

    expect(find.byType(PitchChart), findsOneWidget);
  });

  testWidgets(
      'Tippen auf den Titel von Abschnitt 3 klappt ihn zu - PitchChart verschwindet',
      (tester) async {
    await tester.pumpWidget(_wrap(_buildSession()));
    expect(find.byType(PitchChart), findsOneWidget);

    await tester.tap(find.text('3. Tonhöhen-Vergleich'));
    await tester.pumpAndSettle();

    expect(find.byType(PitchChart), findsNothing);
  });

  testWidgets('erneutes Tippen klappt Abschnitt 3 wieder auf - PitchChart erscheint wieder',
      (tester) async {
    await tester.pumpWidget(_wrap(_buildSession()));

    await tester.tap(find.text('3. Tonhöhen-Vergleich'));
    await tester.pumpAndSettle();
    expect(find.byType(PitchChart), findsNothing);

    await tester.tap(find.text('3. Tonhöhen-Vergleich'));
    await tester.pumpAndSettle();
    expect(find.byType(PitchChart), findsOneWidget);
  });
}
```

`PitchChart` is used as the collapse/expand probe for section 3 specifically because
it's the one widget type in this screen that appears in exactly one section — unlike
`RecordingControl`/`PlaybackButton`/`PlaybackSeekbar`, which each appear in BOTH section
1 and section 2 and would make `findsOneWidget`/`findsNothing` assertions ambiguous
about which section actually collapsed.

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd mobile && flutter test test/home_screen_test.dart`
Expected: FAIL — either a compile error (if any imported symbol doesn't exist yet, unlikely
since all imports are pre-existing project files) or, more likely, all four tests PASS
already for the "visible" assertions but the collapse/expand tests FAIL because tapping
the title text currently does nothing (no `ExpansionTile` exists yet, so
`find.byType(PitchChart)` stays `findsOneWidget` after the tap instead of becoming
`findsNothing`).

- [ ] **Step 4: Wrap each section in an ExpansionTile**

In `mobile/lib/screens/home_screen.dart`, restructure the `ListView`'s children. Replace
the entire body of the `ListView(padding: ..., children: [...])` with the same content,
but with each section's `Text('N. Titel', ...)` header converted into an
`ExpansionTile.title`, and everything from immediately after that header up to (but not
including) the following `Divider` moved into that tile's `children:` list. Concretely,
transform this pattern (shown for section 1, apply the same transformation to all five
sections using each section's own existing content — do NOT alter what any section
renders, only how it's wrapped):

Before:
```dart
Text('1. Zielmelodie', style: Theme.of(context).textTheme.titleMedium),
const SizedBox(height: 8),
if (session.referenceSource == ReferenceSource.midi) ...[
  // ... MIDI content ...
] else ...[
  // ... recording content ...
],
if (session.audioSectionEnabled) ...[
  const SizedBox(height: 8),
  TransposeControl(
    value: session.displayedTranspose,
    onChanged: session.setTranspose,
  ),
],
const Divider(height: 32),
```

After:
```dart
ExpansionTile(
  title: Text('1. Zielmelodie', style: Theme.of(context).textTheme.titleMedium),
  initiallyExpanded: true,
  children: [
    const SizedBox(height: 8),
    if (session.referenceSource == ReferenceSource.midi) ...[
      // ... MIDI content, unveraendert ...
    ] else ...[
      // ... recording content, unveraendert ...
    ],
    if (session.audioSectionEnabled) ...[
      const SizedBox(height: 8),
      TransposeControl(
        value: session.displayedTranspose,
        onChanged: session.setTranspose,
      ),
    ],
  ],
),
const Divider(height: 32),
```

Apply the identical transformation to sections 2, 3, 4, and 5 — each section's own
existing content (unchanged) becomes that section's `ExpansionTile.children`, each
section's own `Text('N. Titel', ...)` becomes that section's `ExpansionTile.title`, each
`initiallyExpanded: true`. Section 5 (`5. Feedback`) currently has no trailing `Divider`
after it (it's the last item in the `ListView`) — keep it that way, don't add one.

Every `ExpansionTile`'s `children` list must be a `List<Widget>`, so any content that was
previously a single non-list expression (e.g. a lone `StatusBanner(...)` line) becomes
one list element; content that was already inside a spread (`...[ ... ]`) keeps that
spread syntax, just nested one level deeper inside the tile's `children:` list — e.g.
`if (session.referenceSource == ReferenceSource.midi) ...[ ... ]` remains a spread
element directly inside `children: [ ... ]`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd mobile && flutter test test/home_screen_test.dart`
Expected: all 4 tests PASS.

- [ ] **Step 6: Run the full mobile test suite for regressions**

Run: `cd mobile && flutter test`
Expected: all tests PASS. (No other file references `home_screen.dart`'s internal
structure directly — this restructuring is self-contained to that one file plus the new
test file.)

- [ ] **Step 7: Commit**

```bash
git add mobile/lib/screens/home_screen.dart mobile/test/home_screen_test.dart
git commit -m "feat: make home screen sections collapsible via ExpansionTile"
```

---

## Self-Review Notes

- **Spec coverage:** the spec's single architectural requirement (wrap all 5 sections in
  `ExpansionTile`, `initiallyExpanded: true`, no new state, no persistence, dividers kept
  between tiles) is fully covered by Task 1's Step 4. The spec's testing section (initial
  visibility of all 5 titles, tap-to-collapse hides a section-specific child widget) is
  covered by Task 1's Step 2 tests. Out-of-scope items (auto-collapse-by-progress,
  persistence, the other two features from the original multi-feature request) are
  untouched.
- **Type consistency:** N/A — single task, no cross-task interfaces to check.
- **No placeholders:** every step has literal code, not descriptions. The "before/after"
  transformation in Step 4 is shown fully for section 1 and described precisely enough
  (apply identically to sections 2-5, each section's own pre-existing content) that no
  section's content needs to be invented or guessed — the implementer reads the real
  current file (Step 1) to get each section's exact existing content before moving it.
