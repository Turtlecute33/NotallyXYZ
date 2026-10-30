@file:OptIn(ExperimentalRoborazziApi::class)

import com.android.build.gradle.internal.tasks.factory.dependsOn
import com.github.takahirom.roborazzi.ExperimentalRoborazziApi

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.parcelize)
    alias(libs.plugins.ksp)
    alias(libs.plugins.ktfmt)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.translations.converter)
    alias(libs.plugins.auto.translation)
    alias(libs.plugins.roborazzi)
    alias(libs.plugins.koin.compiler)
}

android {
    namespace = "com.philkes.notallyx"
    compileSdk = libs.versions.compileSdk.get().toInt()
    ndkVersion = libs.versions.ndk.get()
    defaultConfig {
        applicationId = "com.notallyxyz"
        minSdk = libs.versions.minSdk.get().toInt()
        targetSdk = libs.versions.targetSdk.get().toInt()
        versionCode = project.findProperty("app.versionCode").toString().toInt()
        versionName = project.findProperty("app.versionName").toString()
        androidResources {
            localeFilters +=
                listOf(
                    "en",
                    "ar",
                    "ca",
                    "cs",
                    "da",
                    "de",
                    "el",
                    "es",
                    "fr",
                    "hu",
                    "in",
                    "it",
                    "ja",
                    "my",
                    "nb",
                    "nl",
                    "nn",
                    "pl",
                    "pt-rBR",
                    "pt-rPT",
                    "ro",
                    "ru",
                    "sk",
                    "sv",
                    "tl",
                    "tr",
                    "uk",
                    "vi",
                    "zh-rCN",
                    "zh-rTW",
                )
        }
        vectorDrawables.generatedDensities?.clear()
        ndk {
            debugSymbolLevel = "FULL"
            // Phones with Android 7 or later use ARM. The x86 libraries add about 5.9 MB.
            abiFilters += listOf("arm64-v8a", "armeabi-v7a")
        }
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        testInstrumentationRunnerArguments["clearPackageData"] = "true"
        testOptions {
            animationsDisabled = true
            execution = "ANDROIDX_TEST_ORCHESTRATOR"
        }
    }

    val releaseStoreFile = providers.gradleProperty("RELEASE_STORE_FILE").orNull
    signingConfigs {
        if (releaseStoreFile != null) {
            create("release") {
                storeFile = file(releaseStoreFile)
                storePassword = providers.gradleProperty("RELEASE_STORE_PASSWORD").get()
                keyAlias = providers.gradleProperty("RELEASE_KEY_ALIAS").get()
                keyPassword = providers.gradleProperty("RELEASE_KEY_PASSWORD").get()
            }
        }
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-DEBUG"
            resValue("string", "app_name", "NotallyXYZ DEBUG")
        }
        release {
            isCrunchPngs = false
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            signingConfig = signingConfigs.findByName("release")
        }
        create("beta") {
            initWith(getByName("release"))
            applicationIdSuffix = ".beta"
            versionNameSuffix = "-BETA"
            resValue("string", "app_name", "NotallyXYZ BETA")
        }
    }

    dependenciesInfo {
        includeInApk = false
        includeInBundle = false
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        viewBinding = true
        dataBinding = true
        buildConfig = true
        resValues = true
    }

    packaging {
        resources.excludes +=
            listOf(
                "DebugProbesKt.bin",
                "META-INF/**.version",
                "kotlin/**.kotlin_builtins",
                "kotlin-tooling-metadata.json",
            )
    }

    testOptions { unitTests.isIncludeAndroidResources = true }
}

androidComponents {
    onVariants { variant ->
        val versionName = project.findProperty("app.versionName").toString()
        variant.outputs.forEach { output ->
            output.outputFileName.set("NotallyXYZ-$versionName.apk")
        }
    }
}

ksp {
    arg("room.generateKotlin", "true")
    arg("room.schemaLocation", "$projectDir/schemas")
}

ktfmt { kotlinLangStyle() }

autoTranslate {
    provider = deepL { authKey = providers.gradleProperty("DEEPL_API_KEY") }
    translateStringsXml { enabled = true }
    translateFastlane {
        enabled = false
        targetLanguages = setOf("de-DE", "ru-RU")
    }
}

tasks.preBuild.dependsOn(tasks.exportTranslationsToExcel)

afterEvaluate {
    tasks.named("bundleRelease").configure { dependsOn(tasks.named("testReleaseUnitTest")) }
    tasks.named("assembleRelease").configure { dependsOn(tasks.named("testReleaseUnitTest")) }
}

roborazzi {
    // Directory for reference images
    outputDir.set(file("src/screenshots"))
    compare { outputDir.set(file("build/outputs/screenshots_comparison")) }
}

dependencies {
    implementation(libs.androidx.documentfile)
    implementation(libs.bundles.navigation)
    implementation(libs.androidx.preference)
    ksp(libs.androidx.room.compiler)
    implementation(libs.bundles.room)
    implementation(libs.androidx.security.crypto)
    implementation(libs.androidx.sqlite)
    implementation(libs.androidx.work)
    implementation(libs.androidx.biometric)
    implementation(libs.customactivityoncrash)
    implementation(libs.subsampling.scale.image.view)
    implementation(libs.glide)
    implementation(libs.swipe.drawer)
    implementation(libs.colorpickerview)
    implementation(libs.material)
    implementation(libs.jsr305)
    implementation(libs.fastscroll)
    implementation(libs.zip4j)
    implementation(libs.sqlcipher)
    implementation(libs.kotlinx.serialization)
    implementation(libs.jsoup)
    implementation(libs.prettytime)
    implementation(libs.simple.xml) { exclude(group = "xpp3", module = "xpp3") }
    implementation(libs.bundles.commonmark)

    // Koin
    implementation(platform(libs.koin.bom))
    implementation(libs.koin.core)
    implementation(libs.koin.android)

    androidTestImplementation(libs.androidx.test.uiautomator)
    androidTestImplementation(libs.androidx.test.espresso.core)
    androidTestImplementation(libs.androidx.test.espresso.contrib)
    androidTestImplementation(libs.androidx.test.espresso.intents)
    androidTestImplementation(libs.androidx.test.junit)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.rules)
    androidTestUtil(libs.androidx.test.orchestrator)
    androidTestImplementation(libs.androidx.room.testing)
    androidTestImplementation(libs.androidx.work.testing)

    testImplementation(libs.roborazzi)
    testImplementation(libs.roborazzi.junit.rule)
    testImplementation(libs.androidx.test.espresso.core)
    testImplementation(libs.androidx.test.junit)
    testImplementation(libs.androidx.core.testing)
    testImplementation(libs.androidx.test.core.ktx)
    testImplementation(libs.androidx.test.core)
    testImplementation(libs.mockk)
    testImplementation(libs.junit)
    testImplementation(libs.assertj)
    testImplementation(libs.json)
    testImplementation(libs.mockito.kotlin)
    testImplementation(libs.mockito.core)
    testImplementation(libs.robolectric)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.androidx.test.espresso.contrib)
    testImplementation(libs.koin.test)
    testImplementation(libs.koin.test.junit4)
}
