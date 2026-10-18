plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

val buildNumber = (System.getenv("BUILD_NUMBER") ?: "1").toInt()

android {
    namespace = "com.wolfiegoesai.chipburner"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.wolfiegoesai.chipburner"
        minSdk = 26
        targetSdk = 34
        versionCode = buildNumber
        versionName = System.getenv("APP_VERSION") ?: "0.1.$buildNumber"
        buildConfigField("String", "COMMIT", "\"${System.getenv("GITHUB_SHA")?.take(7) ?: "local"}\"")
        buildConfigField("String", "BUILD_DATE", "\"${System.getenv("BUILD_DATE") ?: ""}\"")
        ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64") }
    }

    signingConfigs {
        create("release") {
            storeFile = file("../keystore/chipburner.jks")
            storePassword = "chipburner"
            keyAlias = "chipburner"
            keyPassword = "chipburner"
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("release")
        }
        debug {
            signingConfig = signingConfigs.getByName("release")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    // minipro is an executable packed as libminipro.so: it must be extracted to the native library
    // folder (the one place an app may run a program from).
    packaging {
        jniLibs { useLegacyPackaging = true }
    }
    androidResources { noCompress += listOf("xml") }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.09.03")
    implementation(composeBom)
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.activity:activity-compose:1.9.2")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.6")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.6")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-core")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
}
