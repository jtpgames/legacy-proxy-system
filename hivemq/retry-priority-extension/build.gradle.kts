plugins {
    java
    id("com.hivemq.extension") version "3.1.0"
}

group = "com.jl"
version = "1.0.0"

java {
    sourceCompatibility = JavaVersion.VERSION_11
    targetCompatibility = JavaVersion.VERSION_11
}

repositories {
    mavenCentral()
}

hivemqExtension {
    name = "Retry Priority Extension"
    author = "JL"
    priority = 0
    startPriority = 1000
    sdkVersion = "4.45.0"
    mainClass = "com.jl.RetryPriorityExtension"
}

tasks.withType<JavaCompile> {
    options.encoding = "UTF-8"
}

