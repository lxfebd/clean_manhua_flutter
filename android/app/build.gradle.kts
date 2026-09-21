import java.util.Properties
import java.io.FileInputStream
import java.security.MessageDigest

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.xingmanxia.app"
    compileSdk = 36
    // 使用与当前依赖（wakelock_plus / webview_flutter_android / media_kit 等）
    // 声明一致的最高 NDK；Flutter 工具链声明各 NDK 版本向后兼容。
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    // split-per-abi（android/settings.gradle.kts 里未开 splits，走 CLI --split-per-abi 时）
    // 时 Flutter 插件开启 splits.abi，再设 ndk.abiFilters 会与 splits 冲突导致
    // 配置失败，故 split 模式下不注入 abiFilters（split 输出已按 ABI 切开）。
    val splitPerAbi =
        (project.findProperty("split-per-abi")?.toString()?.toBoolean()) ?: false

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.xingmanxia.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // minSdk 需 >=24：cronet_http（JM 源走 Cronet 网络栈）硬性要求 API 24。
        minSdk = maxOf(flutter.minSdkVersion, 24)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // 默认仅打包 arm64-v8a（发布版体积最省，112MB→33.5MB）；
        // debug 构建在下方 buildTypes 中放开全 ABI，保证 x86/x86_64 模拟器可正常测试。
        if (!splitPerAbi) {
            ndk {
                abiFilters += "arm64-v8a"
            }
        }
    }

    packaging {
        jniLibs {
            // F4：librife_cpu.so / libffmpeg.so 是**可执行程序**（以 lib*.so 名义
            // 打包），必须让 PM 把它们抽取到 nativeLibraryDir —— Android 10+
            // 禁止 exec 应用可写目录里的文件，nativeLibraryDir 是唯一可靠
            // exec 路径。extractNativeLibs=false（默认：未压缩直载，PM 不落盘，
            // 目录为空、无法 exec），故强制 useLegacyPackaging。
            useLegacyPackaging = true
        }
    }

    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String?
            keyPassword = keystoreProperties["keyPassword"] as String?
            storeFile = keystoreProperties["storeFile"]?.let { file(it) }
            storePassword = keystoreProperties["storePassword"] as String?
        }
    }

    buildTypes {
        // debug 与 release 统一用同一把 release 签名（key.properties），
        // 保证测试环境能用 GitHub 的 release APK 直接覆盖安装 debug 包，
        // 避免"软件包似乎无效/签名不一致"导致无法更新安装。
        debug {
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // 调试/测试保留全 ABI：x86/x86_64 模拟器、老设备都能跑。
            // split 模式下同样不注（见上方 splitPerAbi 说明），否则与 splits 冲突。
            if (!splitPerAbi) {
                ndk {
                    abiFilters += setOf("arm64-v8a", "armeabi-v7a", "x86", "x86_64")
                }
            }
        }
        release {
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}

// 构建期一致性守卫：校验 jniLibs 打包的演示 .so 与能力插件元数据 SHA256 一致。
// 版本钉死：值来自 Dart 侧 DemoNativePlugin.androidSha256*，变更 .so 必须同步
// 更新，否则构建即失败（fail-fast，杜绝运行期未知版本）。
tasks.register("verifyDemoNativeSha") {
    val expected = mapOf(
        "arm64-v8a" to "8a6524084aa328ccceea9188ac6c1330dcc96165e234ff10fb76139edc8d7076",
        "armeabi-v7a" to "15ed0631996d6bd5f6fa10ffb7c1ca056ee100ed4eaa25053763d03e3ebfd207",
        "x86_64" to "749339d2fb0b2d80d5044fd9f8af7a98d620f498b53b0c8683377f13783faa41",
    )
    doLast {
        expected.forEach { (abi, hash) ->
            val f = file("src/main/jniLibs/$abi/libdemo_math.so")
            if (!f.exists()) {
                throw GradleException("缺 $abi/libdemo_math.so（先跑 test/assets/demo_native/build_android_so.bat）")
            }
            val sha = MessageDigest.getInstance("SHA-256")
                .digest(f.readBytes()).joinToString("") { "%02x".format(it) }
            if (sha != hash) {
                throw GradleException("$abi/libdemo_math.so SHA256 与元数据不一致，需同步更新或重编译")
            }
        }
    }
}

tasks.named("preBuild") {
    dependsOn("verifyDemoNativeSha")
}
