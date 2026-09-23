allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// Fix: một số plugin cũ (vd. flutter_pos_printer_platform_image_3) tự pin compileSdk
// thấp (31), gây lỗi AAR metadata với các thư viện AndroidX mới hơn.
// Ép toàn bộ subproject build cùng compileSdk 36 để đồng bộ.
subprojects {
    // ":app" đã tự evaluate sớm ở trên (evaluationDependsOn) và đã có compileSdk 36
    // đúng rồi nên bỏ qua, tránh lỗi "already evaluated". Các module plugin khác
    // (vd. flutter_pos_printer_platform_image_3 tự pin compileSdk 31 trong build.gradle
    // riêng của nó) thì override lại SAU khi script gốc của nó chạy xong.
    if (name != "app") {
        afterEvaluate {
            extensions.findByType(com.android.build.gradle.BaseExtension::class.java)?.compileSdkVersion(36)
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
