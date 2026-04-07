namespace WiFiErabi.App.Services;

public sealed class NetshCommandResult
{
    public required int ExitCode { get; init; }

    public required string Text { get; init; }

    public required IReadOnlyList<string> Lines { get; init; }
}
