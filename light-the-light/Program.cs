// Import packages
using Microsoft.SemanticKernel;
using Microsoft.SemanticKernel.ChatCompletion;
using Microsoft.SemanticKernel.Connectors.OpenAI;
using Azure.Identity;
using Azure.AI.OpenAI;
using Azure;
using DotNetEnv;
using System.Text.Json;
using OpenTelemetry.Logs;
using OpenTelemetry.Metrics;
using OpenTelemetry.Trace;
using Microsoft.Extensions.Logging;
using System.Text.RegularExpressions;

// Welcome message
Console.WriteLine("💡 Light the Light ");
Console.WriteLine("🤖 I'm here to help you control your lights!");

// Load .env
Env.Load();

var deploymentName = Env.GetString("AZURE_OPENAI_CHAT_DEPLOYMENT_NAME") ?? string.Empty;
var endpoint = Env.GetString("AZURE_OPENAI_ENDPOINT") ?? string.Empty;
var apiKey = Env.GetString("AZURE_OPENAI_KEY") ?? string.Empty;
var applicationInsightsConnectionString = Env.GetString("APPLICATION_INSIGHTS_CONNECTION_STRING") ?? string.Empty;

if (new string[] { deploymentName, endpoint }.Contains(string.Empty))
{
    Console.WriteLine("⚠️ Missing required environment variables. Please check your .env file.");
    return;
}

// Where log is sent to console or not
var logToConsole = false;

// Create a kernel with Azure OpenAI chat completion
var builder = Kernel.CreateBuilder();

// Create the Azure OpenAI client
AzureOpenAIClient azureClient = apiKey switch
{
    null or "" => new(new Uri(endpoint), new DefaultAzureCredential()),
    _ => new(new Uri(endpoint), new AzureKeyCredential(apiKey))
};

// Add Azure OpenAI chat completion
builder.AddAzureOpenAIChatCompletion(deploymentName, azureClient);

// Enable Application Insights telemetry
if (!string.IsNullOrEmpty(applicationInsightsConnectionString))
{
    var loggerFactory = ApplicationInsightsTelemetry.Configure(applicationInsightsConnectionString);
    builder.Services.AddSingleton(loggerFactory);
}
else
{
    Console.WriteLine("⚠️  Application Insights connection string is not set. Telemetry is disabled.");
    builder.Services.AddLogging(services =>
    {
        // services.AddConsole(options =>
        // {
        //     options.LogToStandardErrorThreshold = LogLevel.None; // Prevent duplicate output
        // });
        services.AddProvider(new CustomSemanticKernelLoggerProvider());
        services.SetMinimumLevel(LogLevel.Information);
    });
    logToConsole = true;
}

// Build the kernel
Kernel kernel = builder.Build();

// Get the services
var chatCompletionService = kernel.GetRequiredService<IChatCompletionService>();

// Add the lights plugin 
var lightsPlugin = new LightsPlugin();
kernel.Plugins.AddFromObject(lightsPlugin);

// List the available plugins
Console.WriteLine("🤖 Functions (or tools) I can use:");
foreach (var plugin in kernel.Plugins)
{
    Console.WriteLine($"\t{plugin.Name}: " + string.Join(", ", plugin.Select(f => f.Name)));
}

// Enable planning
OpenAIPromptExecutionSettings openAIPromptExecutionSettings = new()
{
    FunctionChoiceBehavior = FunctionChoiceBehavior.Auto()
};

// Start the web socket server
WebSocketServer webSocketServer = new(lightsPlugin);
Task webSocketServerTask = webSocketServer.StartAsync("http://localhost:5000");

// Create a history store the conversation
var history = new ChatHistory();

history.AddSystemMessage("""
You are a helpful home assistant. You can turn lights on and off, add new lights, and remove lights. Use the available functions to perform these actions.
If the user ask for something that is not related to lights, respond that you are a home assistant and can only help with lights.
""");

// Initiate a back-and-forth chat
string? userInput;
Console.WriteLine("🚀 Ready! Type your message below (or /exit to quit, /history to see the chat history):");
do
{
    // Check if cancellation was requested
    if (webSocketServer.IsCancellationRequested)
    {
        Console.WriteLine("🛑 Shutting down due to cancellation request...");
        break;
    }

    // Collect user input
    Console.Write("🧑 > ");
    userInput = Console.ReadLine();
    
    if (userInput is "/exit" or "/quit")
    {
        break;
    }
    
    if (userInput is "/clear") {
        Console.Clear();
        continue;
    }

    if (userInput is "/history")
    {
        foreach (var message in history)
        {
            Console.WriteLine($"HISTORY> {message.Role}: {message.Content}");

            if (message.Metadata != null && message.Metadata.Count > 0)
            {
                var metadataJson = JsonSerializer.Serialize(message.Metadata, new JsonSerializerOptions
                {
                    WriteIndented = true
                });
                Console.WriteLine($"HISTORY> Metadata:");
                Console.WriteLine(metadataJson);
            }
        }

        continue;
    }

    if (!string.IsNullOrEmpty(userInput))
    {
        // Add user input
        history.AddUserMessage(userInput);

        // Get the streaming response from the AI
        Console.Write("🤔 thinking...");
        if (logToConsole) Console.WriteLine();
        string fullResponse = string.Empty;
        bool responseStarted = false;
        await foreach (var streamingResult in chatCompletionService.GetStreamingChatMessageContentsAsync(
            history,
            executionSettings: openAIPromptExecutionSettings,
            kernel: kernel))
        {
            if (!string.IsNullOrEmpty(streamingResult.Content))
            {
                if (!responseStarted)
                {
                    if (!logToConsole) Console.WriteLine();
                    Console.Write("🤖 > ");
                    responseStarted = true;
                }
            }
            else
            {
                if (!logToConsole) Console.Write(".");
            }

            Console.Write(streamingResult.Content);
            fullResponse += streamingResult.Content;
        }
        Console.WriteLine();

        // Add the complete message from the agent to the chat history
        history.AddAssistantMessage(fullResponse);

        // Notify the web app about the light state change
        await webSocketServer.BroadcastLightUpdateAsync();
    }
} while (userInput is not null && !webSocketServer.IsCancellationRequested);

// Stop the web server
await webSocketServer.StopAsync();