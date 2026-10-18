---
name: my99apps
description: Publish this app to the My99apps board and @my99apps_bot (build the APK, attach it to the app's card), or connect it the first time. Use when the user runs /my99apps, or says publish / connect / release this app.
argument-hint: "[publish | connect | version like 1.2.0]"
---

This repo is one of Thanoon12k's apps on My99apps. The instructions live in the private repo
`Thanoon12k/My99apps`, not here.

1. Attach it with `add_repo` (owner `Thanoon12k`, repo `My99apps`, access `read`) and shallow-clone it
   to `/home/user/my99apps`.
2. Read `/home/user/my99apps/CLAUDE.md`, then follow:
   - `.github/workflows/my-apps.yml` missing here, or the user said "connect" →
     `/home/user/my99apps/.claude/skills/connect-app/SKILL.md` for this repo.
   - Otherwise (no argument, "publish", or a version number) →
     `/home/user/my99apps/.claude/skills/publish-app/SKILL.md` for this repo.
3. Work quietly and report the result in a few lines: app, status on the board, APK file name.
