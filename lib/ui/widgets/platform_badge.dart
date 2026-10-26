import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/models/enums.dart';

/// Small coloured pill naming a destination platform.
class PlatformBadge extends StatelessWidget {
  const PlatformBadge.youtube({super.key, this.compact = false})
    : _label = 'YouTube',
      _icon = Icons.play_circle_outline,
      _color = AppTheme.youtubeRed;

  const PlatformBadge.instagram({super.key, this.compact = false})
    : _label = 'Instagram',
      _icon = Icons.camera_alt_outlined,
      _color = AppTheme.instagramPink;

  final String _label;
  final IconData _icon;
  final Color _color;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final textStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: _color,
      fontWeight: FontWeight.w600,
    );
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 6 : 8,
        vertical: compact ? 2 : 4,
      ),
      decoration: BoxDecoration(
        color: _color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: _color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_icon, size: compact ? 12 : 14, color: _color),
          const SizedBox(width: 4),
          Text(_label, style: textStyle),
        ],
      ),
    );
  }
}

/// Renders one badge per platform included in [platform].
class PlatformBadges extends StatelessWidget {
  const PlatformBadges({super.key, required this.platform, this.compact = false});

  final UploadPlatform platform;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        if (platform.includesYouTube) PlatformBadge.youtube(compact: compact),
        if (platform.includesInstagram)
          PlatformBadge.instagram(compact: compact),
      ],
    );
  }
}
