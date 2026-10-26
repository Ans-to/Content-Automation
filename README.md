# Content Automation

A **local-first Android app** (Flutter) that keeps your videos on the phone and,
at the exact scheduled time, pings you on WhatsApp and uploads them to **YouTube**
and **Instagram** — no server, no cloud queue, your keys never leave the device.

> Status: **Phase 1 of 6 complete** — project setup, local database, and the
> Home / Add / Settings screens. Phases 2–6 (background scheduler, WhatsApp
> agent, YouTube + Instagram uploaders, APK packaging docs) follow one by one.

## Build phases

| Phase | Scope | Status |
| ----- | ----- | ------ |
| 1 | Flutter project, SQLite schedule DB, Home / Add / Settings UI, secure key storage | ✅ done |
| 2 | Background scheduler (`flutter_background_service` + `workmanager`), battery-optimisation opt-out, failure handling | ⏳ |
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

## Project layout

```
lib/
├── main.dart                     # wiring: database → repository → app
├── app.dart                      # MultiProvider + MaterialApp
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
│   └── video_file_service.dart       # pick video, keep private copy on device
├── state/                            # ChangeNotifier providers
└── ui/
    ├── home/                         # list + cards + empty state
    ├── add_upload/                   # create / edit form
    ├── upload_detail/                # details + activity log
    ├── settings/                     # credentials form
    └── widgets/                      # badges, status chips
test/                                 # unit, repository (real SQLite) and widget tests
android/                              # Flutter 3.47 template (AGP 9.1, Kotlin 2.4, Gradle 9.3.1)
tool/generate_icons.py                # regenerates launcher icons (no Pillow needed)
```

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
