using System.Collections.Concurrent;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace VSLive.Samples.LightTheLight;

public class WebSocketRequestHandler
{
    private readonly ConcurrentDictionary<string, WebSocket> _connections = new();
    private readonly LightsPlugin _lightsPlugin;
    private readonly ILogger<WebSocketRequestHandler> _logger;

    public WebSocketRequestHandler(LightsPlugin lightsPlugin, ILogger<WebSocketRequestHandler> logger)
    {
        _lightsPlugin = lightsPlugin;
        _logger = logger;
    }

    public async Task HandleWebSocketConnection(WebSocket webSocket, string connectionId)
    {
        _connections[connectionId] = webSocket;
        _logger.LogInformation($"WebSocket connection established: {connectionId}");

        var buffer = new byte[1024 * 4];
        
        try
        {
            while (webSocket.State == WebSocketState.Open)
            {
                var result = await webSocket.ReceiveAsync(new ArraySegment<byte>(buffer), CancellationToken.None);
                
                if (result.MessageType == WebSocketMessageType.Text)
                {
                    var message = Encoding.UTF8.GetString(buffer, 0, result.Count);
                    _logger.LogInformation($"Received WebSocket message: {message}");

                    var request = JsonSerializer.Deserialize<WebSocketRequest>(message);
                    
                    await HandleWebSocketRequest(webSocket, request);
                }
                else if (result.MessageType == WebSocketMessageType.Close)
                {
                    _logger.LogInformation($"WebSocket connection closed: {connectionId}");
                    break;
                }
            }
        }
        catch (Exception ex)
        {
            _logger.LogError($"WebSocket error for connection {connectionId}: {ex.Message}");
        }
        finally
        {
            _connections.TryRemove(connectionId, out _);
            _logger.LogInformation($"WebSocket connection removed: {connectionId}");
            if (webSocket.State == WebSocketState.Open)
            {
                await webSocket.CloseAsync(WebSocketCloseStatus.NormalClosure, "", CancellationToken.None);
            }
        }
    }

    private async Task HandleWebSocketRequest(WebSocket webSocket, WebSocketRequest? request)
    {
        if (request == null) 
        {
            _logger.LogWarning("Received null WebSocket request");
            return;
        }

        _logger.LogInformation($"Processing WebSocket request: Action={request.Action}, Id={request.Id}, State={request.State}");

        try
        {
            switch (request.Action?.ToLowerInvariant())
            {
                case "getlights":
                    _logger.LogInformation("Handling getLights request");
                    var lights = _lightsPlugin.GetLights();
                    _logger.LogInformation($"Found {lights.Count} lights");
                    var response = new { type = "lightsUpdate", lights = lights };
                    var responseJson = JsonSerializer.Serialize(response);
                    _logger.LogInformation($"Sending response: {responseJson}");
                    await SendWebSocketMessage(webSocket, responseJson);
                    break;

                case "togglelight":
                    _logger.LogInformation("Handling toggleLight request");
                    if (request.Id.HasValue && !string.IsNullOrEmpty(request.State))
                    {
                        var newState = request.State.ToLowerInvariant() == "on" ? 
                            LightsPlugin.LightState.On : LightsPlugin.LightState.Off;
                        
                        var result = _lightsPlugin.ChangeState(request.Id.Value, newState);
                        _logger.LogInformation($"Light state changed: {result?.Name} -> {newState}");

                        // Broadcast update to all clients
                        await BroadcastLightUpdate();
                    }
                    else
                    {
                        _logger.LogWarning("Invalid toggleLight request - missing Id or State");
                    }
                    break;

                default:
                    _logger.LogWarning($"Unknown WebSocket action: {request.Action}");
                    break;
            }
        }
        catch (Exception ex)
        {
            _logger.LogError($"Error handling WebSocket request: {ex.Message}");
        }
    }

    private async Task SendWebSocketMessage(WebSocket webSocket, string message)
    {
        if (webSocket.State == WebSocketState.Open)
        {
            _logger.LogInformation($"Sending WebSocket message: {message}");
            var buffer = Encoding.UTF8.GetBytes(message);
            await webSocket.SendAsync(new ArraySegment<byte>(buffer), WebSocketMessageType.Text, true, CancellationToken.None);
        }
        else
        {
            _logger.LogWarning($"Cannot send message - WebSocket state is {webSocket.State}");
        }
    }

    public async Task BroadcastLightUpdate()
    {
        var lights = _lightsPlugin.GetLights();
        var message = JsonSerializer.Serialize(new { type = "lightsUpdate", lights = lights });
        
        var tasks = new List<Task>();
        
        foreach (var kvp in _connections.ToArray())
        {
            var webSocket = kvp.Value;
            if (webSocket.State == WebSocketState.Open)
            {
                tasks.Add(SendWebSocketMessage(webSocket, message));
            }
            else
            {
                _connections.TryRemove(kvp.Key, out _);
            }
        }
        
        if (tasks.Count > 0)
        {
            await Task.WhenAll(tasks);
        }
    }

    public int ActiveConnections => _connections.Count;
}

public class WebSocketRequest
{
    [JsonPropertyName("action")]
    public string? Action { get; set; }
    
    [JsonPropertyName("id")]
    public int? Id { get; set; }
    
    [JsonPropertyName("state")]
    public string? State { get; set; }
}
