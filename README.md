# Content Automation

A **local-first Android app** (Flutter) that keeps your videos on the phone and,
at the exact scheduled time, pings you on WhatsApp and uploads them to **YouTube**
and **Instagram** — no server, no cloud queue, your keys never leave the device.

> Status: **Phase 4 of 6 complete** — project setup, local database, the
> Home / Add / Settings screens, the background scheduler that fires at the
> exact time with the app closed, the WhatsApp agent integration (alerts +
> "Status" replies) and the YouTube uploader (Google Sign-In + resumable
> Data API v3 upload with progress and resume-after-kill). Phases 5–6
> (Instagram uploader, APK packaging docs) follow one by one.

## Build phases

| Phase | Scope | Status |
| ----- | ----- | ------ |
| 1 | Flutter project, SQLite schedule DB, Home / Add / Settings UI, secure key storage | ✅ done |
| 2 | Background scheduler (`flutter_background_service` + `workmanager`), battery-optimisation opt-out, failure handling | ✅ done |
| 3 | WhatsApp Agent integration (outbound alerts + "Status" replies) | ✅ done |
| 4 | YouTube Data API v3 resumable uploader (`googleapis` + `google_sign_in`) | ✅ done |
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
   upload for [Title]."*), checks the
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

## What Phase 3 adds: the WhatsApp agent

The app never talks to WhatsApp directly — it talks to **your WhatsApp Agent**,
a small HTTP bridge you host (a Node/Baileys script, a Twilio/360dialog/Meta
Cloud API wrapper, n8n, …). Everything is configured in **Settings → WhatsApp
Agent API**: *Agent endpoint URL*, *API key* (optional), *Your WhatsApp number*
and an optional *Inbox URL*. A **Send test message** button verifies the setup.

### Outbound: what the app sends

| When | Message | `event` |
| ---- | ------- | ------- |
| Scheduled time reached | `Time reached. Starting upload for [Video Title].` | `upload_started` |
| Any platform failed | `Upload failed for [Title].` + `YouTube: … \| Instagram: …` + `Reason: …` | `upload_failed` |
| Everything succeeded | `Upload completed for [Title].` + status line + links/ids | `upload_completed` |
| You asked "Status" | `YouTube: [Status] \| Instagram: [Status]` + context (see below) | `status_reply` |
| Settings → Send test message | A greeting with the current time | `test` |

Each message is a `POST {endpoint}/messages` (the `/messages` suffix is added
unless the endpoint already ends with it):

```http
POST /api/messages
Authorization: Bearer <API key>        # only when an API key is set
X-API-Key: <API key>                    # same key, for bridges that prefer it
Content-Type: application/json

{
  "to": "923001234567",
  "type": "text",
  "text": "Time reached. Starting upload for Launch teaser.",
  "message": "Time reached. Starting upload for Launch teaser.",
  "event": "upload_started",
  "sent_at": "2026-10-26T13:00:00.000Z",
  "upload": { "id": 7, "title": "Launch teaser", "platform": "both",
              "status": "triggered", "youtube_status": "pending",
              "instagram_status": "pending", "progress": 0.0,
              "scheduled_time": "2026-10-26T13:00:00.000Z" }
}
```

Any **2xx** response means "delivered to the agent". Pointing the endpoint at
`https://graph.facebook.com/v<ver>/<phone-number-id>/messages` switches the
client to the **Meta Cloud API** body (`messaging_product: whatsapp`, …) with
the API key as bearer token — outbound only, because the Cloud API delivers
incoming messages by webhook rather than polling.

### Inbound: "Status"

The phone has no public address, so the app **polls** the agent instead of
receiving a webhook:

```http
GET /api/messages?since=2026-10-26T12:50:00.000Z&limit=50&from=923001234567
Authorization: Bearer <API key>
```

The agent answers with the messages your number sent to it, newest or oldest
first — a bare array or wrapped in `messages` / `data` / `items` / `results`:

