import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../config/app_constants.dart';

class RoomCodeInput extends StatelessWidget {
  final TextEditingController controller;
  final String? errorText;

  const RoomCodeInput({
    super.key,
    required this.controller,
    this.errorText,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      maxLength: AppConstants.roomCodeLength,
      textCapitalization: TextCapitalization.characters,
      textAlign: TextAlign.center,
      style: const TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.bold,
        letterSpacing: 6,
      ),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp('[a-zA-Z0-9]')),
        UpperCaseTextFormatter(),
      ],
      decoration: InputDecoration(
        hintText: 'ENTER CODE',
        hintStyle: TextStyle(
          color: Colors.white.withValues(alpha: 0.3),
          letterSpacing: 4,
        ),
        counterText: '',
        errorText: errorText,
      ),
    );
  }
}

class UpperCaseTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    return TextEditingValue(
      text: newValue.text.toUpperCase(),
      selection: newValue.selection,
    );
  }
}
