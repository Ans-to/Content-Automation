# Content Automation

A **local-first Android app** (Flutter) that keeps your videos on the phone and,
at the exact scheduled time, pings you on WhatsApp and uploads them to **YouTube**
and **Instagram** — no server, no cloud queue, your keys never leave the device.

> Status: **Phase 2 of 6 complete** — project setup, local database, the
> Home / Add / Settings screens, and the background scheduler that fires at the
> exact time with the app closed. Phases 3–6 (WhatsApp agent, YouTube +
> Instagram uploaders, APK packaging docs) follow one by one.

## Build phases

| Phase | Scope | Status |
| ----- | ----- | ------ |
| 1 | Flutter project, SQLite schedule DB, Home / Add / Settings UI, secure key storage | ✅ done |
| 2 | Background scheduler (`flutter_background_service` + `workmanager`), battery-optimisation opt-out, failure handling | ✅ done |
| 3 | WhatsApp Agent integration (outbound alerts + "Status" replies) | ⏳ |
| 4 | YouTube Data API v3 resumable uploader (`googleapis` + `google_sign_in`) | ⏳ |
| 5 | Instagram Graph API uploader via on-device `shelf` server + temporary tunnel | ⏳ |
| 6 | Permissions, release APK workflow, full setup documentation | ⏳ |

## What Phase 1 gives you

* **Home screen** – list of scheduled uploads split into *Upcoming* and *History*,
  live countdowns, platform badges, per-upload status, swipe-to-delete, and a
  banner that nags until API keys are entered.
* **Add / Edit screen** – native video picker, title / description / tags
  (validated against YouTube and Instagram limits), YouTube / Instagram
  multi-select, date + time pickers. The picked video is **moved into the app's
  private storage** so Android cannot purge it before the scheduled time —
  nothing is uploaded at this point.
