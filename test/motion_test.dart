import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:snake_catcher/motion.dart';

Float32List grid(double Function(int i) value) =>
    Float32List.fromList(List.generate(gridW * gridH, (i) => value(i)));

void main() {
  test('no change scores zero', () {
    final a = grid((i) => (i % 200).toDouble());
    expect(motionScore(a, a, 16), 0);
  });

  test('a whole-picture brightness shift is ignored', () {
    final a = grid((i) => 100);
    final b = grid((i) => 140);
    expect(motionScore(a, b, 16), 0);
  });

  test('a small moving object is detected below 1%', () {
    final a = grid((i) => 100);
    // 6 of 3072 cells change (~0.2% of the picture).
    final b = grid((i) => i < 6 ? 200 : 100);
    final score = motionScore(a, b, 16);
    expect(score, closeTo(6 / 3072, 1e-9));
    expect(score < 0.01, isTrue);
    expect(score > thresholdFromSlider(0), isTrue);
  });

  test('slider covers 0.05% to 20% on a log scale', () {
    expect(thresholdFromSlider(0), closeTo(0.0005, 1e-12));
    expect(thresholdFromSlider(1), closeTo(0.2, 1e-9));
    expect(sliderFromThreshold(0.01), closeTo(0.5, 0.01));
    expect(percent(0.0025), '0.25%');
  });

  test('YUV frame converts to an upright JPEG', () {
    const w = 8, h = 4;
    final frame = FrameSnapshot(
        w,
        h,
        90,
        [
          Uint8List(w * h)..fillRange(0, w * h, 120),
          Uint8List(w * h ~/ 2)..fillRange(0, w * h ~/ 2, 128),
          Uint8List(w * h ~/ 2)..fillRange(0, w * h ~/ 2, 128),
        ],
        [w, w, w],
        [1, 2, 2]);
    final jpeg = img.decodeJpg(frameToJpeg(frame))!;
    expect(jpeg.width, h);
    expect(jpeg.height, w);
    expect(jpeg.getPixel(1, 1).r, closeTo(120, 4));
  });
}