```json
{ "messages": [
  { "id": "m-1042", "from": "923001234567", "text": "Status",
    "timestamp": "2026-10-26T12:58:41Z" }
] }
```

Field names are matched loosely (`id|message_id|wamid`, `from|sender|wa_id`,
`text|body|message` — `text` may also be `{ "body": … }` — and `timestamp` as
ISO-8601, epoch seconds or milliseconds). Messages that **start with
"Status"** (any case, `status?`, `/status` …) get a reply built from the local
database:

```
YouTube: Uploading (42%) | Instagram: Pending
"Launch teaser" — uploading, 42% overall.

Other uploads:
• Weekly vlog — YouTube: Pending | Instagram: Pending (scheduled, in 3h 10m)
• Behind the scenes — YouTube: Completed | Instagram: Completed (completed)
```

`Status <part of a title>` narrows the reply to matching uploads. Messages from
other numbers, messages older than the last poll and anything that is not a
status request are ignored; every message id is remembered so a reply is sent
once even though the UI isolate, the foreground service and the WorkManager
watchdog all poll (they coordinate through `whatsapp_inbox.json` and an
exclusive lock file in the app's support directory).

**Reply latency:** every 30 s while the app is open or the scheduler service is
armed/uploading; otherwise the 15-minute watchdog picks the message up. Use the
**Check inbox now** button in Settings to force a poll.

### A minimal agent

Any bridge that implements the two routes above works. Sketch (Node +
Express; the `sendWhatsApp` / `onWhatsAppMessage` hooks come from whichever
WhatsApp library or provider you use):

```js
const app = require('express')().use(require('express').json());
const inbox = [];                       // {id, from, text, timestamp}
const KEY = process.env.AGENT_KEY;      // same value as "API Key" in Settings
const auth = (req, res, next) =>
  !KEY || req.get('x-api-key') === KEY ? next() : res.sendStatus(401);

onWhatsAppMessage(m => inbox.push({ id: m.id, from: m.from, text: m.text,
                                    timestamp: new Date().toISOString() }));

app.post('/api/messages', auth, async (req, res) => {
  await sendWhatsApp(req.body.to, req.body.text);
  res.json({ ok: true });
});
app.get('/api/messages', auth, (req, res) => {
  const since = req.query.since ? Date.parse(req.query.since) : 0;
  res.json({ messages: inbox.filter(m => Date.parse(m.timestamp) >= since
                                      && (!req.query.from || m.from.endsWith(req.query.from.slice(-10)))) });
});
app.listen(3000);
```

### Testing the agent on a phone

1. Settings → WhatsApp Agent API: enter the endpoint (e.g.
   `https://agent.example.com/api`), the API key if your bridge needs one and
   your number in international format (`923001234567`). **Save**, then tap
   **Send test message** — it should arrive on WhatsApp within seconds.
2. Send **"Status"** to the agent's WhatsApp number. With the app open the
   reply arrives within ~30 s (or immediately via **Check inbox now**); the
   Settings section shows *Inbox last checked …* and *Last "Status" reply …*.
3. Schedule an upload a few minutes ahead and lock the phone: you receive
   *Time reached…* at the exact minute, then *Upload completed…* (YouTube) or
   *Upload failed…* with the reason. "Status" answered while the service is
   armed comes back within 30 s; later ones within 15 minutes.

## What Phase 4 adds: the YouTube uploader

At the scheduled time the engine now really uploads to YouTube:

* **Sign in once, upload forever** — Settings → YouTube → *Sign in with
  Google* runs the Google account picker + consent screen
  (`google_sign_in` 7). The account e-mail is stored in secure storage; the
  background service and the WorkManager watchdog refresh access tokens for
  that account silently (no Activity needed), so uploads work hours or days
  later with the app closed.
* **Resumable upload protocol** (`POST …/upload/youtube/v3/videos?uploadType=resumable`
  → session URI → 4 MiB `PUT` chunks with `Content-Range`), implemented on
  `package:http` so the app controls retries and progress; `googleapis` is used
  for the request/response models and the read calls (`channels.list`,
  `videos.list`).
* **Metadata from the schedule** — title (≤ 100 chars, `<`/`>` removed),
  description (≤ 5000), tags (≤ 500 chars total), category 22, and
  `status = { privacyStatus: "public", selfDeclaredMadeForKids: false }`. There is
  **no `publishAt`**: the video is public as soon as YouTube finishes
  processing. Every adjustment made to your text is written to the activity log.
* **Progress in the database** — the uploader reports every 64 KiB; the engine
  writes `upload_progress` (0..1) at most every 1.5 s, which drives the card on
  the Home screen, the foreground-service notification and the WhatsApp
  "Status" reply.
* **Survives bad networks and a killed process** — network errors and 5xx
  answers back off (2 s → 2 min), ask YouTube how many bytes it has
  (`Content-Range: bytes */total`) and continue from there; a 401 refreshes
  the token and retries. The session URI is stored in the new
  `youtube_upload_uri` column (database version 2); if the process dies, the
  next service start / watchdog pass resumes the transfer from the last byte
  YouTube confirmed — up to 3 times — instead of failing it. Platforms that
  already finished are not uploaded twice. Failed uploads get a **Retry now**
  button in the details screen that redoes only the platform that failed.
* **Readable failures** — quota exhausted (≈ 1,600 of the default 10,000 daily
  units per upload), no YouTube channel on the account, revoked consent,
  invalid metadata, missing file… each ends up as a clear *Failed* reason in
  the app and in the WhatsApp failure message.

### Google Cloud setup (once)

1. Create a project at <https://console.cloud.google.com/> and enable
   **YouTube Data API v3** (APIs & Services → Library).
2. **OAuth consent screen**: External, add the scopes
   `…/auth/youtube.upload` and `…/auth/youtube.readonly`, and add your Google
   account as a **test user**. (While the app is in *Testing* mode Google
   expires the grant after 7 days — just sign in again in Settings. Publishing
   the consent screen removes that limit; for a personal app you can keep it
   unverified and click through the "unverified app" warning.)
3. **Credentials → Create credentials → OAuth client ID → Android**:
   package name `com.contentautomation.app`, SHA-1 of the key your APK is
   signed with (see below). Its ID is *not* typed anywhere — Google matches it
   by package + signature.
4. **Credentials → Create credentials → OAuth client ID → Web application**
   (no redirect URIs needed). Copy this client ID: it is the **Web OAuth
   client ID** you paste into Settings → YouTube (Google Sign-In on Android
   uses it as the `serverClientId`).
5. In the app: Settings → YouTube → paste the Web client ID → **Save** →
   **Sign in with Google** → pick the channel's account → allow *Manage your
   YouTube videos*. The section then shows the channel name and e-mail, and
   the YouTube chip turns green.

### Signing key = Google Sign-In identity

Google Sign-In only works when the APK is signed with the key whose SHA-1 is
registered in step 3, so **every APK must be signed with the same key**:

* **Local builds** use `~/.android/debug.keystore` (stable per machine). Get
  its SHA-1 with
  `keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android -keypass android`.
* **CI builds** need a keystore in the repository secrets; otherwise every run
  signs with a throw-away key and sign-in fails with *"could not find a
  credential for this app"*. Create one and add it once:

  ```bash
  keytool -genkey -v -keystore upload-keystore.jks -storetype JKS \
    -keyalg RSA -keysize 2048 -validity 10000 -alias upload
  base64 -w0 upload-keystore.jks        # → ANDROID_KEYSTORE_BASE64
  ```

  GitHub → repository **Settings → Secrets and variables → Actions**:
  `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`
  (`upload`), `ANDROID_KEY_PASSWORD`. The workflow writes `android/key.properties`
  from them, `android/app/build.gradle.kts` picks it up, and the job summary of
  every run prints the **SHA-1 / SHA-256 of the certificate the APK was signed
  with** — that SHA-1 is what you register in Google Cloud. Keep the `.jks`
  file safe; reinstalling with a differently signed APK requires uninstalling
  first.

### Testing YouTube on a phone

1. Settings → YouTube: paste the Web client ID, Save, Sign in with Google.
2. Schedule a short video 2–3 minutes ahead (platform *YouTube* only, so the
   Instagram placeholder does not mark the run as failed), lock the phone.
3. At the minute you get *Time reached…* on WhatsApp, the card shows the
   progress bar filling, and the activity log ends with
   *YouTube received all … (video id …, https://youtu.be/…)* followed by a
   status line such as *upload uploaded, processing processing, privacy public*.
   The video appears on the channel as soon as YouTube finishes processing.
4. Kill the app or switch to airplane mode mid-upload to see the resume:
   the log shows *Upload was interrupted … Resuming — attempt 1 of 3* and
   *Resuming the YouTube upload at X MB of Y MB*.

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
│   ├── whatsapp/
│   │   ├── whatsapp_agent.dart       # outbound interface + HttpWhatsAppAgent
│   │   ├── whatsapp_client.dart      # HTTP client: send / fetch inbox (generic + Cloud API)
│   │   ├── whatsapp_messages.dart    # exact texts + "Status" detection
│   │   ├── inbound_message.dart      # tolerant JSON parsing of inbox messages
│   │   ├── status_reply_builder.dart # DB → "YouTube: … | Instagram: …" reply
│   │   ├── inbox_service.dart        # poll → de-duplicate → reply (shared lock + cursor)
│   │   ├── inbox_cursor_store.dart   # whatsapp_inbox.json + cross-isolate lock file
│   │   └── inbox_poller.dart         # 30 s foreground polling while the app is open
│   ├── youtube/
│   │   ├── google_auth_gateway.dart  # google_sign_in seam: interactive sign-in + silent background tokens
│   │   ├── google_auth_client.dart   # token cache + Bearer http client (401 → refresh → retry)
│   │   ├── resumable_upload.dart     # Google resumable upload protocol (chunks, 308/Range, backoff, resume)
│   │   ├── youtube_metadata.dart     # schedule → snippet/status JSON within YouTube's limits
│   │   ├── youtube_uploader.dart     # VideoUploader for YouTube (resume via stored session URI)
│   │   ├── youtube_account_service.dart # Settings: sign in / channel name / sign out
│   │   └── youtube_errors.dart       # Google error JSON → readable messages
│   └── uploaders/video_uploader.dart # uploader interface + Instagram placeholder (Phase 5)
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
├── state/                            # ChangeNotifier providers (schedule, settings, background, whatsapp, youtube)
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
| `INTERNET` | YouTube uploads, WhatsApp agent (Instagram follows in Phase 5) |
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
   exact minute you get **"Time reached"** and the YouTube upload starts
   (Instagram is still a placeholder until Phase 5, so a *both* schedule ends
   as *Failed* with the Instagram reason in its activity log while the YouTube
   part completes).

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
Google Cloud setup is described under Phase 4 and the WhatsApp agent contract
under Phase 3; Meta Developer App and ngrok instructions arrive with Phases 5/6.

## Data model

`scheduled_uploads`: `video_path`, `video_name`, `video_size_bytes`, `title`,
`description`, `tags` (comma-separated), `scheduled_time` (epoch ms), `status`
(`scheduled | triggered | uploading | completed | failed`), `platform`
(`youtube | instagram | both`), `youtube_status`, `instagram_status`,
`youtube_video_id`, `instagram_media_id`, `youtube_upload_uri` (resumable
session while a YouTube transfer is in flight, v2), `upload_progress`,
`error_message`, `retry_count` (also counts automatic resumes), `created_at`,
`updated_at`.

`upload_events`: per-upload activity log (`timestamp`, `level`, `message`),
deleted by cascade with its upload.
