plugins {
    java
}

group = "com.p10entrancer"
version = "0.1.0"

repositories {
    mavenCentral()
    maven { url = uri("https://maven.bitwig.com") }
}

java {
    toolchain {
        languageVersion = JavaLanguageVersion.of(21)
    }
}

dependencies {
    compileOnly("com.bitwig:extension-api:22")
}

tasks.named<Jar>("jar") {
    archiveBaseName = "P10EBridge"
    archiveExtension = "bwextension"
    destinationDirectory = layout.buildDirectory.dir("bwextension")
    manifest {
        attributes(
            "Bitwig-Extension-Definition-Class" to "com.p10entrancer.bitwig.P10EBridgeExtensionDefinition",
            "Implementation-Title" to "P10 Entrancer Bridge",
            "Implementation-Version" to project.version.toString()
        )
    }
}

tasks.named("build") {
    dependsOn("jar")
}
