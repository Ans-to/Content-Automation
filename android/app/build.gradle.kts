plugins {
    id("com.android.application")
    // NOTE: do not add org.jetbrains.kotlin.android here. With AGP 9 the Flutter
    // Gradle Plugin applies Kotlin itself (android.builtInKotlin=false) and warns
    // when the app module applies KGP directly.
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
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

    buildTypes {
        release {
            // Phase 6 wires up a real keystore via key.properties. Until then the
            // release APK is signed with the debug key so it installs on a phone.
            signingConfig = signingConfigs.getByName("debug")
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
