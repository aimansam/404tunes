/// A `major.minor.patch` app version, as used in release tags (`v1.2.3`).
class Version implements Comparable<Version> {
  const Version(this.major, this.minor, this.patch);

  final int major, minor, patch;

  static final _pattern = RegExp(r'^v?(\d{1,4})\.(\d{1,4})\.(\d{1,4})$');

  /// Null for anything that is not exactly `1.2.3` or `v1.2.3` (so odd or pre-release tags are ignored).
  static Version? tryParse(String text) {
    final m = _pattern.firstMatch(text);
    return m == null ? null : Version(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
  }

  @override
  int compareTo(Version o) => major != o.major
      ? major.compareTo(o.major)
      : minor != o.minor
          ? minor.compareTo(o.minor)
          : patch.compareTo(o.patch);

  bool operator >(Version o) => compareTo(o) > 0;

  @override
  bool operator ==(Object other) => other is Version && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch);

  @override
  String toString() => '$major.$minor.$patch';
}
