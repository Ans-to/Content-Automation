// Mirrors the Flutter 3.47 plugin template. The Flutter Gradle plugin applies
// the Kotlin plugin to this module itself (android.builtInKotlin=false), so
// org.jetbrains.kotlin.android must not be applied here.
group = "com.contentautomation.platform_bridge"
version = "0.1.0"

plugins {
    id("com.android.library")
}

android {
    namespace = "com.contentautomation.platform_bridge"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
    }

    defaultConfig {
        minSdk = 24
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.15.0")
}
