# 🐍 Snake Catcher

A Flutter Android app that turns an old phone into a motion-triggered camera.
It's built for watching a room at night, for example for a snake or a rat.

## What it does

- **Fine motion sensing.** The picture is split into a 64×48 grid. The
  trigger is the share of the picture that changed, and you can set it from
  **0.05% to 20%**. The slider is logarithmic, so most of it covers the
  range under 1%. The live "Motion" meter shows the current value, so you
  can tune the trigger for your room. Whole-picture brightness changes
  (auto exposure, lights) are ignored.
- **Nothing gets disabled while recording.** The screen shows a blinking
  **● REC m:ss** badge. Settings, recordings, the slider, clip length and
  Stop all keep working, and the app keeps sensing motion during the clip.
- **Clips extend while motion continues.** You pick a clip length (5 s,
  10 s, 30 s, 1, 2, 3 or 5 min). New motion pushes the end time out again,
  up to 5 minutes per clip. If motion is still going after that, a new clip
  and a new alert start.
- **Clips appear in the phone gallery.** They're saved in the album
  **Gallery → Snake Catcher**, and a copy is kept in the app so the bot can
  send it.
- **Telegram alerts.** When motion is detected, the bot sends the **first
  photo** and a message to **every subscriber**. Videos are **never sent
  automatically**. A subscriber taps **🎥 Get full video** under the photo,
  or sends `/video`, and only that person gets the clip. If the clip is
  still recording, it's sent when it finishes.

## Telegram setup

1. In Telegram, open **@BotFather**, send `/newbot`, and copy the **token**.
2. In the app, open **Settings**:
   - turn on **Telegram alerts**
   - paste the **Bot token**
   - choose a secret **Join code**, for example `garden2026`
3. Each person (you included) opens the bot and sends `/start garden2026`.
   They then show up under **Subscribers**, and you can remove them there.
4. Press **Save & send test**.

Bot commands for subscribers:

| Command | What it does |
|---|---|
| `/video` (or any message containing "video" / "فيديو") | full video of the latest motion |
| `/video_20261006_231502` | a specific clip |
| `/list` | last 10 clips |
| `/status` | whether the guard is on or off |
| `/stop` | unsubscribe |

The app listens for bot messages while it is open. Keep it open on the
screen while guarding; the screen stays on automatically.

Telegram bots can't upload files bigger than **50 MB**. Long clips (about
4–5 minutes) may go over that limit. In that case the bot says so, and the
clip is still in the phone gallery.

## Build

```bash
flutter pub get
flutter test
flutter build apk --release
# -> build/app/outputs/flutter-apk/app-release.apk
```

## Notes

- This app detects **movement**. It does not identify what moved.
- Phones that can't stream camera frames while recording (most of them)
  take a silent, flash-off, low-resolution photo about every 1.5 s during
  a recording to keep sensing motion. On very old ("legacy" camera) phones
  this isn't possible, so clips just run for the length you set.
