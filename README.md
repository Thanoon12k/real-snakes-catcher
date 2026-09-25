# Night Guard
Flutter Android overnight motion recorder.

## Run/build on your laptop
Because this package contains the app source, first let Flutter generate the platform boilerplate:
1. Open terminal in the project folder.
2. `flutter create . --platforms=android`
3. IMPORTANT: restore/use the supplied `android/app/src/main/AndroidManifest.xml` if flutter create overwrites it.
4. `flutter pub get`
5. `flutter run` (real phone recommended; camera emulators vary)
6. APK: `flutter build apk --release`
Output: `build/app/outputs/flutter-apk/app-release.apk`

## Behavior
Samples the camera luminance about every 350 ms. If normalized frame difference exceeds sensitivity, it stops analysis, records video (default 60 s), saves it under the app documents/NightGuard folder, then resumes monitoring.

## Important
This v1 detects MOVEMENT, not animal species. It intentionally does not falsely claim that ordinary motion detection can identify a snake/rat. Species AI can be added as a second stage with a trained TFLite detector.

## Manual camera mode
Settings now includes a manual Day/Night selector. Default is Day. There is no automatic switching.
Night mode increases motion-analysis sensitivity for dim scenes; it does not create true night vision, so the camera still needs some visible light.
