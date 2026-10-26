import 'package:flutter/material.dart';

import '../../data/models/enums.dart';

/// Colour + icon describing an [UploadStatus] or [PlatformUploadStatus].
class StatusStyle {
  const StatusStyle({
    required this.icon,
    required this.foreground,
    required this.background,
  });

  final IconData icon;
  final Color foreground;
  final Color background;

  static StatusStyle forUpload(UploadStatus status, ColorScheme scheme) {
    return switch (status) {
      UploadStatus.scheduled => StatusStyle(
        icon: Icons.schedule,
        foreground: scheme.onSecondaryContainer,
        background: scheme.secondaryContainer,
      ),
      UploadStatus.triggered => StatusStyle(
        icon: Icons.notifications_active_outlined,
        foreground: scheme.onTertiaryContainer,
        background: scheme.tertiaryContainer,
      ),
      UploadStatus.uploading => StatusStyle(
        icon: Icons.cloud_upload_outlined,
        foreground: scheme.onPrimaryContainer,
        background: scheme.primaryContainer,
      ),
      UploadStatus.completed => const StatusStyle(
        icon: Icons.check_circle_outline,
        foreground: Color(0xFF166534),
        background: Color(0xFFDCFCE7),
      ),
      UploadStatus.failed => StatusStyle(
        icon: Icons.error_outline,
        foreground: scheme.onErrorContainer,
        background: scheme.errorContainer,
      ),
    };
  }

  static StatusStyle forPlatform(
    PlatformUploadStatus status,
    ColorScheme scheme,
  ) {
    return switch (status) {
      PlatformUploadStatus.notApplicable => StatusStyle(
        icon: Icons.remove_circle_outline,
        foreground: scheme.onSurfaceVariant,
        background: scheme.surfaceContainerHighest,
      ),
      PlatformUploadStatus.pending => StatusStyle(
        icon: Icons.hourglass_empty,
        foreground: scheme.onSecondaryContainer,
        background: scheme.secondaryContainer,
      ),
      PlatformUploadStatus.uploading => StatusStyle(
        icon: Icons.cloud_upload_outlined,
        foreground: scheme.onPrimaryContainer,
        background: scheme.primaryContainer,
      ),
      PlatformUploadStatus.processing => StatusStyle(
        icon: Icons.sync,
        foreground: scheme.onTertiaryContainer,
        background: scheme.tertiaryContainer,
      ),
      PlatformUploadStatus.completed => const StatusStyle(
        icon: Icons.check_circle_outline,
        foreground: Color(0xFF166534),
        background: Color(0xFFDCFCE7),
      ),
      PlatformUploadStatus.failed => StatusStyle(
        icon: Icons.error_outline,
        foreground: scheme.onErrorContainer,
        background: scheme.errorContainer,
      ),
    };
  }
}

/// Pill showing the overall [UploadStatus].
class UploadStatusChip extends StatelessWidget {
  const UploadStatusChip({super.key, required this.status});

  final UploadStatus status;

  @override
  Widget build(BuildContext context) {
    final style = StatusStyle.forUpload(status, Theme.of(context).colorScheme);
    return _Pill(style: style, label: status.label);
  }
}

/// Pill showing a per-platform [PlatformUploadStatus].
class PlatformStatusChip extends StatelessWidget {
  const PlatformStatusChip({super.key, required this.status});

  final PlatformUploadStatus status;

  @override
  Widget build(BuildContext context) {
    final style = StatusStyle.forPlatform(
      status,
      Theme.of(context).colorScheme,
    );
    return _Pill(style: style, label: status.label);
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.style, required this.label});

  final StatusStyle style;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: style.background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(style.icon, size: 14, color: style.foreground),
          const SizedBox(width: 4),
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: style.foreground,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
