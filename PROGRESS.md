# Exam Checker - Progress Log

Last updated: 2026-09-26
Status: full pipeline wired end to end. Still no measured accuracy, because
there is no ground truth.

## Verification status

```
dart analyze lib tool test   -> No issues found!
flutter analyze              -> No issues found!  (whole app, all platforms)
flutter test                 -> 74 tests, All tests passed!
flutter build web            -> succeeds
```

Not yet done: run on a real device, and any measurement of real accuracy.

## Product rules that must not be lost

- Accuracy outranks speed, convenience and code size. Never fabricate a grade.
- Everything runs on device. Student images must not leave the device.
- The teacher calibrates the answer grid **once per exam**; calibration is then
  reused for every student. Do not block on getting a better blank-sheet photo.
- The answer key is needed for scoring only, not to learn the letter clusters.
- Low confidence must reach the teacher for confirmation, never be auto-graded.
- Short answers are separate from choices and stay teacher-graded.

## Architecture decisions

- A blank printed sheet is not required: cells are **measured** from teacher
  drags rather than detected from a template.
- Geometry is still required to map an image position to a question number.
  Whether options are a row or a column is irrelevant; an ordered list of
  writable cells in reading order is enough.
- Calibration input: one drag across the first answer row, one drag across a
  single cell, plus an optional drag across one whole question block (used only
  to measure vertical row pitch). A row/column switch is only a label.
- Recognition is unsupervised per exam. Cells are cropped, featurised, and
  clustered (k-means++); the teacher labels one exemplar per cluster. This
  sidesteps needing a trained model and adapts to each student's own hand.
- `CellGrouping.single` is for one handwritten letter per question.
  `CellGrouping.options` is for crossed/ticked option cells.
- Automatic grid detection (`grid_detector.dart`) exists as a prototype but is
  not production-ready: it produced plausible output on only 3 of 13 real photos
  (wrong cell counts of 9, 4, 8). Teacher calibration removes this dependency.

## Built and tested

Image / geometry core
- `lib/omr/gray_image.dart` - EXIF-aware decode, planar float luminance in
  `0..255`, sampling, downscaling, connected components, `warp` (inverse map +
  bilinear).
- `lib/omr/geometry.dart` - `Point`, `Homography`, convex hull, quad ordering.
- `lib/omr/preprocess.dart` - separable morphology, `percentileBackground`,
  `InkMap`, `medianFiltered`.
- `lib/omr/mask.dart` - Otsu, connected components.

Bugs already fixed here (do not reintroduce)
- Closing had been wrongly composed as opening.
- Sliding-window min/max comparison was inverted.
- Sliding output carried a padding offset.
- `InkMap.medianFiltered` allocated a line-sized buffer for a square window.
- Dense-form illumination model replaced with local high-percentile
  background: ink `p50` on the sample sheet improved `0.220 -> 0.086`, long
  background runs `327k -> 13k` pixels.
- Removed the `mask.dart -> gray_image.dart` import, which had been a cycle.
- `GrayImage.data` is `0..255`; `InkMap.ink` is about `0..1`.

Handwriting reader (this session)
- `lib/omr/calibration.dart` - `ExamCalibration`, `CellGrouping`, `deriveLattice`.
  Holds the teacher's real `AnswerKey`, so numbering and gaps cannot diverge.
  `validate()` covers only structural faults; `keyProblems` reports gaps.
- `lib/omr/letter_features.dart` - 16x16 centred resample, 3x3 blur, row/col
  mass profiles, symmetry, bbox-relative density, Otsu, blank rejection, hole
  counting. The constructor asserts the vector matches the grid length.
- `lib/omr/letter_cluster.dart` - deterministic k-means++, nearest-centroid
  classification, review confidence, sample-aware `isUsableFor`.
- `lib/omr/omr_service.dart` - the pipeline. `read` crops every calibrated cell
  and clusters them; `grade` compares against the key. Throws
  `OmrReadException` only when the sheet cannot be read at all.
- `test/omr/reader_test.dart` - synthetic A/B/C/D, hole topology, invariance,
  unsupervised recovery, calibration, and answer-key parsing.
- `test/omr/pipeline_test.dart` - end to end on a synthetic page: read, label,
  grade. Covers the safety properties.

App
- `lib/models/answer_key.dart` - `AnswerKeyParser` returns a result plus
  human-readable `problems` instead of guessing.
- `lib/models/grade_result.dart` - `AnswerResult` can represent "no key" and
  "not confirmed". `GradeResult` totals only settled questions.
- `lib/screens/answer_key_screen.dart` - shows the parse and every problem.
- `lib/screens/calibrate_screen.dart` - the three drags, grouping, live overlay.
- `lib/screens/review_screen.dart` - name clusters, confirm cells. No marks here.
- `lib/screens/grade_screen.dart` - marks, plus what was excluded and why.

Fixed while getting the reader tests green
- `countHoles` produced `RangeError ... -6` and `... -17` from padded-border
  indices going negative. Now goes through a bounds-safe `valueAt` accessor.
  Remaining direct `_unpad` call sites were replaced too.
- Option columns are now the **explicit** `optionCount`, never re-measured
  from the dragged row. A row dragged 50% wide used to invent extra columns and
  drift every later cell off its mark. Covered by a regression test.
- `optionCount` used to be inferred from the widest answer-key letter, so a key
  containing no `D` silently shrank the option row. It is now an explicit field.
