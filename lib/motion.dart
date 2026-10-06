import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;

/// Motion is measured on a small grid of averaged brightness cells.
/// The score is the fraction of cells (0..1) that changed more than the
/// noise level, so 0.005 means "0.5% of the picture moved".
const int gridW = 64, gridH = 48;

/// Noise level (0..255) a cell has to change by to count as motion.
double noiseFor(String cameraMode) => cameraMode == 'night' ? 9 : 16;

/// Builds the brightness grid straight from the camera's Y (luma) plane.
Float32List gridFromCameraImage(CameraImage image) {
  final plane = image.planes.first;
  return _gridFromLuma(
      plane.bytes, image.width, image.height, plane.bytesPerRow);
}

Float32List _gridFromLuma(Uint8List y, int width, int height, int rowStride) {
  final sums = Float32List(gridW * gridH);
  final counts = Int32List(gridW * gridH);
  for (int py = 0; py < height; py += 2) {
    final gy = py * gridH ~/ height;
    final row = py * rowStride;
    for (int px = 0; px < width; px += 2) {
      final i = row + px;
      if (i >= y.length) break;
      final cell = gy * gridW + px * gridW ~/ width;
      sums[cell] += y[i];
      counts[cell]++;
    }
  }
  for (int i = 0; i < sums.length; i++) {
    if (counts[i] > 0) sums[i] /= counts[i];
  }
  return sums;
}

/// Builds the brightness grid from a JPEG file (used while recording on
/// phones that cannot stream frames during video capture). Runs in an
/// isolate through `compute`.
Float32List? gridFromJpegFile(String path) {
  final decoded = img.decodeJpg(File(path).readAsBytesSync());
  if (decoded == null) return null;
  final small = img.copyResize(decoded,
      width: gridW, height: gridH, interpolation: img.Interpolation.average);
  final out = Float32List(gridW * gridH);
  for (int y = 0; y < gridH; y++) {
    for (int x = 0; x < gridW; x++) {
      out[y * gridW + x] = small.getPixel(x, y).luminance.toDouble();
    }
  }
  return out;
}

/// Fraction of cells that changed, ignoring overall brightness shifts
/// (auto exposure, lights flickering).
double motionScore(Float32List prev, Float32List cur, double noise) {
  if (prev.length != cur.length) return 0;
  double shift = 0;
  for (int i = 0; i < cur.length; i++) {
    shift += cur[i] - prev[i];
  }
  shift /= cur.length;
  int changed = 0;
  for (int i = 0; i < cur.length; i++) {
    if ((cur[i] - prev[i] - shift).abs() > noise) changed++;
  }
  return changed / cur.length;
}

/// Sensitivity slider position (0..1) to threshold, on a log scale from
/// 0.05% to 20% so the sub-1% range gets most of the slider.
double thresholdFromSlider(double t) => 0.0005 * math.pow(400, t);
double sliderFromThreshold(double thr) =>
    (math.log(thr / 0.0005) / math.log(400)).clamp(0.0, 1.0);

String percent(double v) {
  final p = v * 100;
  if (p < 1) return '${p.toStringAsFixed(2)}%';
  if (p < 10) return '${p.toStringAsFixed(1)}%';
  return '${p.round()}%';
}

/// A copy of one camera frame, safe to send to another isolate.
class FrameSnapshot {
  final int width, height, rotation;
  final List<Uint8List> planes;
  final List<int> rowStrides, pixelStrides;
  FrameSnapshot(this.width, this.height, this.rotation, this.planes,
      this.rowStrides, this.pixelStrides);

  factory FrameSnapshot.of(CameraImage image, int rotation) => FrameSnapshot(
      image.width,
      image.height,
      rotation,
      [for (final p in image.planes) Uint8List.fromList(p.bytes)],
      [for (final p in image.planes) p.bytesPerRow],
      [for (final p in image.planes) p.bytesPerPixel ?? 1]);
}

/// Converts a YUV420 frame to an upright JPEG. Runs in an isolate.
Uint8List frameToJpeg(FrameSnapshot f) {
  final out = img.Image(width: f.width, height: f.height);
  final y = f.planes[0];
  final yRow = f.rowStrides[0];
  final hasColor = f.planes.length >= 3;
  for (int py = 0; py < f.height; py++) {
    for (int px = 0; px < f.width; px++) {
      final yi = py * yRow + px;
      final lum = yi < y.length ? y[yi] : 0;
      if (!hasColor) {
        out.setPixelRgb(px, py, lum, lum, lum);
        continue;
      }
      final uvi = (py >> 1) * f.rowStrides[1] + (px >> 1) * f.pixelStrides[1];
      final u = (uvi < f.planes[1].length ? f.planes[1][uvi] : 128) - 128;
      final v = (uvi < f.planes[2].length ? f.planes[2][uvi] : 128) - 128;
      out.setPixelRgb(
          px,
          py,
          (lum + 1.402 * v).round().clamp(0, 255),
          (lum - 0.344136 * u - 0.714136 * v).round().clamp(0, 255),
          (lum + 1.772 * u).round().clamp(0, 255));
    }
  }
  final upright =
      f.rotation == 0 ? out : img.copyRotate(out, angle: f.rotation);
  return img.encodeJpg(upright, quality: 85);
}
