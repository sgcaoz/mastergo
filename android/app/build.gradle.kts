import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

fun keystoreValue(key: String, envKey: String): String? {
    val fromFile = keystoreProperties.getProperty(key)?.trim()
    if (!fromFile.isNullOrEmpty()) return fromFile
    val fromEnv = System.getenv(envKey)?.trim()
    if (!fromEnv.isNullOrEmpty()) return fromEnv
    return null
}

val releaseStoreFile = keystoreValue("storeFile", "ANDROID_STORE_FILE")
val releaseStorePassword = keystoreValue("storePassword", "ANDROID_STORE_PASSWORD")
val releaseKeyAlias = keystoreValue("keyAlias", "ANDROID_KEY_ALIAS")
val releaseKeyPassword = keystoreValue("keyPassword", "ANDROID_KEY_PASSWORD")
val hasReleaseSigning =
    !releaseStoreFile.isNullOrEmpty() &&
    !releaseStorePassword.isNullOrEmpty() &&
    !releaseKeyAlias.isNullOrEmpty() &&
    !releaseKeyPassword.isNullOrEmpty()

// Phone APKs: 64-bit only. x86_64 is emulator-only and used to bloat the zip.
val packagedAbis = listOf("arm64-v8a")
tasks.register("checkKatagoForRelease") {
    doLast {
        val jniLibsDir = file("src/main/jniLibs")
        val missing = packagedAbis.filter { abi ->
            !file("$jniLibsDir/$abi/libkatago.so").exists()
        }
        if (missing.isNotEmpty()) {
            throw GradleException(
                "Release build requires libkatago.so for packaged ABIs. Missing: ${missing.joinToString()}.\n" +
                "Run once: ABI=all ./scripts/android/build_katago_android.sh"
            )
        }
    }
}
project.afterEvaluate {
    tasks.findByName("bundleRelease")?.dependsOn("checkKatagoForRelease")
    tasks.findByName("assembleRelease")?.dependsOn("checkKatagoForRelease")
}

android {
    namespace = "com.boringtime.mastergo"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.boringtime.mastergo"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            abiFilters.clear()
            abiFilters.addAll(packagedAbis)
        }
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = file(releaseStoreFile!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            if (hasReleaseSigning) {
                signingConfig = signingConfigs.getByName("release")
            } else {
                throw GradleException(
                    "Release signing is not configured. " +
                        "Provide android/key.properties " +
                        "or env vars ANDROID_STORE_FILE, ANDROID_STORE_PASSWORD, " +
                        "ANDROID_KEY_ALIAS, ANDROID_KEY_PASSWORD.",
                )
            }
        }
    }

    // Required: KataGo is run as a subprocess (ProcessBuilder), not loaded via System.loadLibrary().
    // Without this, AAB/Play installs do not extract .so to nativeLibraryDir, so the binary path does not exist.
    packaging {
        jniLibs {
            useLegacyPackaging = true
            excludes += setOf("**/lib/x86/**", "**/lib/x86_64/**")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
}

flutter {
    source = "../.."
}
