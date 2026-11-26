# youtubedl-android loads its JSON models and helpers by reflection; R8 would strip or rename them
# and the first call into the library then fails with ExceptionInInitializerError.
-keep class com.yausername.** { *; }
-keep class com.fasterxml.jackson.** { *; }
-dontwarn com.fasterxml.jackson.**
-keep class org.apache.commons.io.** { *; }
-dontwarn org.apache.commons.compress.**
-dontwarn org.apache.commons.io.**
