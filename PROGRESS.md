# Exam Checker - Progress Log

Last updated: 2026-09-26
Status: CV core + handwriting reader complete and green. Not yet wired into the app.

## Verification status

```
dart analyze lib tool test   -> No issues found!
flutter test                 -> 54 tests, All tests passed!
```

Not yet run: `flutter analyze` (app + platform folders), and no build/run on a device.

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
- `lib/omr/letter_features.dart` - 16x16 centred resample, 3x3 blur, row/col
  mass profiles, symmetry, bbox-relative density, Otsu, blank rejection, hole
  counting.
- `lib/omr/letter_cluster.dart` - deterministic k-means++, nearest-centroid
  classification, review confidence.
- `test/omr/reader_test.dart` - synthetic A/B/C/D, hole topology, scale and
  position invariance, unsupervised recovery, calibration consistency.

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

## Open work, in order

1. `LetterModel.exemplarsByCluster` retrains k-means with a fixed seed instead
   of reusing its own stored centroids, so cluster ids can diverge from the
   trained model. Make it use the centroids it was given.
2. Calibrate `blankInkFraction`, the Otsu fallback, the confidence margin and
   hole connectivity against real handwriting, not synthetic strokes.
3. Build the teacher calibration UI: drag the first row, a single cell, and the
   optional block, then derive and show the lattice for confirmation.
4. Build the review screen: crop every cell, cluster, let the teacher label one
   exemplar per cluster, flag low-confidence cells, and only then compute grades.
5. Replace `MockGradeAdapter`, which fabricates answers from a byte sum, in
   `lib/screens/scan_screen.dart`.
6. Fix answer-key parser bugs: one-line numbered input can lose answers, and
   non-sequential question numbers are silently renumbered.
7. Camera and platform work: `AndroidManifest.xml` declares camera permission
   but no runtime request exists; `ios/Runner/Info.plist` lacks
   `NSCameraUsageDescription`; `scan_screen.dart` imports `dart:io`, which
   breaks web. Decide whether web is actually a target.
8. Drop unused `path_provider` from `pubspec.yaml`.

## Hard blockers and unknowns

- **No ground truth.** There are no correct answers and no labelled handwriting,
  so no real recognition accuracy has been measured and none can be claimed.
  Synthetic tests prove the pipeline is internally consistent, nothing more.
- Not a git repository. If history matters, initialise one before large edits.
- Existing blank-sheet photos in `blank sheet/` are clipped on multiple frame
  edges, so fully automatic corner and lattice detection cannot be validated
  against them. Teacher calibration sidesteps this.
- `blank sheet/Screenshot 2026-09-25 231953.png` is a grade-recording
  spreadsheet, not a blank answer sheet. It only indicates the desired output
  shape: one student row, one column per question.
- `photos/` holds 13 filled-exam JPEGs. Most fill the frame or span its full
  width, so normalised frame coordinates are generally viable.

## Useful commands

```powershell
dart analyze lib tool test     # analyzer over the parts being edited
flutter test                   # full suite, 54 tests
flutter analyze                # full app, not yet clean
```

## Tools

- `tool/probe_grid.dart` - lattice diagnostics.
- `tool/probe_sheet.dart` - sheet detection, rectification, ASCII render, grid.
- `tool/ascii_render.dart` - shared percentile-normalised ASCII renderer.
- `tool/inspect_photos.dart`, morphology and illumination probes.
