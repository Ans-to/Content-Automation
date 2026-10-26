import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../data/models/scheduled_upload.dart';
import '../../services/settings_service.dart';
import 'inbound_message.dart';

/// Raised for any transport / HTTP-level problem talking to the agent.
class WhatsAppAgentException implements Exception {
  const WhatsAppAgentException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Which wire format to speak.
enum WhatsAppAgentFlavor {
  /// The small REST contract documented in the README
  /// (`POST {endpoint}/messages`, `GET {endpoint}/messages`).
  generic,

  /// Meta's WhatsApp Cloud API (`graph.facebook.com/…/messages`). Outbound
  /// only — the Cloud API delivers inbound messages by webhook, not polling.
  cloudApi,
}

/// Everything the client needs, derived from [AppSettings].
class WhatsAppAgentConfig {
  const WhatsAppAgentConfig({
    required this.endpoint,
    this.apiKey = '',
    this.recipient = '',
    this.inboxUrl = '',
  });

  factory WhatsAppAgentConfig.fromSettings(AppSettings settings) =>
      WhatsAppAgentConfig(
        endpoint: settings.whatsappEndpoint.trim(),
        apiKey: settings.whatsappApiKey.trim(),
        recipient: settings.whatsappRecipient.trim(),
        inboxUrl: settings.whatsappInboxUrl.trim(),
      );

  final String endpoint;
  final String apiKey;
  final String recipient;
  final String inboxUrl;

  Uri? get _endpointUri {
    final uri = Uri.tryParse(endpoint);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
    if (uri.scheme != 'https' && uri.scheme != 'http') return null;
    return uri;
  }

  /// Outbound alerts are possible.
  bool get isConfigured => _endpointUri != null && recipient.isNotEmpty;

  WhatsAppAgentFlavor get flavor {
    final host = _endpointUri?.host.toLowerCase() ?? '';
    return host == 'graph.facebook.com' || host.endsWith('.facebook.com')
        ? WhatsAppAgentFlavor.cloudApi
        : WhatsAppAgentFlavor.generic;
  }

  /// `POST` target for outgoing messages.
  Uri get sendUri {
    final base = _endpointUri;
    if (base == null) {
      throw const WhatsAppAgentException('WhatsApp agent endpoint is not set.');
    }
    if (flavor == WhatsAppAgentFlavor.cloudApi) return base;
    return _withMessagesPath(base);
  }

  /// `GET` target for polling inbound messages; `null` when polling is not
  /// available for this configuration.
  Uri? get inboxUri {
    if (inboxUrl.isNotEmpty) {
      final uri = Uri.tryParse(inboxUrl);
      return (uri != null && uri.hasScheme && uri.host.isNotEmpty) ? uri : null;
    }
    if (flavor == WhatsAppAgentFlavor.cloudApi) return null;
    final base = _endpointUri;
    return base == null ? null : _withMessagesPath(base);
  }

  bool get supportsInbox => inboxUri != null;

  /// Digits of the configured recipient (for sender checks).
  String? get recipientDigits => InboundMessage.normalizeNumber(recipient);

  static Uri _withMessagesPath(Uri base) {
    final segments = base.pathSegments.where((s) => s.isNotEmpty).toList();
    final alreadyThere = segments.isNotEmpty && segments.last == 'messages';
    // `replace` also normalises a trailing slash away.
    return base.replace(
      pathSegments: alreadyThere ? segments : [...segments, 'messages'],
    );
  }
}

/// Thin HTTP client for the agent. Pure Dart; tested with `MockClient`.
class WhatsAppHttpClient {
  WhatsAppHttpClient({
    http.Client? client,
    this.timeout = const Duration(seconds: 20),
    DateTime Function()? clock,
  }) : _client = client ?? http.Client(),
       _clock = clock ?? DateTime.now;

  final http.Client _client;
  final Duration timeout;
  final DateTime Function() _clock;

  static const String userAgent = 'ContentAutomation/0.1 (Android)';

  Map<String, String> _headers(WhatsAppAgentConfig config) => {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
    'User-Agent': userAgent,
    if (config.apiKey.isNotEmpty) ...{
      'Authorization': 'Bearer ${config.apiKey}',
      'X-API-Key': config.apiKey,
    },
  };

