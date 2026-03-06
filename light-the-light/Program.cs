// Import packages
using Azure.Identity;
using Azure.AI.OpenAI;
using Azure;
using DotNetEnv;
using System.Text.Json;
using Microsoft.Agents.AI;
using Microsoft.Extensions.AI;

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

// Enable Application Insights telemetry
if (!string.IsNullOrEmpty(applicationInsightsConnectionString))
{
    ApplicationInsightsTelemetry.Configure(applicationInsightsConnectionString);
}
else
{
    Console.WriteLine("⚠️  Application Insights connection string is not set. Telemetry is disabled.");
}

// Create the Azure OpenAI client
AzureOpenAIClient azureClient = apiKey switch
{
    null or "" => new(new Uri(endpoint), new DefaultAzureCredential()),
    _ => new(new Uri(endpoint), new AzureKeyCredential(apiKey))
};

// Add the lights manager
var lightsManager = new LightsManager();

// Create function tools from the LightsManager instance methods
var tools = new List<AITool>
{
    AIFunctionFactory.Create(lightsManager.GetLights),
    AIFunctionFactory.Create(lightsManager.ChangeState),
    AIFunctionFactory.Create(lightsManager.AddLight),
    AIFunctionFactory.Create(lightsManager.RemoveLight)
};

// List the available tools
Console.WriteLine("🤖 Functions (or tools) I can use:");
foreach (var tool in tools)
{
    Console.WriteLine($"\t{tool.Name}");
}

// Create the agent using Microsoft Agent Framework
AIAgent agent = azureClient
    .GetChatClient(deploymentName)
    .AsIChatClient()
    .AsAIAgent(
        name: "LightAssistant",
        instructions: """
            You are a helpful home assistant. You can turn lights on and off, add new lights, and remove lights. Use the available functions to perform these actions.
            IMPORTANT: The state of the lights can change at any time from external sources (e.g. a web interface). 
            Always call GetLights to check the current state before answering any question about the status of the lights. Never rely on your memory of previous states.
            If the user ask for something that is not related to lights, respond that you are a home assistant and can only help with lights.
            """,
        tools: tools);

// Create a session for multi-turn conversation
AgentSession session = await agent.CreateSessionAsync();

// Start the web socket server
WebSocketServer webSocketServer = new(lightsManager);
Task webSocketServerTask = webSocketServer.StartAsync("http://localhost:5000");

// Initiate a back-and-forth chat
string? userInput;
Console.WriteLine("🚀 Ready! Type your message below (or /exit to quit):");
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
        if (session.TryGetInMemoryChatHistory(out var history))
        {
            foreach (var message in history)
            {
                Console.WriteLine($"HISTORY> {message.Role}: {message.Text}");

                if (message.AdditionalProperties != null && message.AdditionalProperties.Count > 0)
                {
                    var metadataJson = JsonSerializer.Serialize(message.AdditionalProperties, new JsonSerializerOptions
                    {
                        WriteIndented = true
                    });
                    Console.WriteLine($"HISTORY> Metadata:");
                    Console.WriteLine(metadataJson);
                }

                // Show tool call details
                foreach (var content in message.Contents)
                {
                    if (content is FunctionCallContent functionCall)
                    {
                        Console.WriteLine($"HISTORY>   🔧 Tool Call: {functionCall.Name}({JsonSerializer.Serialize(functionCall.Arguments)})");
                    }
                    else if (content is FunctionResultContent functionResult)
                    {
                        Console.WriteLine($"HISTORY>   📋 Tool Result: {functionResult.Result}");
                    }
                }
            }
        }
        else
        {
            Console.WriteLine("⚠️ Chat history is not available for this session type.");
        }

        continue;
    }

    if (!string.IsNullOrEmpty(userInput))
    {
        // Get the streaming response from the AI agent
        Console.Write("🤔 thinking...");
        string fullResponse = string.Empty;
        bool responseStarted = false;
        await foreach (var update in agent.RunStreamingAsync(userInput, session))
        {
            if (!string.IsNullOrEmpty(update.Text))
            {
                if (!responseStarted)
                {
                    Console.WriteLine();
                    Console.Write("🤖 > ");
                    responseStarted = true;
                }
                Console.Write(update.Text);
                fullResponse += update.Text;
            }
            else
            {
                Console.Write(".");
            }
        }
        Console.WriteLine();

        // Notify the web app about the light state change
        await webSocketServer.BroadcastLightUpdateAsync();
    }
} while (userInput is not null && !webSocketServer.IsCancellationRequested);

// Stop the web server
await webSocketServer.StopAsync();