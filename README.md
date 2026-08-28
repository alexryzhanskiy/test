# Ball Speed

An iOS app that films a ball with the back camera and works out how fast it is
flying, using the known dimensions of the court as its ruler.

Swift 5 / SwiftUI, iOS 17+, no third-party dependencies.

---

## What it does

1. **Calibrate.** Point the phone at the court and tap the four corners of a
   rectangle whose real dimensions are known — a full tennis court, a service
   box, a volleyball court, or a rectangle you measured yourself. Fifteen
   standard courts are built in.
2. **Record.** Hit the record button and take the shot. The camera runs at the
   highest frame rate the device offers (240 fps on recent iPhones), and the same
   frames feed both the video file and the tracker.
3. **Read the speed.** Vision finds the ball's flight path, the app fits a motion
   model to it, and the speed appears on screen — live while recording, and saved
   to history with the clip afterwards.

Every shot is stored with its full fitted path, drawn from above and in profile,
and the whole history exports as CSV.

## How the measurement works

**Calibration → camera pose.** Four tapped corners with known spacing give a
homography between the court plane and the image. Combined with the camera's
intrinsic matrix — read per frame from the capture connection when the device
supplies it, otherwise derived from the format's field of view — that homography
decomposes into the camera's position and orientation relative to the court.
The app reports the recovered camera height and distance, which is a good sanity
check on your taps: if it says the phone is 40 m up, something went wrong.

**Detection.** `VNDetectTrajectoriesRequest` looks for small objects whose motion
across frames fits a parabola. That rules out players, shadows and camera shake
without any colour tuning, and it is the same request Apple built for this class
of sports analysis.

**3D ballistic fit (the primary method).** A single camera cannot place a point in
space — each detection is a ray, not a position. What makes it solvable is the
motion model: a flying ball follows `P(t) = P₀ + V·t + ½·g·t²` with `g` known.
That is six unknowns, and writing the projection constraint in cross-product form
gives two linear equations per detection, so five or more detections
over-determine the system and least squares solves it in closed form. The result
is true 3D speed — vertical motion included — with no assumption about how high
the ball was flying. Launch angle and apex height fall out of the same fit.

**Where the scale comes from, and when the app declines.** Gravity is the only
thing that fixes the ball's distance from the camera: a fast ball far away and a
slow ball nearby project to the same straight line, and only the curvature of the
path tells them apart. Over a window of `T` seconds that curvature is `g·T²/8`
metres — 3 mm over 50 ms, which is a fraction of a pixel and hopelessly buried in
detection noise. So the fit is gated on the curvature actually being measurable
(scaled by `√n` for `n` detections). Below that threshold the app does not report
a confident number built on noise; it falls back and says so.

**2D fallback.** When the 3D fit declines — or camera pose could not be recovered
at all — the app maps detections through a homography for a plane at an assumed
ball height and reports the ground-plane speed, badged `2D` throughout the UI.
This is genuinely approximate: a ball above the assumed plane, seen from a camera
not much higher than it, projects onto the plane further away than it really is,
and the reading inflates accordingly. It is a usable rough figure, not a
measurement.

## Accuracy in practice

Verified against synthetic scenes with exact ground truth (see
`BallSpeedTests`), for a camera 3.2 m up beside a tennis court:

| Case | Result |
|---|---|
| Corner reprojection, exact taps | < 0.01 px |
| Recovered camera position | < 2 cm |
| 30 m/s drive, 0.54 s window, exact detections | speed within 0.1 % |
| Same, with 1 px detection jitter | speed within 2 %, residual 0.7 px |
| 17 m/s lob at 45°, 1 px jitter | speed within 1.1 %, angle within 0.2° |
| One gross outlier mid-path | rejected, speed within 0.1 % |
| 80 ms window, 1 px jitter | 3D fit declines, falls back to 2D |

What dominates real-world error, in order:

1. **Corner tap precision.** This is the ruler. A pixel of error at the far
   baseline is worth more than everything else on this list.
2. **Camera movement after calibration.** Invalidates the geometry entirely.
   Brace or mount the phone.
3. **Window length.** Track the ball for longer and the fit gets dramatically
   better — this is what the gate above is measuring.
4. **Viewing angle.** Film across the flight, not down the line. A ball flying
   straight at the camera barely moves in the image.
5. **Frame rate and light.** More frames means more constraints; short exposures
   keep the ball a compact blob rather than a smear.

## Building

Open `BallSpeed.xcodeproj` in Xcode 16 or later and run on a device. The project
uses file-system-synchronised groups, so files added to `BallSpeed/` are picked
up without touching the project file.

- **Deployment target:** iOS 17.0
- **Device required.** The simulator has no camera; the capture screen will report
  that no usable back camera was found. The test suite runs fine on the simulator
  because every test drives the geometry from synthetic scenes.
- **Signing:** set your own team on the `BallSpeed` target. The bundle identifier
  is `com.ballspeed.app`.

Run the tests with `⌘U`, or:

```sh
xcodebuild test -project BallSpeed.xcodeproj -scheme BallSpeed \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

## Layout

```
BallSpeed/
  App/          App entry point and the tab shell
  Math/         Mat3/Vec3, linear solver, homography, camera intrinsics and pose
  Model/        Court presets, calibration, saved measurements
  Estimation/   Ballistic and planar speed estimators, quality scoring
  Capture/      AVCaptureSession, Vision tracker, asset writer, coordinators
  Storage/      Measurement, calibration and settings persistence
  Views/        Capture, calibration, history, detail and settings screens
BallSpeedTests/ Synthetic-scene geometry and estimator tests
```

The estimators and everything in `Math/` are pure functions over plain values,
which is what makes the accuracy table above testable without a camera.

## Privacy

Everything stays on the device. Clips are written to the app's own Documents
directory, measurements to Application Support, and nothing is uploaded
anywhere — the app makes no network calls at all. Deleting a shot deletes its
clip with it.
