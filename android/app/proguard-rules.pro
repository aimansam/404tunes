# R8 rules for youtubedl-android. Flutter loads this file for release builds.

# The library unzips Python and ffmpeg with commons-compress, which creates its zip "extra field" classes by
# reflection. Without their no-arg constructors the first run fails with "class ... is not a concrete class".
-keep class org.apache.commons.compress.archivers.zip.** { *; }
-dontwarn org.apache.commons.compress.**

# The library itself, and Jackson, which maps yt-dlp's JSON onto its classes by reflection.
-keep class com.yausername.** { *; }
-keep class com.fasterxml.jackson.** { *; }
-dontwarn com.fasterxml.jackson.**
-keep class org.apache.commons.io.** { *; }
-dontwarn org.apache.commons.io.**
