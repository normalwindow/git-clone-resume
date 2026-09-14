using System;
using System.Diagnostics;
using System.IO;
using System.Text;

internal static class GcrLauncher
{
    private static int Main(string[] args)
    {
        string scriptPath = Path.Combine(
            Path.GetDirectoryName(typeof(GcrLauncher).Assembly.Location),
            "git-clone-resume.ps1");

        if (!File.Exists(scriptPath))
        {
            Console.Error.WriteLine("Cannot find git-clone-resume.ps1 next to gcr.exe.");
            return 2;
        }

        var arguments = new StringBuilder();
        arguments.Append("-NoLogo -NoProfile -ExecutionPolicy Bypass -File ");
        arguments.Append(QuoteArgument(scriptPath));
        foreach (string argument in args)
        {
            arguments.Append(' ');
            arguments.Append(QuoteArgument(argument));
        }

        try
        {
            using (var process = new Process())
            {
                process.StartInfo = new ProcessStartInfo
                {
                    FileName = "powershell.exe",
                    Arguments = arguments.ToString(),
                    UseShellExecute = false,
                    WorkingDirectory = Environment.CurrentDirectory
                };
                process.Start();
                process.WaitForExit();
                return process.ExitCode;
            }
        }
        catch (Exception error)
        {
            Console.Error.WriteLine("Unable to start PowerShell: " + error.Message);
            return 2;
        }
    }

    private static string QuoteArgument(string value)
    {
        if (value.Length == 0)
        {
            return "\"\"";
        }

        bool needsQuotes = value.IndexOfAny(new[] { ' ', '\t', '"' }) >= 0;
        if (!needsQuotes)
        {
            return value;
        }

        var result = new StringBuilder();
        result.Append('"');
        int backslashes = 0;
        foreach (char character in value)
        {
            if (character == '\\')
            {
                backslashes++;
            }
            else if (character == '"')
            {
                result.Append('\\', backslashes * 2 + 1);
                result.Append('"');
                backslashes = 0;
            }
            else
            {
                result.Append('\\', backslashes);
                result.Append(character);
                backslashes = 0;
            }
        }

        result.Append('\\', backslashes * 2);
        result.Append('"');
        return result.ToString();
    }
}