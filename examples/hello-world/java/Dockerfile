# syntax=docker/dockerfile:1
# ============================================================================
# Hello-Java — Spring Boot 3 + Java 21
# Two-stage Maven -> JRE-alpine. Final image ~190 MB (JRE dominates).
# ============================================================================
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /src
# Cache deps when only sources change.
COPY pom.xml ./
RUN mvn -B -q dependency:go-offline
COPY src ./src
RUN mvn -B -q -DskipTests clean package

FROM eclipse-temurin:21-jre-alpine
WORKDIR /app
COPY --from=build /src/target/app.jar /app/app.jar
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s CMD wget -qO- http://127.0.0.1:8080/healthz || exit 1
# -XX:MaxRAMPercentage so the JVM respects the cgroup memory limit
ENTRYPOINT ["sh", "-c", "exec java -XX:MaxRAMPercentage=75 -jar /app/app.jar"]