  /// Sends [text] to [to] (defaults to the configured recipient).
  ///
  /// [event] tags the message so an agent can route it
  /// (`upload_started`, `upload_failed`, `upload_completed`, `status_reply`,
  /// `test`). [upload] is attached as structured data when relevant.
  Future<void> sendText(
    WhatsAppAgentConfig config,
    String text, {
    String event = 'message',
    String? to,
    ScheduledUpload? upload,
  }) async {
    final recipient = (to ?? config.recipient).trim();
    if (recipient.isEmpty) {
      throw const WhatsAppAgentException('No WhatsApp recipient configured.');
    }

    final body = switch (config.flavor) {
      WhatsAppAgentFlavor.cloudApi => {
        'messaging_product': 'whatsapp',
        'recipient_type': 'individual',
        'to': recipient,
        'type': 'text',
        'text': {'preview_url': false, 'body': text},
      },
      WhatsAppAgentFlavor.generic => {
        'to': recipient,
        'type': 'text',
        'text': text,
        'message': text, // alias for agents that expect "message"
        'event': event,
        'sent_at': _clock().toUtc().toIso8601String(),
        if (upload != null) 'upload': _uploadJson(upload),
      },
    };

    final response = await _run(
      () => _client.post(
        config.sendUri,
        headers: _headers(config),
        body: jsonEncode(body),
      ),
      'send message',
    );
    _ensureSuccess(response, 'Sending the WhatsApp message');
  }

  /// Fetches messages received since [since] (agent-side filtering is a
  /// courtesy; the caller de-duplicates anyway).
  Future<List<InboundMessage>> fetchInbox(
    WhatsAppAgentConfig config, {
    DateTime? since,
    int limit = 50,
  }) async {
    final base = config.inboxUri;
    if (base == null) {
      throw const WhatsAppAgentException(
        'This agent configuration has no inbox to poll.',
      );
    }
    final uri = base.replace(
      queryParameters: {
        ...base.queryParameters,
        if (since != null) 'since': since.toUtc().toIso8601String(),
        'limit': '$limit',
        if (config.recipient.isNotEmpty) 'from': config.recipient,
      },
    );

    final response = await _run(
      () => _client.get(uri, headers: _headers(config)),
      'fetch inbox',
    );
    _ensureSuccess(response, 'Reading the WhatsApp inbox');
    if (response.body.trim().isEmpty) return const [];

    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException catch (e) {
      throw WhatsAppAgentException(
        'The inbox response is not valid JSON: ${e.message}',
        statusCode: response.statusCode,
      );
    }
    return InboundMessage.parseList(decoded);
  }

  // ---------------------------------------------------------------------------

  Future<http.Response> _run(
    Future<http.Response> Function() request,
    String what,
  ) async {
    try {
      return await request().timeout(timeout);
    } on TimeoutException {
      throw WhatsAppAgentException(
        'The WhatsApp agent did not answer within ${timeout.inSeconds}s '
        '($what).',
      );
    } on WhatsAppAgentException {
      rethrow;
    } catch (e) {
      throw WhatsAppAgentException('Could not reach the WhatsApp agent: $e');
    }
  }

  void _ensureSuccess(http.Response response, String what) {
    final code = response.statusCode;
    if (code >= 200 && code < 300) return;
    final snippet = response.body.trim();
    final detail = snippet.isEmpty
        ? ''
        : ': ${snippet.length > 300 ? '${snippet.substring(0, 300)}…' : snippet}';
    final hint = switch (code) {
      401 || 403 => ' Check the API key.',
      404 => ' Check the endpoint URL.',
      _ => '',
    };
    throw WhatsAppAgentException(
      '$what failed with HTTP $code$detail.$hint',
      statusCode: code,
    );
  }

  static Map<String, Object?> _uploadJson(ScheduledUpload upload) => {
    'id': upload.id,
    'title': upload.title,
    'platform': upload.platform.dbValue,
    'status': upload.status.dbValue,
    'youtube_status': upload.youtubeStatus.dbValue,
    'instagram_status': upload.instagramStatus.dbValue,
    'youtube_video_id': upload.youtubeVideoId,
    'instagram_media_id': upload.instagramMediaId,
    'progress': upload.uploadProgress,
    'scheduled_time': upload.scheduledTime.toUtc().toIso8601String(),
    'error': upload.errorMessage,
  };

  void close() => _client.close();
}
