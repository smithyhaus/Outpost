# hello-java

Spring Boot 3.3 + Java 21 for smoke-testing the Outpost CI/CD pipeline.

- Single `HelloApplication.java`, two endpoints
- Maven build, packaged as a fat jar (`target/app.jar`)
- Final image: `eclipse-temurin:21-jre-alpine` (~190 MB)
- JVM uses `MaxRAMPercentage=75` so it respects the K8s memory limit

> First-time Maven build pulls a lot of deps (~2-3 minutes inside Tekton).
> Subsequent builds are much faster because of the dependency cache layer.

## Local sanity check

```bash
docker build -t hello-java:dev .
docker run --rm -p 8080:8080 hello-java:dev
# Wait ~5-10s for Spring Boot to start
curl http://localhost:8080/         # → Hello from Java! ...
curl http://localhost:8080/healthz  # → ok
```

## Push as your application repo

```bash
git init && git checkout -b main
git add .
git commit -m "init: hello-java"
git remote add origin https://gitee.com/<you>/hello-java.git
git push -u origin main
```

Full smoke-test walkthrough: `../README.md`.
