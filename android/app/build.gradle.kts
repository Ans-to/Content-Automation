import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // NOTE: do not add org.jetbrains.kotlin.android here. With AGP 9 the Flutter
    // Gradle Plugin applies Kotlin itself (android.builtInKotlin=false) and warns
    // when the app module applies KGP directly.
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// --- Release signing ---------------------------------------------------------
// Google Sign-In (YouTube) only works when the APK is signed with the key whose
// SHA-1 is registered in the Android OAuth client, so every build must use the
// SAME key. Provide it through android/key.properties (never committed):
//
//   storePassword=…
//   keyPassword=…
//   keyAlias=upload
//   storeFile=upload-keystore.jks      # path relative to android/app/
//
// CI writes this file from the ANDROID_KEYSTORE_* repository secrets. Without
// it the APK falls back to the debug key of the machine that builds it.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
}

android {
    namespace = "com.contentautomation.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Register this applicationId (plus your signing SHA-1) in Google Cloud
        // Console when you create the Android OAuth client for YouTube.
        applicationId = "com.contentautomation.app"
        // Flutter's defaults (minSdk 24 / target 36 at the time of writing).
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                // Installable on a phone, but the SHA-1 differs per machine.
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
