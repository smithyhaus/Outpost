# hello-csharp

ASP.NET Core 8 minimal API for smoke-testing the Outpost CI/CD pipeline.

- Single `Program.cs`, no controllers, no DI ceremony
- Listens on `0.0.0.0:8080` (set via `ASPNETCORE_URLS` env)
- Final image: `mcr.microsoft.com/dotnet/aspnet:8.0-alpine` (~110 MB)

## Local sanity check

```bash
docker build -t hello-csharp:dev .
docker run --rm -p 8080:8080 hello-csharp:dev
curl http://localhost:8080/         # → Hello from C#! ...
curl http://localhost:8080/healthz  # → ok
```

## Push as your application repo

```bash
git init && git checkout -b main
git add .
git commit -m "init: hello-csharp"
git remote add origin https://gitee.com/<you>/hello-csharp.git
git push -u origin main
```

Full smoke-test walkthrough: `../README.md`.
