using Microsoft.Extensions.Logging;
using System.Text.RegularExpressions;

// Custom logger provider for Semantic Kernel function logging
public class CustomSemanticKernelLoggerProvider : ILoggerProvider
{
    public ILogger CreateLogger(string categoryName)
    {
        return new CustomSemanticKernelLogger(categoryName);
    }

    public void Dispose() { }
}

public class CustomSemanticKernelLogger : ILogger
{
    private readonly string _categoryName;
    private static readonly Regex FunctionLogRegex = new(@"Function (\w+)-(\w+) (invoking|succeeded|completed|failed)\.?", RegexOptions.Compiled);
    private static readonly Regex DurationRegex = new(@"Duration: ([\d\.]+)s", RegexOptions.Compiled);

    public CustomSemanticKernelLogger(string categoryName)
    {
        _categoryName = categoryName;
    }

    IDisposable? ILogger.BeginScope<TState>(TState state) => null;

    public bool IsEnabled(LogLevel logLevel) => _categoryName == "Microsoft.SemanticKernel.KernelFunction" && logLevel >= LogLevel.Information;

    public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception, Func<TState, Exception?, string> formatter)
    {
        if (!IsEnabled(logLevel)) return;

        var message = formatter(state, exception);
        var match = FunctionLogRegex.Match(message);

        if (match.Success)
        {
            var plugin = match.Groups[1].Value;
            var function = match.Groups[2].Value;
            var action = match.Groups[3].Value;

            // Extract duration for completed actions
            var duration = "";
            if (action == "completed")
            {
                var durationMatch = DurationRegex.Match(message);
                if (durationMatch.Success)
                {
                    duration = $" ({durationMatch.Groups[1].Value}s)";
                }
            }

            Console.WriteLine($"🔧 {plugin}.{function} {action}{duration}");
        }
    }
}
