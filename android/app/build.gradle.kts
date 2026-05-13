plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

android {
    namespace = "com.sirkulab.mero"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    packagingOptions {
        // Exclude non-arm64 architectures (arm64-only build)
        excludes.add("lib/x86_64/*.so")
        excludes.add("lib/armeabi-v7a/*.so")

        // MediaPipe LLM JNI bridge — not used, .litertlm goes through FFI directly
        excludes.add("lib/arm64-v8a/libmediapipe_tasks_genai_jni.so")
        excludes.add("lib/arm64-v8a/libllm_inference_engine_jni.so")

        // Embedding models — not used in this app
        excludes.add("lib/arm64-v8a/libgemma_embedding_model_jni.so")
        excludes.add("lib/arm64-v8a/libgecko_embedding_model_jni.so")

        // Image generation — not used in this app
        excludes.add("lib/arm64-v8a/libmediapipe_tasks_vision_image_generator_jni.so")
        excludes.add("lib/arm64-v8a/libimagegenerator_gpu.so")

        // RAG (Retrieval-Augmented Generation) — not used in this app
        excludes.add("lib/arm64-v8a/libtext_chunker_jni.so")
        excludes.add("lib/arm64-v8a/libsqlite_vector_store_jni.so")

        // WebGPU accelerator — not supported on Android, web-only
        excludes.add("lib/arm64-v8a/libLiteRtWebGpuAccelerator.so")
        excludes.add("lib/arm64-v8a/libLiteRtTopKWebGpuSampler.so")
    }

    kotlin {
        jvmToolchain(17)
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.sirkulab.mero"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            abiFilters.add("arm64-v8a")
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

flutter {
    source = "../.."
}
