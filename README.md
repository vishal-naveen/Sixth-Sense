<div align="center">

<img src="docs/media/logo.png" alt="Sixth Sense" width="320">

**An iOS navigation aid for blind and low-vision users.**
Indoor waypoint routing and spoken obstacle alerts, running entirely on-device.

[![Demo](https://img.shields.io/badge/▶_Watch_the_demo-3%20min-red)](https://www.youtube.com/watch?v=SR_WHzHOZHI)
[![Platform](https://img.shields.io/badge/platform-iOS%2015.4+-lightgrey)](#building)
[![Swift](https://img.shields.io/badge/Swift-5.0-orange)](#building)
[![Model](https://img.shields.io/badge/YOLOv8n-Core%20ML-blue)](#object-detection-and-distance)

</div>

---

## What it does

Two features, both designed to be used without looking at the screen.

**Directional assistance.** A sighted helper walks a route once and records it as a
sequence of AR waypoints. A blind user can then replay that route and hear turn-by-turn
instructions — *"walk forward 17.8 feet, then turn left"* — with live correction when they
over- or under-turn.

**Obstacle detection.** The camera runs object detection continuously and speaks what is
ahead, how far away it is, and which side it is on — *"chair, 1.9 meters, left."*

<div align="center">

| Obstacle detection | The same, near-dark | Recording a route | Turn-by-turn replay |
|:---:|:---:|:---:|:---:|
| <img src="docs/media/detection-indoor.jpg" width="200"> | <img src="docs/media/detection-dark.jpg" width="200"> | <img src="docs/media/mapping.jpg" width="200"> | <img src="docs/media/navigation.jpg" width="200"> |

*Unretouched captures, October 2024, iPhone 14 Pro.* Detection reports class, confidence,
distance, and bearing — `chair: 91% · 4.12 m · −12.30° (Left)` — and still works in a room
with the lights off, where the app can drive the torch. The recording screen's log shows the
route model directly: *waypoint ended · distance travelled 113.58 cm · angle moved 86.26° left
· next waypoint · reset to 0.*

> These frames come from the **October 2024 build**, the same one in the demo video — not from
> the source published here. See [Honest status](#honest-status).

</div>

## Demo

[**▶ Watch the 3-minute demo**](https://www.youtube.com/watch?v=SR_WHzHOZHI) — includes
blindfolded walkthroughs of both features, one indoors on a recorded route and one
navigating around real obstacles.

> **The demo shows an earlier build than the code in this repository.** See
> [Honest status](#honest-status) before drawing conclusions from it. That build had a
> voice-command layer and a wider object table; its source did not survive. What is
> published here is the last source I still have, from February 2025.

## Measured performance

| | |
|---|---|
| **15.0 fps sustained** | end-to-end, 66.7 ms per frame, over a 23.3 s steady-state window |
| **iPhone 14 Pro, iOS 17.6.1** | the device the measurement was taken on |
| **12.73 MB** | on-device Core ML model, 640×640 input |
| **CPU + GPU** | `computeUnits = .cpuAndGPU` — the Neural Engine is explicitly not used |

**15 fps is the app's design cap, not the model's ceiling.** `frameInterval = 2` gates
inference to every second frame of a 30 fps capture. What the measurement proves is that
the *whole* pipeline — inference, NMS, distance estimation, and the `CIImage → CGImage →
UIGraphics` redraw — fits inside the 66.7 ms budget without dropping frames. It is not raw
model latency.

The methodology, including why the on-screen refresh rate is a valid proxy for the
inference rate, is written up in [`docs/BENCHMARKS.md`](docs/BENCHMARKS.md). It is
reproducible from the screen recordings.

## How it works

### Routes and waypoints

`ARWorldTrackingConfiguration` supplies 6-DoF pose. Rather than store 3D anchors, the app
reduces each leg of a route to a `(distance, turn angle)` pair:

```swift
struct WavepointSummary: Codable {
    let number: Int      // leg index
    let distance: Float  // cm travelled
    let angle: Float     // degrees turned
}
```

A route is a dead-reckoning chain of these. That keeps routes tiny and means replay needs
no relocalization against a saved world map — but a route is only valid from its exact
starting position, and error accumulates along the chain. It's a deliberate trade, and
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) covers what it costs.

During replay the app tracks distance against the current leg, speaks the instruction
through `AVSpeechSynthesizer`, and corrects over- and under-turns by comparing live yaw to
the stored angle.

### Object detection and distance

`yolov8n` runs through `VNCoreMLRequest`. Detections are filtered at 0.5 confidence and
passed through IoU non-max suppression at 0.5.

Distance uses **monocular pinhole geometry, not a depth sensor.** For each detection the
app looks up the object's real-world size in a 21-entry reference table, then computes
three independent estimates — from bounding-box width, from height, and from area:

```
distance_width  = (real_width  × f) / (box_width  × sensor_width)
distance_height = (real_height × f) / (box_height × sensor_height)
distance_area   = (real_area   × f²) / (box_area  × sensor_area)
```

with `f = 4.25 mm` and a 4.80 × 3.60 mm sensor. The three are averaged and smoothed by a
1-D Kalman filter (`q = 0.1`, `r = 0.1`) so spoken distances don't jitter frame to frame.
Bearing comes from the box centroid against a horizontal FOV derived from the same optics.

This is a real trade-off, not an oversight: it needs no LiDAR, so it runs on any iPhone
with a camera. The cost is accuracy — see [Limitations](#limitations).

Full breakdown in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Building

Requires Xcode 15+, iOS 15.4+, and a **physical device** — ARKit and the camera do not
work in the Simulator.

```bash
git clone https://github.com/vishal-naveen/Sixth-Sense.git
cd Sixth-Sense
open SixthSense.xcodeproj
```

Set your own signing team, then run. The Core ML model is committed, so no extra
download step.

## Honest status

This section exists because a portfolio repository that only lists strengths isn't worth
reading.

**The published source is not the build in the demo video.** The October 2024 demo shows
voice commands ("initialize bedroom to kitchen") and announces objects — backpack, potted
plant — that are absent from this source's reference table. That build's source is lost.
This repository publishes the February 2025 source, which is the last one I have.

**Consequently, there is no voice control in this code.** `Info.plist` still declares
`NSSpeechRecognitionUsageDescription` and `NSMicrophoneUsageDescription` from the earlier
build, but no `SFSpeechRecognizer` is wired up. The app *speaks*; it does not listen.
Rebuilding this layer is [issue #1](../../issues/1).

**The model is stock, not fine-tuned.** `yolov8n.mlmodel` is an unmodified Ultralytics
export trained on COCO. I did not train or fine-tune it. It knows COCO's 80 classes.

## Limitations

- **Only 21 of 80 classes report distance.** Detections without a reference-size entry are
  dropped rather than announced. Common obstacles — `backpack`, `potted plant`, `bench`,
  `door` — fall through this gap. [Issue #3](../../issues/3).
- **Distance degrades badly at range.** The estimator is calibrated by object size, so
  error grows with distance and with any object whose real dimensions differ from the table.
  It is dependable at the 1–2 m range that matters for obstacle avoidance; the double-digit
  readings visible in the outdoor screenshots above should be treated as ordinal, not metric.
- **Fixed optics constants.** `f` and the sensor dimensions are hard-coded for one camera
  rather than read from `AVCaptureDevice`, so distances skew on other iPhone models.
  [Issue #4](../../issues/4).
- **No accessibility labels.** Ironically for an assistive app, the UI itself has no
  `accessibilityLabel` annotations and is not VoiceOver-navigable. [Issue #2](../../issues/2).
- **Drift.** Routes are dead-reckoned, so error accumulates along a route with no absolute
  reference to correct it, and a route is only valid from its exact starting position.
- **`mapping.swift` is dead code.** It holds a complete parallel SwiftUI mapping
  implementation that nothing references — a second, more capable design that was never
  wired up. It still compiles. [Issue #5](../../issues/5).
- **No tests.** The distance math, NMS, and Kalman filter are pure functions over plain
  values — the easiest things in the app to test — and none are tested.

## Background

Built 2023–2025 while at Middleton High School, Tampa. Third place, Congressional App
Challenge 2024. I consulted the City of Tampa's ADA coordinator on accessibility
requirements, and validated the navigation loop myself, blindfolded — both features in the
demo are recorded that way.

This repository was reorganized and documented in August 2026; the commit dates reflect
when the repository was cleaned up, not when the app was written. The original October 2024
upload is preserved as the first commit in this history.

## Credits

- The project scaffold began from **Brian Voong's** ([Let's Build That App](https://www.letsbuildthatapp.com))
  `SmartCameraLBTA` Core ML tutorial project. The camera pipeline grew out of that starting point.
- Object detection uses **[Ultralytics YOLOv8](https://github.com/ultralytics/ultralytics)**.

## License

The application source in this repository is released under the [MIT License](LICENSE).

**The bundled model is not.** `SixthSense/yolov8n.mlmodel` is an Ultralytics YOLOv8n export
and carries **AGPL-3.0**, as recorded in its own metadata. MIT covers my code only; the
model retains its own terms; see [NOTICE](NOTICE). Distributing a closed-source app built on these
weights would require a commercial license from Ultralytics — worth knowing before shipping this.
