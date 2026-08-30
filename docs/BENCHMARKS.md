# Benchmarks

Every number in this document was measured from a recording of the app running on a
physical device, and every one is reproducible from artifacts. The app contains no
performance instrumentation — no timers, no frame counters, no logging — so nothing here
was read off a counter. It was recovered after the fact.

## Summary

| Metric | Value |
|---|---|
| Sustained end-to-end rate | **14.99 fps modal** (85.4% of frames), 14.74 fps mean |
| Frame period | **66.7 ms** |
| Steady-state window analyzed | 23.3 s |
| Device | iPhone 14 Pro, iOS 17.6.1 |
| Model | `yolov8n.mlmodel`, 12,726,860 bytes (12.73 MB), 640×640 input |
| Compute units | `.cpuAndGPU` — Neural Engine explicitly excluded |

**What "end-to-end" covers:** Core ML inference, IoU non-max suppression, the 21-entry
reference-table distance estimate, Kalman smoothing, bearing math, and the full
`CIImage → CGImage → UIGraphicsImageRenderer` redraw with boxes and labels composited.

## Why screen refresh rate is a valid proxy for inference rate

This is the load-bearing assumption, so it is worth stating precisely.

The app has **no `AVCaptureVideoPreviewLayer`** — verifiable with
`grep -c AVCaptureVideoPreviewLayer SixthSense/ViewController.swift`, which returns `0`.
There is no live camera layer rendering independently of inference.

Instead, `previewView.image` is assigned at exactly **one** site in the entire file —
`ViewController.swift:1752` — and that site sits inside `processYOLOResults(request:error:)`,
which is only ever reached from the `VNCoreMLRequest` completion handler.

Therefore **the preview repaints if and only if an inference completes.** The rate at which
the screen changes *is* the rate at which inferences complete. This would not be true of a
typical camera app, where the preview layer runs at capture rate regardless of inference.

## Method

Source recording: `ScreenRecording_10-16-2024 02-11-01_1.MP4` — a 34.12 s screen capture of
the "YOLO Object Detection" screen, 886×1920 at 60000/1001 fps (59.94 fps), taken
2024-10-16.

1. Crop to the preview region and downscale to 96×108 grayscale. Downscaling suppresses
   codec noise while preserving whole-frame change.
2. Compute mean absolute difference between consecutive recorder frames.
3. The differences are **cleanly bimodal** — a "no repaint" cluster at mean 0.001 and a
   "repaint" cluster at mean 3.402, three orders of magnitude apart. There is no ambiguous
   middle, so the threshold placed between them is not a tuning choice.
4. Discard the startup period. The first 10.63 s of the clip is a black screen before the
   capture session delivers frames. **Including it drags the mean to ~11 fps** and is the
   single easiest way to get this measurement wrong.
5. Measure intervals between repaint events across the remaining window.

## Result

343 intervals over a 23.3 s steady-state window:

| Interval (recorder frames) | Implied rate | Count | Share |
|---|---|---|---|
| **4** | **14.99 fps** | **293** | **85.4%** |
| 3 | 19.98 fps | 23 | 6.7% |
| 5 | 11.99 fps | 22 | 6.4% |
| 7–9 | 6.7–8.6 fps | 4 | 1.2% |

The distribution is sharply peaked at exactly 4 recorder frames. The 3- and 5-frame
intervals are adjacent-bin jitter that largely cancels; the handful of 7–9 frame intervals
are genuine dropped frames and are why the mean (14.74) sits slightly below the mode (14.99).

## The caveat that matters

**14.99 fps is the app's design cap, not the model's ceiling.**

`ViewController.swift:1484` sets `frameInterval = 2`, and the capture callback at line 1959
gates on it:

```swift
frameCounter += 1
guard frameCounter == frameInterval else { return }
```

The session preset is `.hd1280x720` at 30 fps, so inference runs on every second frame —
a hard ceiling of 15 fps regardless of how fast the model is.

What this measurement proves is that **the entire pipeline fits inside the 66.7 ms budget
without falling behind** — 85.4% of frames land exactly on the cap. It does **not** measure
raw model latency, which is strictly lower and unmeasured. A claim like "yolov8n runs at
15 fps on an iPhone 14 Pro" would be the wrong conclusion to draw.

Headroom is real but unquantified: `.cpuAndGPU` leaves the A16's Neural Engine unused, and
`frameInterval = 1` is untested.

## Reproducing

```bash
ffmpeg -i "ScreenRecording_10-16-2024 02-11-01_1.MP4" \
       -vf "crop=886:1000:0:400,scale=96:108,format=gray" -f rawvideo gray.raw

python3 - gray.raw <<'EOF'
import numpy as np, sys
W, H, FPS = 96, 108, 60000/1001
f = np.fromfile(sys.argv[1], np.uint8)
n = f.size // (W*H)
f = f[:n*W*H].reshape(n, H, W).astype(np.float32)
d = np.abs(np.diff(f, axis=0)).mean(axis=(1, 2))
lo, hi = d[d < np.median(d)], d[d >= np.median(d)]
chg = np.flatnonzero(d > (lo.mean() + hi.mean()) / 2)
ss = chg[chg >= 638]                       # drop the 10.63 s black startup
iv = np.diff(ss)
v, c = np.unique(iv, return_counts=True)
print(f"mode {FPS/v[c.argmax()]:.2f} fps  ({c.max()}/{len(iv)} intervals)")
print(f"mean {len(ss)-1/((ss[-1]-ss[0])/FPS):.2f} fps")
EOF
```

The recording is not committed to this repository (145 MB). It is retained locally.

## Device identification

The iPhone 14 Pro attribution is evidence-based, not assumed:

- `IMG_8266.MOV`, recorded on the same device the same week, carries
  `com.apple.quicktime.model` metadata naming the device.
- The screen recording's 886×1920 geometry corresponds to the iPhone 14 Pro's 1179×2556
  panel at the capture scale factor.

## Not measured

Stated so nothing here is mistaken for a stronger claim than it is:

- Raw Core ML inference latency in isolation
- Neural Engine performance (`.all` compute units)
- Thermal behavior over sustained use
- Memory footprint
- Battery draw — relevant for an assistive app expected to run for a whole outing
- Detection accuracy (mAP) on any benchmark, and distance-estimate error against ground truth
