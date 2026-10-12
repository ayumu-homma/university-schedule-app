String redactPersonalData(String input) {
  if (input.length <= 4) return '****';
  return '${input.substring(0, 2)}****${input.substring(input.length - 2)}';
}
