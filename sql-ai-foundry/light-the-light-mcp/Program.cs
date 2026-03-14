using Microsoft.Extensions.FileProviders;
using Samples.LightTheLight.Mcp;

var builder = WebApplication.CreateBuilder(args);

// Register shared services
builder.Services.AddSingleton<Lights>();
builder.Services.AddSingleton<WebSocketRequestHandler>();

// Add MCP server with HTTP transport
builder.Services
    .AddMcpServer(options =>
    {
        options.ServerInfo = new() { Name = "Light the Light", Version = "1.0.0" };
    })
    .WithHttpTransport()
    .WithTools<LightsTools>();

var app = builder.Build();

// Enable WebSocket support
app.UseWebSockets();

// Serve static files from client directory
app.UseStaticFiles(new StaticFileOptions
{
    FileProvider = new PhysicalFileProvider(
        Path.Combine(Directory.GetCurrentDirectory(), "client")),
    RequestPath = ""
});

// MCP endpoint
app.MapMcp("/mcp");

// WebSocket endpoint for the web UI
app.Map("/ws", async (HttpContext context) =>
{
    if (context.WebSockets.IsWebSocketRequest)
    {
        var webSocket = await context.WebSockets.AcceptWebSocketAsync();
        var connectionId = Guid.NewGuid().ToString();
        var handler = context.RequestServices.GetRequiredService<WebSocketRequestHandler>();
        await handler.HandleWebSocketConnection(webSocket, connectionId);
    }
    else
    {
        context.Response.StatusCode = 400;
    }
});

// Default route to serve index.html
app.MapGet("/", async context =>
{
    var indexPath = Path.Combine(Directory.GetCurrentDirectory(), "client", "index.html");
    if (File.Exists(indexPath))
    {
        context.Response.ContentType = "text/html";
        await context.Response.SendFileAsync(indexPath);
    }
    else
    {
        context.Response.StatusCode = 404;
        await context.Response.WriteAsync("index.html not found");
    }
});

Console.WriteLine("💡 Light the Light - MCP Server");
Console.WriteLine("🌐 Server running at http://localhost:5000");
Console.WriteLine("📡 MCP endpoint: http://localhost:5000/mcp");
Console.WriteLine("🔌 WebSocket: ws://localhost:5000/ws");
Console.WriteLine("💻 Web UI: http://localhost:5000");
Console.WriteLine();
Console.WriteLine("Waiting for MCP calls...");

app.Run("http://localhost:5000");