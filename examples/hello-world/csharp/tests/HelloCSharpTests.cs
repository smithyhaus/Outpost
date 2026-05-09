// hello-world-csharp smoke tests (xUnit + WebApplicationFactory).
// Phase 2: add a separate Tests.csproj that references HelloCSharp.csproj
// and flip outpost.test.yaml runner.command to `dotnet test`.
using Microsoft.AspNetCore.Mvc.Testing;
using System.Net;
using Xunit;

public class HelloCSharpTests : IClassFixture<WebApplicationFactory<Program>>
{
    private readonly WebApplicationFactory<Program> _factory;

    public HelloCSharpTests(WebApplicationFactory<Program> factory)
    {
        _factory = factory;
    }

    [Fact]
    public async Task HealthzReturnsOk()
    {
        var client = _factory.CreateClient();
        var response = await client.GetAsync("/healthz");
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        var body = await response.Content.ReadAsStringAsync();
        Assert.Contains("ok", body);
    }

    [Fact]
    public async Task RootReturnsGreeting()
    {
        var client = _factory.CreateClient();
        var response = await client.GetAsync("/");
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        var body = await response.Content.ReadAsStringAsync();
        Assert.Contains("Hello from C#", body);
    }
}
