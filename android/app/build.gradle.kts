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

android {
    namespace = "com.boringtime.mastergo"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.boringtime.mastergo"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
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

}

dependencies {
}

flutter {
    source = "../.."
}
