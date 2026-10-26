import 'dart:async';

import 'package:flutter/widgets.dart';

import 'inbox_service.dart';

/// Polls the inbox from the UI isolate while the app is in the foreground.
///
/// Background polling is handled by the scheduler service (while it runs) and
/// by the WorkManager watchdog, so this only adds snappy replies while the
/// user is looking at the app.
class ForegroundInboxPoller {
  ForegroundInboxPoller({
    required WhatsAppInboxService service,
    this.interval = const Duration(seconds: 30),
  }) : _service = service;

  final WhatsAppInboxService _service;
  final Duration interval;

  final ValueNotifier<InboxPollResult?> lastResult = ValueNotifier(null);

  Timer? _timer;
  AppLifecycleListener? _lifecycle;
  bool _polling = false;
  bool _started = false;

  void start() {
    if (_started) return;
    _started = true;
    _lifecycle = AppLifecycleListener(
      onResume: _resume,
      onInactive: _pause,
      onHide: _pause,
      onPause: _pause,
      onDetach: _pause,
    );
    _resume();
  }

  Future<InboxPollResult> pollNow() async {
    if (_polling) {
      return const InboxPollResult.skipped('Already polling');
    }
    _polling = true;
    try {
      final result = await _service.pollOnce();
      lastResult.value = result;
      return result;
    } catch (e) {
      final result = InboxPollResult.failed('$e');
      lastResult.value = result;
      return result;
    } finally {
      _polling = false;
    }
  }

  void _resume() {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => unawaited(pollNow()));
    unawaited(pollNow());
  }

  void _pause() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() {
    _pause();
    _lifecycle?.dispose();
    _lifecycle = null;
    lastResult.dispose();
    _started = false;
  }
}
