var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

app.MapGet("/", () => Results.Text(
    "Hello from C#!\n\n" +
    "If you see this through your Outpost domain, the full-mode CI/CD\n" +
    "pipeline is working: git push -> Tekton build -> registry ->\n" +
    "ArgoCD sync -> Traefik -> here.\n",
    "text/plain"));

app.MapGet("/healthz", () => Results.Text("ok\n", "text/plain"));

app.Run("http://0.0.0.0:8080");
