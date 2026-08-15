namespace Crap4Net;

public sealed record CrapScore(
    MethodInfo Method,
    double Coverage,
    int InstrumentedLines,
    double Crap)
{
    /// <summary>CRAP(m) = comp² × (1 − cov)³ + comp (Savoia/Sundahl).</summary>
    public static double Formula(int complexity, double coverage) =>
        complexity * (double)complexity * Math.Pow(1.0 - coverage, 3) + complexity;
}

public static class CrapAnalyzer
{
    /// <summary>
    /// Scores one method against lcov line hits for its file. Coverage is
    /// the covered fraction of instrumented lines inside the method's
    /// span; a method with no instrumented lines (or a file absent from
    /// the tracefile) counts as uncovered — stale or missing coverage must
    /// never look like safety.
    /// </summary>
    public static CrapScore Score(MethodInfo method, Dictionary<int, long>? lineHits)
    {
        var instrumented = 0;
        var covered = 0;
        if (lineHits is not null)
        {
            for (var line = method.StartLine; line <= method.EndLine; line++)
            {
                if (!lineHits.TryGetValue(line, out var hits))
                    continue;
                instrumented++;
                if (hits > 0)
                    covered++;
            }
        }

        var coverage = instrumented == 0 ? 0.0 : (double)covered / instrumented;
        return new CrapScore(method, coverage, instrumented,
            CrapScore.Formula(method.Complexity, coverage));
    }
}
