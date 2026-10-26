import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Coarse state of the background scheduler, shared with the UI.
enum SchedulerState {
  /// Nothing scheduled; the service is not running.
  idle('Idle'),

  /// Uploads are pending but far away; the service sleeps until the alarm.
  sleeping('Sleeping until wake-up'),

  /// The service is running and counting down to the next due time.
  waiting('Armed'),

  /// An upload is in progress.
  uploading('Uploading');

  const SchedulerState(this.label);

  final String label;

  static SchedulerState parse(Object? raw) => SchedulerState.values.firstWhere(
    (s) => s.name == raw,
    orElse: () => SchedulerState.idle,
  );
}

/// Snapshot published by whichever isolate last touched the scheduler.
@immutable
class SchedulerStatus {
  const SchedulerStatus({
    required this.state,
    required this.updatedAt,
    required this.source,
    this.message,
    this.nextDue,
    this.wakeupAt,
    this.wakeupKind,
    this.activeUploadId,
    this.activeTitle,
    this.progress,
    this.lastWatchdogRun,
  });

  factory SchedulerStatus.fromMap(Map<Object?, Object?> map) {
    DateTime? date(Object? raw) => raw is num
        ? DateTime.fromMillisecondsSinceEpoch(raw.toInt())
        : null;
    return SchedulerStatus(
      state: SchedulerState.parse(map['state']),
      updatedAt: date(map['updatedAt']) ?? DateTime.now(),
      source: (map['source'] as String?) ?? 'unknown',
      message: map['message'] as String?,
      nextDue: date(map['nextDue']),
      wakeupAt: date(map['wakeupAt']),
      wakeupKind: map['wakeupKind'] as String?,
      activeUploadId: (map['activeUploadId'] as num?)?.toInt(),
      activeTitle: map['activeTitle'] as String?,
      progress: (map['progress'] as num?)?.toDouble(),
      lastWatchdogRun: date(map['lastWatchdogRun']),
    );
  }

  final SchedulerState state;
  final DateTime updatedAt;

  /// 'service', 'watchdog' or 'app'.
  final String source;
  final String? message;
  final DateTime? nextDue;
  final DateTime? wakeupAt;

  /// 'exact' / 'inexact' when an alarm is armed.
  final String? wakeupKind;
  final int? activeUploadId;
  final String? activeTitle;

  /// 0..1 while uploading.
  final double? progress;
  final DateTime? lastWatchdogRun;

  Map<String, Object?> toMap() => {
    'state': state.name,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
    'source': source,
    'message': message,
    'nextDue': nextDue?.millisecondsSinceEpoch,
    'wakeupAt': wakeupAt?.millisecondsSinceEpoch,
    'wakeupKind': wakeupKind,
    'activeUploadId': activeUploadId,
    'activeTitle': activeTitle,
    'progress': progress,
    'lastWatchdogRun': lastWatchdogRun?.millisecondsSinceEpoch,
  };

  SchedulerStatus copyWith({DateTime? lastWatchdogRun}) => SchedulerStatus(
    state: state,
    updatedAt: updatedAt,
    source: source,
    message: message,
    nextDue: nextDue,
    wakeupAt: wakeupAt,
    wakeupKind: wakeupKind,
    activeUploadId: activeUploadId,
    activeTitle: activeTitle,
    progress: progress,
    lastWatchdogRun: lastWatchdogRun ?? this.lastWatchdogRun,
  );
}

/// Persists the latest [SchedulerStatus] so the UI can show what happened
/// while it was not running (the isolates share nothing but the disk).
abstract interface class SchedulerStatusStore {
  Future<SchedulerStatus?> read();
  Future<void> write(SchedulerStatus status);

  /// Stamps the watchdog's last run without touching the rest of the status.
  Future<void> markWatchdogRun(DateTime at);
}

/// JSON file in the app's support directory.
class FileSchedulerStatusStore implements SchedulerStatusStore {
  FileSchedulerStatusStore({Directory? directoryOverride})
    : _directoryOverride = directoryOverride;

  final Directory? _directoryOverride;

  Future<File> _file() async {
    final directory =
        _directoryOverride ?? await getApplicationSupportDirectory();
    return File(p.join(directory.path, 'scheduler_status.json'));
  }

  @override
  Future<SchedulerStatus?> read() async {
    try {
      final file = await _file();
      if (!await file.exists()) return null;
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map) return null;
      return SchedulerStatus.fromMap(raw.cast<Object?, Object?>());
    } catch (e) {
      debugPrint('Could not read scheduler status: $e');
      return null;
    }
  }

  @override
  Future<void> write(SchedulerStatus status) async {
    try {
      final previous = await read();
      final merged = status.lastWatchdogRun == null
          ? status.copyWith(lastWatchdogRun: previous?.lastWatchdogRun)
          : status;
      final file = await _file();
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(merged.toMap()), flush: true);
      await tmp.rename(file.path);
    } catch (e) {
      debugPrint('Could not write scheduler status: $e');
    }
  }

  @override
  Future<void> markWatchdogRun(DateTime at) async {
    final current =
        await read() ??
        SchedulerStatus(
          state: SchedulerState.idle,
          updatedAt: at,
          source: 'watchdog',
        );
    await write(current.copyWith(lastWatchdogRun: at));
  }
}

/// Keeps the status in memory (tests, unsupported platforms).
class InMemorySchedulerStatusStore implements SchedulerStatusStore {
  SchedulerStatus? status;

  @override
  Future<SchedulerStatus?> read() async => status;

  @override
  Future<void> write(SchedulerStatus value) async {
    status = value.lastWatchdogRun == null
        ? value.copyWith(lastWatchdogRun: status?.lastWatchdogRun)
        : value;
  }

  @override
  Future<void> markWatchdogRun(DateTime at) async {
    final current =
        status ??
        SchedulerStatus(state: SchedulerState.idle, updatedAt: at, source: 'watchdog');
    status = current.copyWith(lastWatchdogRun: at);
  }
}
