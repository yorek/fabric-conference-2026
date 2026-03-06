using OpenTelemetry;
using OpenTelemetry.Logs;
using OpenTelemetry.Metrics;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;
using Azure.Monitor.OpenTelemetry.Exporter;

public class ApplicationInsightsTelemetry
{
    public static ILoggerFactory Configure(string applicationInsightsConnectionString)
    {
        var resourceBuilder = ResourceBuilder
            .CreateDefault()
            .AddService("TelemetryApplicationInsightsQuickstart");

        // Enable OpenTelemetry diagnostics for AI operations
        AppContext.SetSwitch("Microsoft.Extensions.AI.EnableOTelDiagnosticsSensitive", true);

        var traceProvider = Sdk.CreateTracerProviderBuilder()
            .SetResourceBuilder(resourceBuilder)
            .AddSource("Microsoft.Agents*")
            .AddSource("Microsoft.Extensions.AI*")
            .AddAzureMonitorTraceExporter(options => options.ConnectionString = applicationInsightsConnectionString)
            .Build();

        var meterProvider = Sdk.CreateMeterProviderBuilder()
            .SetResourceBuilder(resourceBuilder)
            .AddMeter("Microsoft.Agents*")
            .AddMeter("Microsoft.Extensions.AI*")
            .AddAzureMonitorMetricExporter(options => options.ConnectionString = applicationInsightsConnectionString)
            .Build();

        var loggerFactory = LoggerFactory.Create(builder =>
        {
            // Add OpenTelemetry as a logging provider
            builder.AddOpenTelemetry(options =>
            {
                options.SetResourceBuilder(resourceBuilder);
                options.AddAzureMonitorLogExporter(options => options.ConnectionString = applicationInsightsConnectionString);
                // Format log messages. This is default to false.
                options.IncludeFormattedMessage = true;
                options.IncludeScopes = true;
            });
            builder.SetMinimumLevel(LogLevel.Information);
        });

        return loggerFactory;
    }
}
