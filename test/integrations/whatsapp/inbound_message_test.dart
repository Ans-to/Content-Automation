import 'package:content_automation/data/models/enums.dart';
import 'package:content_automation/data/models/scheduled_upload.dart';
import 'package:content_automation/integrations/whatsapp/inbound_message.dart';
import 'package:content_automation/integrations/whatsapp/whatsapp_messages.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('InboundMessage.tryParse', () {
    test('reads the generic shape', () {
      final message = InboundMessage.tryParse({
        'id': 'm1',
        'from': '+92 300 1234567',
        'text': 'Status',
        'timestamp': '2026-10-26T10:00:00Z',
      })!;
      expect(message.id, 'm1');
      expect(message.from, '+92 300 1234567');
      expect(message.fromDigits, '923001234567');
      expect(message.text, 'Status');
      expect(message.timestamp, DateTime.utc(2026, 10, 26, 10));
    });

    test('accepts Cloud-API-like nested text, wamid and epoch seconds', () {
      final message = InboundMessage.tryParse({
        'wamid': 'wamid.ABC',
        'wa_id': '923001234567',
        'text': {'body': 'status please'},
        'timestamp': 1761472800, // seconds
      })!;
      expect(message.id, 'wamid.ABC');
      expect(message.from, '923001234567');
      expect(message.text, 'status please');
      expect(
        message.timestamp,
        DateTime.fromMillisecondsSinceEpoch(1761472800 * 1000),
      );
    });

    test('accepts epoch milliseconds as a string and body/sender aliases', () {
      final message = InboundMessage.tryParse({
        'message_id': 7,
        'sender': '0300-1234567',
        'body': 'Status launch',
        'created_at': '1761472800000',
      })!;
      expect(message.id, '7');
      expect(message.fromDigits, '03001234567');
      expect(
        message.timestamp,
        DateTime.fromMillisecondsSinceEpoch(1761472800000),
      );
    });

    test('creates a synthetic id when the agent provides none', () {
      final a = InboundMessage.tryParse({'from': '1', 'text': 'Status'})!;
      final b = InboundMessage.tryParse({'from': '1', 'text': 'Status'})!;
      final c = InboundMessage.tryParse({'from': '1', 'text': 'Other'})!;
      expect(a.id, startsWith('synthetic:'));
      expect(a.id, b.id);
      expect(a.id, isNot(c.id));
    });

    test('returns null for entries without text', () {
      expect(InboundMessage.tryParse({'id': 'x'}), isNull);
      expect(InboundMessage.tryParse('not a map'), isNull);
      expect(InboundMessage.tryParse({'text': '   '}), isNull);
    });
  });

  group('InboundMessage.parseList', () {
    test('accepts a bare list', () {
      final list = InboundMessage.parseList([
        {'id': '1', 'text': 'a'},
        {'id': '2', 'text': 'b'},
        'garbage',
      ]);
      expect(list.map((m) => m.id), ['1', '2']);
    });

    test('accepts wrapped lists, one level deep', () {
      expect(
        InboundMessage.parseList({
          'messages': [
            {'id': '1', 'text': 'a'},
          ],
        }).single.id,
        '1',
      );
      expect(
        InboundMessage.parseList({
          'data': {
            'items': [
              {'id': '2', 'text': 'b'},
            ],
          },
        }).single.id,
        '2',
      );
    });

    test('returns an empty list for anything else', () {
      expect(InboundMessage.parseList(null), isEmpty);
      expect(InboundMessage.parseList({'ok': true}), isEmpty);
      expect(InboundMessage.parseList(42), isEmpty);
    });
  });

  group('WhatsAppMessages', () {
    test('recognises Status requests in many spellings', () {
      for (final text in [
        'Status',
        'status',
        'STATUS',
        ' status? ',
        'Status!',
        '/status',
        'status: launch teaser',
        'Status launch teaser',
      ]) {
        expect(WhatsAppMessages.isStatusRequest(text), isTrue, reason: text);
      }
    });

    test('ignores other messages, including ones that merely contain it', () {
      for (final text in [
        'hello',
        'what is the status',
        'statuses',
        'Stat',
        '',
      ]) {
        expect(WhatsAppMessages.isStatusRequest(text), isFalse, reason: text);
      }
    });

    test('extracts the optional title filter', () {
      expect(WhatsAppMessages.statusFilter('Status'), isNull);
      expect(WhatsAppMessages.statusFilter('status?'), isNull);
      expect(WhatsAppMessages.statusFilter('Status launch teaser'),
          'launch teaser');
      expect(WhatsAppMessages.statusFilter('status: Launch!'), 'Launch');
    });

    test('builds the outbound texts', () {
      final upload = ScheduledUpload(
        id: 3,
        videoPath: '/v.mp4',
        videoName: 'v.mp4',
        title: 'Launch teaser',
        scheduledTime: DateTime(2026, 10, 26, 18),
        status: UploadStatus.completed,
        youtubeStatus: PlatformUploadStatus.completed,
        instagramStatus: PlatformUploadStatus.completed,
        youtubeVideoId: 'abc123',
        instagramMediaId: '999',
      );
      expect(
        WhatsAppMessages.timeReached(upload),
        'Time reached. Starting upload for Launch teaser.',
      );
      expect(
        WhatsAppMessages.uploadFailed(upload, 'boom'),
        'Upload failed for Launch teaser.\n'
        'YouTube: Completed | Instagram: Completed\n'
        'Reason: boom',
      );
      expect(
        WhatsAppMessages.uploadCompleted(upload),
        'Upload completed for Launch teaser.\n'
        'YouTube: Completed | Instagram: Completed\n'
        'YouTube: https://youtu.be/abc123\n'
        'Instagram media id: 999',
      );
      expect(
        WhatsAppMessages.platformLine(
          upload.copyWith(
            status: UploadStatus.uploading,
            youtubeStatus: PlatformUploadStatus.uploading,
            instagramStatus: PlatformUploadStatus.pending,
            uploadProgress: 0.5,
          ),
        ),
        'YouTube: Uploading (50%) | Instagram: Pending',
      );
    });
  });
}