* **Upload details** – metadata, per-platform status ("YouTube: Pending |
  Instagram: N/A" — the same line the WhatsApp agent will reply with), video
  presence check, activity log, retry / reschedule.
* **Settings screen** – fields for YouTube (Client ID, API key), Instagram
  (App ID, access token, Business Account ID), WhatsApp Agent (endpoint, API key,
  your number) and the ngrok tunnel token. Saved with **`flutter_secure_storage`**
  (AES-GCM, key in the Android Keystore); backups are disabled so secrets can
  never be restored onto another device.
* **SQLite** (`sqflite`) tables `scheduled_uploads` and `upload_events` with an
  incremental migration hook.

## What Phase 2 adds: firing at the exact time, app closed

The scheduler is built around one rule — **never run a 24/7 service, but be
awake at the exact minute**:

1. **Exact alarm → foreground service.** Whenever the schedule changes, the app
   (or the service, or the watchdog) re-plans: the earliest pending upload gets
   an `AlarmManager.setExactAndAllowWhileIdle` wake-up **2 minutes before** its
   time (20 minutes when exact alarms are not permitted). The alarm starts the
   `flutter_background_service` **foreground service** (type `specialUse`, a
   quiet "armed" notification), which counts down with a precise timer.
2. **At the due time** the service claims the row (`scheduled → triggered`,
   atomic, so two isolates can never double-fire), logs *"Time reached"*, shows
   a local notification, calls the WhatsApp agent (*"Time reached. Starting
   upload for [Title]."* — the HTTP client itself lands in Phase 3), checks the
   video is still on the device, and runs the YouTube / Instagram uploaders
   one after the other while writing progress to SQLite. Until Phases 4/5 ship
   their uploaders the placeholder ones **fail with a clear message**, so the
   whole pipeline (trigger → notify → `Failed` + error notification) can be
   exercised today.
3. **Failure handling.** Any platform error → upload `Failed`, `error_message`
   set, per-platform status updated, local "Upload failed" notification and a
   WhatsApp error message. Uploads left `triggered`/`uploading` by a killed
   process are marked `Failed` ("Interrupted…") on the next start.
4. **Self-stopping.** Once nothing is due within the lead window the service
   re-arms the alarm and **stops itself** — zero battery between uploads.
5. **Safety nets.** A `workmanager` periodic **watchdog** (every 15 min) plus a
   one-off task 15 min before each due time verify the service is running when
   it should be; if the OS refuses to start it, the watchdog processes due
   uploads inline. The service is also restarted after reboot
   (`RECEIVE_BOOT_COMPLETED`).
6. **Permissions UX.** *Home → alarm icon* (or *Settings → Background
   execution*) opens a checklist: **Ignore battery optimisations** (native
   `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` dialog), **notifications**
   (Android 13+), **exact alarms** (Android 12+ settings page) and, on
   Xiaomi / Huawei / Oppo / Vivo / Samsung-style ROMs, a shortcut to the vendor
   **auto-start** screen. The Home screen shows a red banner and a dialog after
   scheduling while a critical permission is missing. The same screen shows
   the live scheduler state (sleeping / armed / uploading, next wake-up,
   last watchdog run) and lets you start / stop the service by hand.

All platform-specific code lives in the app-local plugin
`packages/platform_bridge` (Kotlin): alarms, notification channels,
permission checks and OEM settings intents. No third-party notification or
permission packages are needed.

## Project layout

```
lib/
├── main.dart                     # wiring: database → repository → app → background coordinator
├── app.dart                      # MultiProvider + MaterialApp
├── background/
│   ├── background_coordinator.dart   # UI-isolate side: configure service + WorkManager, sync schedule
│   ├── scheduler_service.dart        # foreground-service isolate entry point + tick loop
│   ├── workmanager_tasks.dart        # WorkManager isolate entry point (watchdog / fallback wake-up)
│   ├── upload_engine.dart            # claim → notify → upload → final status (pure Dart)
│   ├── wakeup_planner.dart           # arms exact alarms + WorkManager safety nets
│   ├── scheduler_policy.dart         # when to keep the service alive / when to wake up
│   ├── scheduler_status.dart         # status snapshot shared between isolates (JSON file)
│   └── background_runtime.dart       # per-isolate dependency wiring
├── integrations/
│   ├── whatsapp/whatsapp_agent.dart  # outbound agent interface (HTTP client in Phase 3)
│   └── uploaders/video_uploader.dart # uploader interface + placeholders (Phases 4/5)
├── core/
│   ├── env.dart                  # YOUR_… placeholders (String.fromEnvironment)
│   ├── constants.dart            # limits, db name, folders
│   ├── theme.dart                # Material 3 theme
│   └── utils/formatters.dart     # dates, bytes, countdowns
├── data/
│   ├── database/app_database.dart        # sqflite connection + schema/migrations
│   ├── models/                           # ScheduledUpload, UploadEvent, enums
│   └── repositories/schedule_repository.dart  # interface + SQLite implementation
├── services/
│   ├── secure_key_value_store.dart   # flutter_secure_storage wrapper (+ in-memory fake)
│   ├── settings_service.dart         # AppSettings load/save/seed-from-.env
│   ├── video_file_service.dart       # pick video, keep private copy on device
│   └── local_notifier.dart           # "Time reached" / completed / failed notifications
├── state/                            # ChangeNotifier providers (schedule, settings, background)
└── ui/
    ├── home/                         # list + cards + empty state + scheduler status row
    ├── add_upload/                   # create / edit form
    ├── upload_detail/                # details + activity log
    ├── background/                   # background-execution checklist + live status
    ├── settings/                     # credentials form
    └── widgets/                      # badges, status chips
packages/platform_bridge/             # app-local Android plugin (Kotlin): alarms, permissions, notifications
test/                                 # unit, repository (real SQLite), engine/planner and widget tests
android/                              # Flutter 3.47 template (AGP 9.1, Kotlin 2.4, Gradle 9.3.1)
tool/generate_icons.py                # regenerates launcher icons (no Pillow needed)
```

### Android permissions used so far

| Permission | Why |
| ---------- | --- |
| `INTERNET` | uploads / WhatsApp agent (Phases 3–5) |
| `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_SPECIAL_USE` | the scheduler service that runs at the due time |
| `WAKE_LOCK` | keep the CPU on during the countdown / upload |
| `RECEIVE_BOOT_COMPLETED` | re-arm the schedule after a reboot |
| `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | show the "ignore battery optimisations" dialog |
| `SCHEDULE_EXACT_ALARM` (≤ Android 12L), `USE_EXACT_ALARM` (13+) | exact wake-ups |
| `POST_NOTIFICATIONS` | Android 13+ notifications |

Storage permission is not required: the video is copied into the app's private
folder when it is picked (Phase 1).

### Testing the scheduler on a phone

1. Install the APK, open **Settings → Background execution** and tap **Allow**
   on every item (on Xiaomi/Oppo/Vivo also enable *Auto-start*).
2. Schedule a video 3–4 minutes ahead, press Home and lock the phone.
3. About 2 minutes before the time an "armed" notification appears; at the
   exact minute you get **"Time reached"** followed by **"Upload failed"**
   (placeholders until Phases 4/5) — the upload shows as *Failed* with the
   reason in its activity log, and the service disappears again.

## Running it

Requirements: **Flutter ≥ 3.38 (stable)**, JDK 17, Android SDK 36.

```bash
flutter pub get
flutter run                # on a connected phone / emulator
flutter test               # unit + widget tests
flutter analyze
flutter build apk --release
```

CI (`.github/workflows/ci.yml`) runs analyze, tests and a release APK build on
every push and attaches the APK as the **`content-automation-apk`** artifact of
the workflow run, so you can sideload a preview without a local toolchain.

### API keys

You do **not** need any key to build or run the app. Open **Settings** on the
phone and paste the keys there — they are stored encrypted on the device.

Optionally, developers can pre-seed those fields at build time:

```bash
cp .env.example .env            # .env is git-ignored
# edit .env, replacing the YOUR_… placeholders you want to seed
flutter build apk --release --dart-define-from-file=.env
```

Any value still equal to its `YOUR_…` placeholder is ignored. Seeded values only
fill fields that are still empty on the phone and can be changed in Settings.
Full instructions for obtaining each key (Google Cloud Console, Meta Developer
App, WhatsApp agent, ngrok) arrive with Phase 6.

## Data model

`scheduled_uploads`: `video_path`, `video_name`, `video_size_bytes`, `title`,
`description`, `tags` (comma-separated), `scheduled_time` (epoch ms), `status`
(`scheduled | triggered | uploading | completed | failed`), `platform`
(`youtube | instagram | both`), `youtube_status`, `instagram_status`,
`youtube_video_id`, `instagram_media_id`, `upload_progress`, `error_message`,
`retry_count`, `created_at`, `updated_at`.

`upload_events`: per-upload activity log (`timestamp`, `level`, `message`),
deleted by cascade with its upload.
