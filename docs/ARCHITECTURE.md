# Architecture

Everything lives in two files: `ViewController.swift` (~2,000 lines) and `mapping.swift`
(~250). That is not a defensible structure and this document does not pretend otherwise —
see [Known structural problems](#known-structural-problems). It is described accurately so
the code can be read.

## Entry point

`AppDelegate` (bottom of `ViewController.swift`) builds the stack programmatically:

```
UINavigationController
└── MainViewController          ← menu
    ├── MappingViewController   ← record a route
    ├── YOLOViewController      ← obstacle detection
    ├── SavedDataViewController ← list saved routes
    └── NavigationViewController ← replay a route
```

`Info.plist` also sets `UIMainStoryboardFile = Main`, so a storyboard is instantiated at
launch and then replaced by the programmatic stack. Both paths exist; the programmatic one
wins.

## The two features

### 1. Route recording and replay

**`MappingViewController`** runs `ARWorldTrackingConfiguration` and, as `ARSessionDelegate`,
integrates camera pose frame by frame. The operator marks waypoints while walking the route.
Each leg is reduced to:

```swift
struct WavepointSummary: Codable {
    let number: Int      // leg index
    let distance: Float  // cm travelled on this leg
    let angle: Float     // degrees turned entering it
}
```

**A route is `[WavepointSummary]` — a dead-reckoning chain of (distance, turn) pairs, not a
set of 3D anchors in AR world space.** This is the single most important design decision in
the app. Consequences:

- Routes are tiny, trivially serializable, and human-readable.
- Replay needs no relocalization against a saved world map, so it works on a fresh session.
- But a route is only valid from its exact starting position and heading, and errors
  accumulate along the chain with no absolute reference to correct them.

**`NavigationViewController`** replays the chain: track distance covered against the current
leg's target, speak `"Walk forward 17.8 feet, then turn left"` via `AVSpeechSynthesizer`,
detect the turn zone on approach, and correct over- and under-turns by comparing live yaw to
the stored angle. Announcements are throttled through `AVSpeechSynthesizerDelegate` so
instructions don't overlap.

**Persistence.** `DataManager` is a singleton writing `[String: [WavepointSummary]]` through
`PropertyListEncoder` into `UserDefaults` under `SavedLocationData`, keyed by a label such as
`"bedroom to kitchen"`. `SavedDataViewController` lists them.

### 2. Obstacle detection

**`YOLOViewController`** owns an `AVCaptureSession` at `.hd1280x720`, receiving frames via
`AVCaptureVideoDataOutputSampleBufferDelegate`.

```
captureOutput(_:didOutput:from:)
   └─ frameCounter gate (frameInterval = 2)   → every 2nd frame, ≤15 fps
      └─ VNCoreMLRequest → yolov8n (.cpuAndGPU)
         └─ processYOLOResults
            ├─ confidence filter (> 0.5)
            ├─ nonMaxSuppression (IoU > 0.5)
            ├─ referenceSizes lookup ─── no entry? DROP the detection
            ├─ estimateDistance → Kalman filter
            ├─ bearing from centroid vs. horizontal FOV
            ├─ render boxes → previewView.image      (the only assignment site)
            └─ speakNextObject → "chair, 1.9 meters, left"
```

There is no `AVCaptureVideoPreviewLayer`. The preview is a `UIImageView` repainted only from
the inference completion handler — which is what makes the frame-rate measurement in
[BENCHMARKS.md](BENCHMARKS.md) valid.

#### Distance estimation

No depth sensor is involved. For a detection whose class appears in the 21-entry
`referenceSizes` table, three independent pinhole estimates are computed and averaged:

```
d_width  = (W_real × f) / (w_box × sensor_w)
d_height = (H_real × f) / (h_box × sensor_h)
d_area   = (A_real × f²) / (A_box × sensor_area)
```

`f = 4.25 mm`, sensor `4.80 × 3.60 mm`, all hard-coded. Averaging three estimates makes the
result robust to one bad box dimension — a partially occluded object with a truncated width
still has a plausible height.

The average feeds a scalar Kalman filter (`q = 0.1`, `r = 0.1`), which is what keeps spoken
distances from jittering between frames. Without it the announcements would be unusable.

**The reference table is the accuracy ceiling.** It holds 21 of COCO's 80 classes, with one
assumed size each. Every `person` is 0.5 × 1.7 m; a child and a tall adult both round to
that. Classes absent from the table are discarded entirely rather than announced without a
distance — so `backpack`, `potted plant`, `bench`, and `door` are invisible to the user even
when the model detects them confidently.

## Known structural problems

Listed because they're real, not to be self-deprecating.

**`ViewController.swift` holds nine types across ~2,000 lines** — five view controllers, a
persistence singleton, two model structs, and the `AppDelegate`. Each should be its own file.

**`mapping.swift` is dead code.** It contains a complete parallel SwiftUI implementation —
`IndoorMappingManager` (`ObservableObject`), `ContentView`, and richer `Waypoint` / `Path` /
`MapData` models that store 3D positions rather than distance-angle pairs. Nothing in
`ViewController.swift` references any of it; there is no `UIHostingController` anywhere. It
is a second, more capable mapping design that was never wired up. It still compiles, so it
still costs build time and misleads readers.

**Routes live in `UserDefaults`**, which is intended for small preferences, not a growing
route library. A JSON file in Application Support would be correct.

**Optics constants are hard-coded** rather than read from `AVCaptureDevice.activeFormat`, so
distances are calibrated for exactly one camera and skew on any other iPhone.

**No tests.** There is no test target. The distance math, NMS, and the Kalman filter are all
pure functions over plain values — the easiest possible things to unit-test — and none are
tested.

**The `Wavepoint` spelling** is a typo for `Waypoint`, propagated through every call site.
Left alone here because renaming it is a mechanical change best done as its own commit.

## Where to start reading

| Interest | Location |
|---|---|
| Detection loop | `ViewController.swift:1959` (`captureOutput`) |
| Distance math | `ViewController.swift:1902` (`estimateDistance`) |
| Reference table | `ViewController.swift:1503` |
| NMS | `ViewController.swift:1861` |
| Route replay | `ViewController.swift:96` (`NavigationViewController`) |
| Route recording | `ViewController.swift:990` (`MappingViewController`) |
| Persistence | `ViewController.swift:13` (`DataManager`) |
