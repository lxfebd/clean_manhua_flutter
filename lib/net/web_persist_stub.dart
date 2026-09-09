/// io 端占位：web 持久化仅在 web 使用，io 端调用会直接抛错（不应发生）。
class WebPersist {
  static String? read(String key) =>
      throw UnsupportedError('WebPersist 仅用于 web 端');

  static void write(String key, String value) =>
      throw UnsupportedError('WebPersist 仅用于 web 端');

  static void remove(String key) =>
      throw UnsupportedError('WebPersist 仅用于 web 端');
}