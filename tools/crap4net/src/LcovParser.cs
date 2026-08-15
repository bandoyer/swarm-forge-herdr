namespace Crap4Net;

/// <summary>
/// Parses lcov tracefiles (as produced by coverlet) into per-file,
/// per-line hit counts. Only SF/DA/end_of_record records matter here.
/// </summary>
public static class LcovParser
{
    public static Dictionary<string, Dictionary<int, long>> Parse(string lcovText)
    {
        var files = new Dictionary<string, Dictionary<int, long>>();
        Dictionary<int, long>? current = null;

        foreach (var rawLine in lcovText.Split('\n'))
        {
            var line = rawLine.TrimEnd('\r');
            if (line.StartsWith("SF:"))
            {
                var path = NormalizePath(line[3..]);
                if (!files.TryGetValue(path, out current))
                {
                    current = new Dictionary<int, long>();
                    files[path] = current;
                }
            }
            else if (line.StartsWith("DA:") && current is not null)
            {
                var parts = line[3..].Split(',');
                if (parts.Length >= 2
                    && int.TryParse(parts[0], out var lineNumber)
                    && long.TryParse(parts[1], out var hits))
                {
                    // A line may appear once per method record; keep the max.
                    current[lineNumber] = Math.Max(current.GetValueOrDefault(lineNumber), hits);
                }
            }
            else if (line == "end_of_record")
            {
                current = null;
            }
        }

        return files;
    }

    public static string NormalizePath(string path) =>
        Path.GetFullPath(path).Replace('\\', '/');

    /// <summary>
    /// Finds the coverage record for a source file: exact normalized match
    /// first, then unique suffix match (tracefiles sometimes hold paths
    /// from another checkout root).
    /// </summary>
    public static Dictionary<int, long>? ForFile(
        Dictionary<string, Dictionary<int, long>> files, string sourcePath)
    {
        var normalized = NormalizePath(sourcePath);
        if (files.TryGetValue(normalized, out var exact))
            return exact;

        var suffixMatches = files.Keys
            .Where(k => k.EndsWith("/" + Path.GetFileName(normalized)))
            .Where(k => SharedSuffixSegments(k, normalized) >= 2)
            .ToList();
        return suffixMatches.Count == 1 ? files[suffixMatches[0]] : null;
    }

    private static int SharedSuffixSegments(string a, string b)
    {
        var aSegments = a.Split('/');
        var bSegments = b.Split('/');
        var shared = 0;
        while (shared < aSegments.Length && shared < bSegments.Length
               && aSegments[^(shared + 1)] == bSegments[^(shared + 1)])
            shared++;
        return shared;
    }
}
