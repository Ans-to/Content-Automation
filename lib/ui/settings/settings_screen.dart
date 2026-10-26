import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme.dart';
import '../../services/settings_service.dart';
import '../../state/settings_provider.dart';
import 'widgets/secret_field.dart';

/// API credentials for YouTube, Instagram, the WhatsApp agent and the tunnel.
/// Everything typed here is written to encrypted secure storage on the phone.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _formKey = GlobalKey<FormState>();

  // YouTube
  final _youtubeClientId = TextEditingController();
  final _youtubeApiKey = TextEditingController();
  // Instagram
  final _instagramAppId = TextEditingController();
  final _instagramAccessToken = TextEditingController();
  final _instagramBusinessAccountId = TextEditingController();
  // WhatsApp
  final _whatsappEndpoint = TextEditingController();
  final _whatsappApiKey = TextEditingController();
  final _whatsappRecipient = TextEditingController();
  // Tunnel
  final _ngrokAuthToken = TextEditingController();

  late final List<TextEditingController> _all = [
    _youtubeClientId,
    _youtubeApiKey,
    _instagramAppId,
    _instagramAccessToken,
    _instagramBusinessAccountId,
    _whatsappEndpoint,
    _whatsappApiKey,
    _whatsappRecipient,
    _ngrokAuthToken,
  ];

  AppSettings _loaded = const AppSettings();
  bool _populated = false;
  bool _populating = false;

  @override
  void initState() {
    super.initState();
    for (final controller in _all) {
      controller.addListener(_onChanged);
    }
    // Make sure the stored values are read at least once.
    final provider = context.read<SettingsProvider>();
    if (!provider.isLoaded) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !provider.isLoaded) provider.load();
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Fill the fields once the provider has read secure storage. Subscribing
    // here (rather than only in build) means we are re-run when it loads.
    final provider = Provider.of<SettingsProvider>(context);
    if (!_populated && provider.isLoaded) {
      _populate(provider.settings);
    }
  }

  @override
  void dispose() {
    for (final controller in _all) {
      controller
        ..removeListener(_onChanged)
        ..dispose();
    }
    super.dispose();
  }

  void _onChanged() {
    // Controller writes from _populate must not trigger a rebuild mid-build.
    if (!_populating && mounted) setState(() {});
  }

  void _populate(AppSettings settings) {
    _populating = true;
    try {
      _youtubeClientId.text = settings.youtubeClientId;
      _youtubeApiKey.text = settings.youtubeApiKey;
      _instagramAppId.text = settings.instagramAppId;
      _instagramAccessToken.text = settings.instagramAccessToken;
      _instagramBusinessAccountId.text = settings.instagramBusinessAccountId;
      _whatsappEndpoint.text = settings.whatsappEndpoint;
      _whatsappApiKey.text = settings.whatsappApiKey;
      _whatsappRecipient.text = settings.whatsappRecipient;
      _ngrokAuthToken.text = settings.ngrokAuthToken;
    } finally {
      _populating = false;
    }
    _loaded = settings;
    _populated = true;
  }

  AppSettings get _current => AppSettings(
    youtubeClientId: _youtubeClientId.text.trim(),
    youtubeApiKey: _youtubeApiKey.text.trim(),
    instagramAppId: _instagramAppId.text.trim(),
    instagramAccessToken: _instagramAccessToken.text.trim(),
    instagramBusinessAccountId: _instagramBusinessAccountId.text.trim(),
    whatsappEndpoint: _whatsappEndpoint.text.trim(),
    whatsappApiKey: _whatsappApiKey.text.trim(),
    whatsappRecipient: _whatsappRecipient.text.trim(),
    ngrokAuthToken: _ngrokAuthToken.text.trim(),
  );

  bool get _isDirty => _populated && _current != _loaded;

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    if (!(_formKey.currentState?.validate() ?? false)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fix the highlighted fields.')),
      );
      return;
    }
    final provider = context.read<SettingsProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final settings = _current;
    try {
      await provider.save(settings);
      if (!mounted) return;
      setState(() => _loaded = settings);
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Saved. Keys are stored encrypted on this device.'),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not save: $e')));
    }
  }

  Future<void> _clearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove all keys?'),
        content: const Text(
          'Every API key and token will be deleted from this device. '
          'Scheduled uploads are kept but cannot run until keys are entered again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final provider = context.read<SettingsProvider>();
    final messenger = ScaffoldMessenger.of(context);
    await provider.clear();
    if (!mounted) return;
    setState(() => _populate(const AppSettings()));
    messenger.showSnackBar(const SnackBar(content: Text('All keys removed.')));
  }

  Future<bool> _confirmDiscard() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text('You have unsaved changes.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep editing'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  String? _validateUrl(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return null;
    final uri = Uri.tryParse(text);
    if (uri == null || !(uri.isScheme('https') || uri.isScheme('http')) || uri.host.isEmpty) {
      return 'Enter a full URL starting with https://';
    }
    return null;
  }

  String? _validatePhone(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return null;
    if (!RegExp(r'^\+?[0-9]{7,15}$').hasMatch(text)) {
      return 'Digits only, international format (e.g. 923001234567).';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<SettingsProvider>();

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final current = _current;

    return PopScope(
      canPop: !_isDirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final discard = await _confirmDiscard();
        if (!discard || !mounted) return;
        Navigator.of(this.context).pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Settings'),
          actions: [
            IconButton(
              tooltip: 'Save',
              onPressed: provider.isSaving ? null : _save,
              icon: const Icon(Icons.save_outlined),
            ),
            PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'clear') _clearAll();
              },
              itemBuilder: (context) => const [
                PopupMenuItem(
                  value: 'clear',
                  child: ListTile(
                    leading: Icon(Icons.delete_forever_outlined),
                    title: Text('Remove all keys'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
          ],
        ),
        body: !provider.isLoaded
            ? const Center(child: CircularProgressIndicator())
            : Form(
                key: _formKey,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
                  children: [
                    _PrivacyNote(scheme: scheme),
                    if (provider.error != null)
                      Card(
                        color: scheme.errorContainer,
                        margin: const EdgeInsets.only(top: 8),
                        child: ListTile(
                          leading: Icon(
                            Icons.error_outline,
                            color: scheme.onErrorContainer,
                          ),
                          title: Text(
                            provider.error!,
                            style: TextStyle(color: scheme.onErrorContainer),
                          ),
                        ),
                      ),
                    const SizedBox(height: 8),
                    _StatusRow(settings: current),
                    const SizedBox(height: 8),

                    // --- YouTube ------------------------------------------------
                    _SettingsSection(
                      icon: Icons.play_circle_outline,
                      color: AppTheme.youtubeRed,
                      title: 'YouTube Data API v3',
                      subtitle:
                          'Google Cloud Console → APIs & Services → Credentials',
                      configured: current.isYouTubeConfigured,
                      children: [
                        SecretField(
                          controller: _youtubeClientId,
                          label: 'OAuth Client ID',
                          hint: '1234567890-abc.apps.googleusercontent.com',
                          helper:
                              'Android OAuth client created for package '
                              'com.contentautomation.app + your signing SHA-1.',
                          icon: Icons.badge_outlined,
                          secret: false,
                        ),
                        SecretField(
                          controller: _youtubeApiKey,
                          label: 'API Key',
                          hint: 'AIza…',
                          helper: 'Optional. Used for read-only requests.',
                          icon: Icons.key_outlined,
                        ),
                      ],
                    ),

                    // --- Instagram ----------------------------------------------
                    _SettingsSection(
                      icon: Icons.camera_alt_outlined,
                      color: AppTheme.instagramPink,
                      title: 'Instagram Graph API',
                      subtitle: 'Meta for Developers → your app',
                      configured: current.isInstagramConfigured,
                      children: [
                        SecretField(
                          controller: _instagramAppId,
                          label: 'App ID',
                          icon: Icons.apps_outlined,
                          secret: false,
                          keyboardType: TextInputType.number,
                        ),
                        SecretField(
                          controller: _instagramAccessToken,
                          label: 'Access Token',
                          hint: 'EAAG…',
                          helper:
                              'Long-lived token with instagram_content_publish '
                              '(+ pages_read_engagement) permissions.',
                          icon: Icons.key_outlined,
                        ),
                        SecretField(
                          controller: _instagramBusinessAccountId,
                          label: 'Instagram Business Account ID',
                          hint: '17841400000000000',
                          helper:
                              'The {ig-user-id} used by /media and /media_publish. '
                              'Must be a Business or Creator account.',
                          icon: Icons.person_outline,
                          secret: false,
                          keyboardType: TextInputType.number,
                        ),
                      ],
                    ),

                    // --- WhatsApp -----------------------------------------------
                    _SettingsSection(
                      icon: Icons.chat_outlined,
                      color: AppTheme.whatsappGreen,
                      title: 'WhatsApp Agent API',
                      subtitle:
                          'Sends "time reached" / failure alerts and answers "Status"',
                      configured: current.isWhatsAppConfigured,
                      children: [
                        SecretField(
                          controller: _whatsappEndpoint,
                          label: 'Agent endpoint URL',
                          hint: 'https://your-agent.example.com/api',
                          icon: Icons.link_outlined,
                          secret: false,
                          keyboardType: TextInputType.url,
                          validator: _validateUrl,
                        ),
                        SecretField(
                          controller: _whatsappApiKey,
                          label: 'API Key',
                          icon: Icons.key_outlined,
                        ),
                        SecretField(
                          controller: _whatsappRecipient,
                          label: 'Your WhatsApp number',
                          hint: '923001234567',
                          helper:
                              'International format, digits only. Receives the '
                              'notifications.',
                          icon: Icons.phone_android_outlined,
                          secret: false,
                          keyboardType: TextInputType.phone,
                          validator: _validatePhone,
                        ),
                      ],
                    ),

                    // --- Tunnel -------------------------------------------------
                    _SettingsSection(
                      icon: Icons.vpn_lock_outlined,
                      color: scheme.primary,
                      title: 'Tunnel (Instagram bridge)',
                      subtitle:
                          'Instagram needs a public URL. A temporary tunnel exposes '
                          'the on-device video server only while publishing.',
                      configured: current.isTunnelConfigured,
                      children: [
                        SecretField(
                          controller: _ngrokAuthToken,
                          label: 'ngrok auth token',
                          hint: '2abc…_…',
                          helper:
                              'dashboard.ngrok.com → Your Authtoken. Used in Phase 5.',
                          icon: Icons.key_outlined,
                        ),
                      ],
                    ),

                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: provider.isSaving ? null : _save,
                      icon: provider.isSaving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.save_outlined),
                      label: Text(
                        _isDirty ? 'Save changes' : 'Saved',
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

class _PrivacyNote extends StatelessWidget {
  const _PrivacyNote({required this.scheme});

  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: scheme.secondaryContainer,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.lock_outline, color: scheme.onSecondaryContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Keys are stored with flutter_secure_storage (AES-GCM, key held in '
                'the Android Keystore). They never leave this phone and are '
                'excluded from backups. Leave a field empty if you do not use '
                'that platform yet.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSecondaryContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _StatusChip(label: 'YouTube', ok: settings.isYouTubeConfigured),
        _StatusChip(label: 'Instagram', ok: settings.isInstagramConfigured),
        _StatusChip(label: 'WhatsApp', ok: settings.isWhatsAppConfigured),
        _StatusChip(label: 'Tunnel', ok: settings.isTunnelConfigured),
      ],
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, required this.ok});

  final String label;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Chip(
      avatar: Icon(
        ok ? Icons.check_circle : Icons.radio_button_unchecked,
        size: 18,
        color: ok ? const Color(0xFF166534) : scheme.onSurfaceVariant,
      ),
      label: Text(label),
      visualDensity: VisualDensity.compact,
    );
  }
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.configured,
    required this.children,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final bool configured;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: color),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  configured ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: configured
                      ? const Color(0xFF166534)
                      : theme.colorScheme.outline,
                ),
              ],
            ),
            const SizedBox(height: 16),
            ...children,
          ],
        ),
      ),
    );
  }
}
