import 'package:flutter/foundation.dart';

import '../integrations/whatsapp/inbox_cursor_store.dart';
import '../integrations/whatsapp/inbox_poller.dart';
import '../integrations/whatsapp/inbox_service.dart';
import '../integrations/whatsapp/whatsapp_agent.dart';

/// Settings-screen state for the WhatsApp agent: test messages and inbox
/// diagnostics (last check, last reply, last error).
class WhatsAppProvider extends ChangeNotifier {
  WhatsAppProvider({
    required HttpWhatsAppAgent agent,
    required InboxCursorStore cursorStore,
    ForegroundInboxPoller? poller,
  }) : _agent = agent,
       _cursorStore = cursorStore,
       _poller = poller {
    _poller?.lastResult.addListener(_onPoll);
  }

  final HttpWhatsAppAgent _agent;
  final InboxCursorStore _cursorStore;
  final ForegroundInboxPoller? _poller;

  bool _busy = false;
  String? _lastTestMessage;
  String? _lastTestError;
  InboxCursor _cursor = const InboxCursor();
  InboxPollResult? _lastPoll;

  bool get isBusy => _busy;
  String? get lastTestMessage => _lastTestMessage;
  String? get lastTestError => _lastTestError;
  InboxCursor get cursor => _cursor;
  InboxPollResult? get lastPoll => _lastPoll;

  /// Whether the running app polls the inbox at all.
  bool get hasPoller => _poller != null;

  Future<void> refresh() async {
    _cursor = await _cursorStore.read();
    notifyListeners();
  }

  /// Sends the test message with the *saved* settings.
  Future<bool> sendTest() async {
    _busy = true;
    _lastTestError = null;
    notifyListeners();
    try {
      _lastTestMessage = await _agent.sendTestMessage();
      return true;
    } catch (e) {
      _lastTestMessage = null;
      _lastTestError = '$e';
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Polls the inbox right now (answers pending "Status" messages).
  Future<InboxPollResult?> checkInbox() async {
    final poller = _poller;
    if (poller == null) return null;
    _busy = true;
    notifyListeners();
    try {
      final result = await poller.pollNow();
      _cursor = await _cursorStore.read();
      return result;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  void _onPoll() {
    _lastPoll = _poller?.lastResult.value;
    _cursorStore.read().then((cursor) {
      _cursor = cursor;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _poller?.lastResult.removeListener(_onPoll);
    super.dispose();
  }
}