- Test renderer placed skeletons partly outside the cell, so the letters were
  clipped. Placement now insets the 0..1 skeleton by `pad` within the cell.
- Test pen was thinner than one grid cell, which broke A/B/D outlines during
  downsampling and destroyed the hole count. Pen width is now 5px and the
  reason is documented in the test.
- The descriptor's density feature was cell-relative, so it moved with letter
  size and, at a 60x weight, dominated the distance. It is now bbox-relative.
- The square resample window was anchored at the bounding box's top-left, so a
  narrow letter was padded on one side only and its horizontal projection
  shifted. The window is now centred on the ink.

Known limitation, deliberately not hidden
- The descriptor is not perfectly scale-invariant: a small letter keeps
  proportionally fatter strokes in a fixed grid. Peak normalisation, blurring
  and centring reduce this but leave roughly a 2x separation margin. The
  clustering layer absorbs the residual. The invariance test asserts a 0.7
  ratio with that reasoning in a comment.

Removed, and why it matters that they are gone
- `lib/ai/mock_grade_adapter.dart` fabricated "detected" answers from a byte sum
  of the frame, so wrong answers moved as the teacher shifted the paper. It and
  its `GradeAdapter` interface are deleted. The interface was shaped around a
  cloud vision model, which the on-device requirement rules out anyway.
- `lib/screens/scan_screen.dart` drew red rings and crosses over the live
  preview from those fabricated results. A teacher glancing at it would have
  seen confident wrong marks. Also deleted.
- `AnswerKey.bubbleRect` encoded a hardcoded five-column sheet template, the
  exact assumption calibration replaces.
- `path_provider` was never used. `permission_handler` was added instead,
  because the camera plugin declares the Android permission but never asks.

Correctness fixes made while wiring it up
- `exemplarsByCluster` re-ran k-means with its own seed, so the cluster ids it
  returned were unrelated to the model's own centroids. The teacher could name
  cluster 2 while every cell the app later read as cluster 2 was a different
  letter. It now assigns against the stored centroids, nearest first.
- Several test fixtures paired a 1-element grid with a 4-element vector.
  `LetterFeatures.dimension` is `grid.length + letterFeatureCount`, so every
  model call rejected them and the tests passed while asserting nothing. The
  constructor now asserts the two agree.
- The answer-key parser anchored its number regex to the start of a line, so
  `1. A 2. B 3. C` on one line matched only the first answer and silently
  dropped the rest.
- The parser renumbered any non-sequential key, so a key missing question 3
  became 1:A 2:B 3:D and reported question 4's answer against question 3. It now
  keeps the teacher's numbers and reports the gap. Parsing returns a result
  plus human-readable problems, because guessing here is the one failure the
  app must never produce.
- `grade` emitted one result per cell under option grouping, so a single
  question produced four results and three of them were never confirmed. It now
  emits one result per question, pointing at the marked cell.
- An unlabelled cluster used to be able to block grading on its own. A centroid
  no sample lands on is a phantom with nothing to show the teacher, so
  `isUsableFor` judges only the clusters the samples actually use.
- `GrayImage` had no crop. It now has one that clamps and pads, so a cell
  hanging off the edge reads as blank instead of shifting every later cell.

## Open work, in order

1. Calibrate `blankInkFraction`, the Otsu fallback, the confidence margin and
   hole connectivity against real handwriting, not synthetic strokes.
2. Run it on a real phone. The whole camera path, the preview-to-frame drag
   mapping and the still-capture geometry have never been exercised on hardware.
3. Collect labelled handwriting. Nothing about accuracy can be claimed until
   some real answers are checked against a known key.
4. Decide the web story. It compiles, but the camera plugin and the runtime
   permission request do not work there, so the app is effectively mobile-only.
5. Persist calibrations. `ExamCalibration` is per-exam and should be saved and
   reused, since the teacher only wants to mark the grid once.
6. Export the grade spreadsheet. The original request was a spreadsheet output
   like `Screenshot 2026-09-25 231953.png`; nothing produces one yet.

## Hard blockers and unknowns

- **No ground truth.** There are no correct answers and no labelled handwriting,
  so no real recognition accuracy has been measured and none can be claimed.
  Synthetic tests prove the pipeline is internally consistent, nothing more.
- The confidence margin in `LetterGuess.needsReview` is `0.12`, chosen with no
  data behind it. Until real sheets are measured it is a guess, and it decides
  what reaches the teacher.
- Existing blank-sheet photos in `blank sheet/` are clipped on multiple frame
  edges, so fully automatic corner and lattice detection cannot be validated
  against them. Teacher calibration sidesteps this.
- `blank sheet/Screenshot 2026-09-25 231953.png` is a grade-recording
  spreadsheet, not a blank answer sheet. It only indicates the desired output
  shape: one student row, one column per question.
- `photos/` holds 13 filled-exam JPEGs. Most fill the frame or span its full
  width, so normalised frame coordinates are generally viable. They are
  gitignored and must stay local: they are real students' work.

## Useful commands

```powershell
dart analyze lib tool test     # fast, covers the parts being edited
flutter analyze                # whole app, all platforms
flutter test                   # 74 tests
```

## Tools

- `tool/probe_grid.dart` - lattice diagnostics.
- `tool/probe_sheet.dart` - sheet detection, rectification, ASCII render, grid.
- `tool/ascii_render.dart` - shared percentile-normalised ASCII renderer.
- `tool/inspect_photos.dart`, morphology and illumination probes.
