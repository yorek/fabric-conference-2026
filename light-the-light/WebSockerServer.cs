using Microsoft.Extensions.FileProviders;
using VSLive.Samples.LightTheLight;

public class WebSocketServer
{
    private readonly WebApplication webApp;
    private readonly WebSocketRequestHandler webSocketHandler;
    private CancellationTokenSource? _cancellationTokenSource;
    private Task? _serverTask;

    public WebSocketServer(LightsPlugin lightsPlugin)
    {
        // Create web application
        var app = WebApplication.CreateBuilder();

        // Configure host options for faster shutdown
        app.Services.Configure<HostOptions>(opts => 
        {
            opts.ShutdownTimeout = TimeSpan.FromSeconds(5);
        });

        // Register services for dependency injection
        app.Services.AddSingleton(lightsPlugin);
        app.Services.AddSingleton<WebSocketRequestHandler>();
        
        // Configure logging to None
        app.Services.AddLogging(builder =>
        {
            builder.SetMinimumLevel(LogLevel.None);
            builder.ClearProviders();
        });

        // Create App
        webApp = app.Build();

        // Get the web socket handler from DI
        webSocketHandler = webApp.Services.GetRequiredService<WebSocketRequestHandler>();


        // Enable WebSocket support
        webApp.UseWebSockets();

        // Serve static files from client directory
        webApp.UseStaticFiles(new StaticFileOptions
        {
            FileProvider = new PhysicalFileProvider(
                Path.Combine(Directory.GetCurrentDirectory(), "client")),
            RequestPath = ""
        });

        // WebSocket endpoint
        webApp.Map("/ws", async (HttpContext context) =>
        {
            if (context.WebSockets.IsWebSocketRequest)
            {
                var webSocket = await context.WebSockets.AcceptWebSocketAsync();
                var connectionId = Guid.NewGuid().ToString();

                await webSocketHandler.HandleWebSocketConnection(webSocket, connectionId);
            }
            else
            {
                context.Response.StatusCode = 400;
            }
        });

        // Default route to serve index.html
        webApp.MapGet("/", async context =>
        {
            var indexPath = Path.Combine(Directory.GetCurrentDirectory(), "client", "index.html");
            if (File.Exists(indexPath))
            {
                var content = await File.ReadAllTextAsync(indexPath);
                context.Response.ContentType = "text/html";
                await context.Response.WriteAsync(content);
            }
            else
            {
                context.Response.StatusCode = 404;
                await context.Response.WriteAsync("index.html not found");
            }
        });
    }

    public Task StartAsync(string url)
    {
        // Set up cancellation token for graceful shutdown
        _cancellationTokenSource = new CancellationTokenSource();
        Console.CancelKeyPress += OnCancelKeyPress;

        _serverTask = Task.Run(async () =>
        {
            try
            {
                Console.WriteLine("🌐 Web server started at " + url);
                //Console.WriteLine("🔌 WebSocket endpoint available at " + url.Replace("http", "ws") + "/ws");
                //Console.WriteLine("💻 Open " + url + " in your browser to monitor and control the lights via web interface");

                await webApp.RunAsync(url);
            }
            catch (OperationCanceledException)
            {
                // Expected when cancellation is requested
                Console.WriteLine("🛑 Server shutdown initiated...");
            }
            catch (Exception ex)
            {
                Console.WriteLine($"❌ Server error: {ex.Message}");
            }
        }, _cancellationTokenSource.Token);

        return _serverTask;
    }

    private void OnCancelKeyPress(object? sender, ConsoleCancelEventArgs e)
    {
        Console.WriteLine("\n🛑 Shutdown requested...");
        e.Cancel = true; // Prevent immediate termination
        _cancellationTokenSource?.Cancel(); // Signal for graceful shutdown
    }

    public async Task StopAsync()
    {
        Console.WriteLine("🛑 Shutting down gracefully...");

        // Unregister the console cancel event
        Console.CancelKeyPress -= OnCancelKeyPress;

        // Cancel the cancellation token to signal shutdown
        _cancellationTokenSource?.Cancel();

        // Stop the web server
        await webApp.StopAsync();

        // Wait for the server task to complete (with timeout)
        if (_serverTask != null)
        {
            try 
            {
                await _serverTask.WaitAsync(TimeSpan.FromSeconds(5));
            }
            catch (TimeoutException)
            {
                Console.WriteLine("⚠️ Server shutdown timed out - forcing exit");
            }
        }

        // Clean up
        _cancellationTokenSource?.Dispose();
        _cancellationTokenSource = null;
        _serverTask = null;

        Console.WriteLine("✅ Shutdown complete");
    }

    public async Task BroadcastLightUpdateAsync()
    {        
        await webSocketHandler.BroadcastLightUpdate();
    }

    public bool IsCancellationRequested => _cancellationTokenSource?.Token.IsCancellationRequested ?? false;
}
