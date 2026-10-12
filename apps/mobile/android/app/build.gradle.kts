import java.util.Properties
import java.util.Base64
import java.security.MessageDigest

fun sha256Hex(value: String): String = MessageDigest.getInstance("SHA-256")
    .digest(value.toByteArray(Charsets.UTF_8))
    .joinToString("") { byte -> "%02x".format(byte) }

val flutterDartDefines = (project.findProperty("dart-defines") as String?)
    .orEmpty()
    .split(',')
    .filter { it.isNotBlank() }
    .mapNotNull { encoded ->
        runCatching {
            String(Base64.getDecoder().decode(encoded), Charsets.UTF_8)
        }.getOrNull()
    }
    .mapNotNull { entry ->
        val separator = entry.indexOf('=')
        if (separator <= 0) null else entry.substring(0, separator) to entry.substring(separator + 1)
    }
    .toMap()

fun nativeConfigStamp(flavor: String, defaultScheme: String): String {
    // Keep the Dart environment defaults and raw define distinctions visible
    // to the pre-Dart fence. A staging APK with omitted APP_ENV is therefore
    // different from one configured for staging, and malformed/alternate
    // boolean spellings cannot silently reuse the old native scope.
    val environment = flutterDartDefines["APP_ENV"] ?: "local"
    val mode = flutterDartDefines["APP_DEMO_MODE"] ?: "false"
    val origin = flutterDartDefines["SUPABASE_URL"] ?: ""
    return "storage-config-v1:" + sha256Hex(
        listOf(environment, mode, origin, flavor, defaultScheme).joinToString("|")
    )
}

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseSigningPropertiesFile = rootProject.file("key.properties")
val releaseSigningProperties = Properties()
val releaseSigningPropertyNames = listOf(
    "storeFile",
    "storePassword",
    "keyAlias",
    "keyPassword",
)
val releaseSigningRequested = releaseSigningPropertiesFile.isFile

if (releaseSigningRequested) {
    releaseSigningPropertiesFile.inputStream().use(releaseSigningProperties::load)
    val missingReleaseSigningProperties = releaseSigningPropertyNames.filter { name ->
        releaseSigningProperties.getProperty(name)?.trim().isNullOrEmpty()
    }
    require(missingReleaseSigningProperties.isEmpty()) {
        "key.properties is incomplete; missing: " +
            missingReleaseSigningProperties.joinToString(", ")
    }

    val configuredStoreFile = rootProject.file(
        releaseSigningProperties.getProperty("storeFile").trim(),
    )
    require(configuredStoreFile.isFile) {
        "key.properties storeFile does not reference an existing file."
    }
}

android {
    namespace = "jp.universityschedule.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "jp.universityschedule.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        externalNativeBuild {
            cmake {
                arguments += "-DANDROID_STL=c++_shared"
            }
        }
    }

    flavorDimensions += "environment"
    productFlavors {
        create("staging") {
            dimension = "environment"
            applicationIdSuffix = ".staging"
            versionNameSuffix = "-staging"
            manifestPlaceholders["appLabel"] = "Uni Schedule (Staging)"
            manifestPlaceholders["authScheme"] = "unischedule-staging"
            buildConfigField("String", "DEEP_LINK_SCHEME", "\"unischedule-staging\"")
            buildConfigField("String", "STORAGE_CONFIG_STAMP", "\"${nativeConfigStamp("staging", "unischedule-staging")}\"")
        }
        create("production") {
            dimension = "environment"
            manifestPlaceholders["appLabel"] = "Uni Schedule"
            manifestPlaceholders["authScheme"] = "unischedule"
            buildConfigField("String", "DEEP_LINK_SCHEME", "\"unischedule\"")
            buildConfigField("String", "STORAGE_CONFIG_STAMP", "\"${nativeConfigStamp("production", "unischedule")}\"")
        }
    }

    buildFeatures {
        buildConfig = true
    }

    signingConfigs {
        if (releaseSigningRequested) {
            create("release") {
                storeFile = rootProject.file(
                    releaseSigningProperties.getProperty("storeFile").trim(),
                )
                storePassword = releaseSigningProperties.getProperty("storePassword")
                keyAlias = releaseSigningProperties.getProperty("keyAlias")
                keyPassword = releaseSigningProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // Internal testing keeps R8 disabled until a signed release smoke test
            // covers reflection-heavy Flutter plugins and its mapping artifact.
            isMinifyEnabled = false
            isShrinkResources = false

            // A release is signed only when the ignored external properties file
            // is complete and its keystore exists. An absent file deliberately
            // produces an unsigned bundle for local contract checks. Never fall
            // back to the Android debug key.
            if (releaseSigningRequested) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }

    testOptions {
        unitTests.isIncludeAndroidResources = true
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

dependencies {
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.16.1")
}

// Flutter's asset copy task and AGP 9's host-test packaging task share the
// merged asset directory. Declare the ordering explicitly so Gradle's strict
// work validation can safely run the app module's Robolectric tests.
tasks.matching {
    it.name == "packageStagingDebugUnitTestForUnitTest" ||
        it.name == "packageProductionDebugUnitTestForUnitTest"
}.configureEach {
    val flavorName = if (name.contains("Staging")) "Staging" else "Production"
    dependsOn("copyFlutterAssets${flavorName}Debug")
}
