class AppLogger {
  const AppLogger();

  void info(String message) {
    // Replace with structured logging before production. Avoid logging personal schedule details.
    assert(() {
      // ignore: avoid_print
      print('[info] $message');
      return true;
    }());
  }

  void warning(String message) {
    assert(() {
      // ignore: avoid_print
      print('[warning] $message');
      return true;
    }());
  }
}
