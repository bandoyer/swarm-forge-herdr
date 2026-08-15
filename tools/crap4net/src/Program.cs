using System.Text.Json;

namespace Crap4Net;

internal static class Program
{
    private const string Usage = """
        crap4net — CRAP scores (complexity² × (1−coverage)³ + complexity) for C#.

        Usage: crap4net --lcov <tracefile> [options] [source-dir ...]

        Options:
          --lcov <file>       lcov tracefile (e.g. from coverlet). Required.
          --threshold <n>     failure bar; any method above it fails the run (default 6)
          --all               list every method, not just those above the threshold
          --json              machine-readable output
        Source dirs default to the current directory; bin/ and obj/ are skipped.

        Exit codes: 0 ok; 1 usage/input error; 2 methods above the threshold.
        """;

    private static int Main(string[] args)
    {
        string? lcovPath = null;
        double threshold = 6;
        var showAll = false;
        var json = false;
        var sourceDirs = new List<string>();

        for (var i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--lcov" when i + 1 < args.Length: lcovPath = args[++i]; break;
                case "--threshold" when i + 1 < args.Length
                    && double.TryParse(args[i + 1], out threshold): i++; break;
                case "--all": showAll = true; break;
                case "--json": json = true; break;
                case "--help" or "-h": Console.WriteLine(Usage); return 0;
                case var flag when flag.StartsWith('-'):
                    Console.Error.WriteLine($"Unknown option: {flag}\n\n{Usage}"); return 1;
                default: sourceDirs.Add(args[i]); break;
            }
        }

        if (lcovPath is null || !File.Exists(lcovPath))
        {
            Console.Error.WriteLine(lcovPath is null
                ? $"Missing required --lcov <tracefile>.\n\n{Usage}"
                : $"lcov tracefile not found: {lcovPath}");
            return 1;
        }
        if (sourceDirs.Count == 0)
            sourceDirs.Add(".");

        var lcov = LcovParser.Parse(File.ReadAllText(lcovPath));
        var scores = new List<CrapScore>();
        foreach (var file in SourceFiles(sourceDirs))
        {
            var hits = LcovParser.ForFile(lcov, file);
            scores.AddRange(
                ComplexityWalker.Analyze(file, File.ReadAllText(file))
                    .Select(method => CrapAnalyzer.Score(method, hits)));
        }

        var failures = scores.Where(s => s.Crap > threshold)
                             .OrderByDescending(s => s.Crap)
                             .ToList();
        Report(json, showAll, threshold, scores, failures);
        return failures.Count == 0 ? 0 : 2;
    }

    private static IEnumerable<string> SourceFiles(IEnumerable<string> dirs) =>
        dirs.SelectMany(dir => Directory.EnumerateFiles(dir, "*.cs", SearchOption.AllDirectories))
            .Where(f => !f.Split(Path.DirectorySeparatorChar, '/')
                          .Any(segment => segment is "bin" or "obj"))
            .Distinct();

    private static void Report(bool json, bool showAll, double threshold,
        List<CrapScore> scores, List<CrapScore> failures)
    {
        if (json)
        {
            Console.WriteLine(JsonSerializer.Serialize(new
            {
                threshold,
                methods = scores.Count,
                failures = failures.Count,
                results = (showAll ? scores.OrderByDescending(s => s.Crap).ToList() : failures)
                    .Select(s => new
                    {
                        file = s.Method.File,
                        method = s.Method.Name,
                        line = s.Method.StartLine,
                        complexity = s.Method.Complexity,
                        coverage = Math.Round(s.Coverage, 4),
                        instrumentedLines = s.InstrumentedLines,
                        crap = Math.Round(s.Crap, 2)
                    })
            }, new JsonSerializerOptions { WriteIndented = true }));
            return;
        }

        foreach (var s in showAll ? scores.OrderByDescending(s => s.Crap).ToList() : failures)
            Console.WriteLine(
                $"{s.Crap,8:F2}  comp {s.Method.Complexity,3}  cov {s.Coverage,6:P1}  " +
                $"{s.Method.File}:{s.Method.StartLine}  {s.Method.Name}" +
                (s.InstrumentedLines == 0 ? "  [no coverage data]" : ""));

        Console.WriteLine($"crap4net: {scores.Count} methods, threshold {threshold}, " +
                          (failures.Count == 0 ? "all within threshold."
                                               : $"{failures.Count} ABOVE THRESHOLD."));
    }
}
