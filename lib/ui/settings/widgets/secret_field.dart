import 'package:flutter/material.dart';

/// Text field for API keys / tokens: obscured by default with a reveal toggle,
/// no autocorrect or suggestions so the keyboard never learns the secret.
class SecretField extends StatefulWidget {
  const SecretField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.helper,
    this.icon,
    this.secret = true,
    this.enabled = true,
    this.keyboardType,
    this.validator,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final String? helper;
  final IconData? icon;

  /// When `false` the field behaves like a normal text field (e.g. an ID).
  final bool secret;
  final bool enabled;
  final TextInputType? keyboardType;
  final FormFieldValidator<String>? validator;

  @override
  State<SecretField> createState() => _SecretFieldState();
}

class _SecretFieldState extends State<SecretField> {
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    final obscure = widget.secret && !_revealed;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextFormField(
        controller: widget.controller,
        enabled: widget.enabled,
        obscureText: obscure,
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: obscure
            ? TextInputType.visiblePassword
            : (widget.keyboardType ?? TextInputType.text),
        validator: widget.validator,
        decoration: InputDecoration(
          labelText: widget.label,
          hintText: widget.hint,
          helperText: widget.helper,
          helperMaxLines: 3,
          prefixIcon: widget.icon == null ? null : Icon(widget.icon),
          suffixIcon: widget.secret
              ? IconButton(
                  tooltip: _revealed ? 'Hide' : 'Show',
                  onPressed: () => setState(() => _revealed = !_revealed),
                  icon: Icon(
                    _revealed
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                  ),
                )
              : null,
        ),
      ),
    );
  }
}
