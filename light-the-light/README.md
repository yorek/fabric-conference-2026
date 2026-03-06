# VS Live 2025 - San Diego - Semantic Kernel Samples - Light the light

Clone the repo and open the `light-the-light` folder.

## Prerequisites

Create an `.env` file using the `.env.sample` as a template and add your Azure OpenAI endpoint and key. The mandatory environment variables are:

- `AZURE_OPENAI_CHAT_DEPLOYMENT_NAME`
- `AZURE_OPENAI_ENDPOINT`

if you are using key-based authentication for Azure OpenAI, you also need to set

- `AZURE_OPENAI_API_KEY`

If you are using Entra ID authentication, make sure to give your account the permission needed to use the Azure OpenAI resource using the `Cognitive Services OpenAI User` role. (see: [Authenticate to Azure OpenAI from an Azure hosted app using Microsoft Entra ID](https://learn.microsoft.com/dotnet/ai/how-to/app-service-aoai-auth?tabs=system-assigned%2Cresource&pivots=azure-portal))

You can also monitor all the calls made to the Azure OpenAI resource using [Application Insight](https://learn.microsoft.com/semantic-kernel/concepts/enterprise-readiness/observability/telemetry-with-app-insights?tabs=Powershell&pivots=programming-language-csharp) or [Azure AI Foundry](https://learn.microsoft.com/semantic-kernel/concepts/enterprise-readiness/observability/telemetry-with-azure-ai-foundry-tracing). All you have to do is add the `APPLICATION_INSIGHTS_CONNECTION_STRING` environment variable to your `.env` file.

## Run the sample

Compile the project via

```bash
dotnet build
```

and then run it via

```bash 
dotnet run
```

## Using the application

Once the application is running, it will server a Web App at `http://localhost:5000` where you can see what lights are available and their status. You can turn on or off the lights from the web interface.

You can also use the console to interact with the lights using natural language. Just type your command and hit enter. For example, you can type "Turn on the living room light" or "Turn off all lights". You can also add and remove lights using natural language. For example, you can type "Add a kitchen light" or "Remove the bedroom light".

If can see what are the functions that the AI is calling by looking at the console output or the Application Insights logs if you have configured it.