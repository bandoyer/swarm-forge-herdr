using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;

namespace Crap4Net;

public sealed record MethodInfo(
    string File,
    string Name,
    int StartLine,
    int EndLine,
    int Complexity);

/// <summary>
/// Extracts every executable member (methods, constructors, operators,
/// accessors with bodies, local functions, lambdas folded into their
/// enclosing member) with its cyclomatic complexity:
/// 1 + one per decision point (if, loops, case arms, catch, conditional
/// expressions, &amp;&amp;, ||, ??, ??=).
/// </summary>
public static class ComplexityWalker
{
    public static List<MethodInfo> Analyze(string file, string source)
    {
        var tree = CSharpSyntaxTree.ParseText(source);
        var results = new List<MethodInfo>();

        foreach (var node in tree.GetRoot().DescendantNodes())
        {
            var (name, body) = node switch
            {
                MethodDeclarationSyntax m => (m.Identifier.Text, Body(m.Body, m.ExpressionBody)),
                ConstructorDeclarationSyntax c => (c.Identifier.Text + " (ctor)", Body(c.Body, c.ExpressionBody)),
                OperatorDeclarationSyntax o => ("operator " + o.OperatorToken.Text, Body(o.Body, o.ExpressionBody)),
                ConversionOperatorDeclarationSyntax v => ("operator " + v.Type, Body(v.Body, v.ExpressionBody)),
                LocalFunctionStatementSyntax l => (l.Identifier.Text + " (local)", Body(l.Body, l.ExpressionBody)),
                AccessorDeclarationSyntax a when a.Body is not null || a.ExpressionBody is not null =>
                    (AccessorName(a), Body(a.Body, a.ExpressionBody)),
                _ => (null, null)
            };
            if (name is null || body is null)
                continue;

            var span = body.GetLocation().GetLineSpan();
            results.Add(new MethodInfo(
                file,
                Qualify(node, name),
                span.StartLinePosition.Line + 1,
                span.EndLinePosition.Line + 1,
                1 + body.DescendantNodes(descend => !StartsNewMember(descend)).Count(IsDecisionPoint)));
        }

        return results;
    }

    private static SyntaxNode? Body(SyntaxNode? block, SyntaxNode? expressionBody) =>
        block ?? expressionBody;

    private static string AccessorName(AccessorDeclarationSyntax accessor)
    {
        var owner = accessor.Ancestors().OfType<BasePropertyDeclarationSyntax>().FirstOrDefault();
        var ownerName = owner switch
        {
            PropertyDeclarationSyntax p => p.Identifier.Text,
            IndexerDeclarationSyntax => "this[]",
            EventDeclarationSyntax e => e.Identifier.Text,
            _ => "?"
        };
        return $"{ownerName}.{accessor.Keyword.Text}";
    }

    private static string Qualify(SyntaxNode node, string name)
    {
        var type = node.Ancestors().OfType<BaseTypeDeclarationSyntax>().FirstOrDefault();
        return type is null ? name : $"{type.Identifier.Text}.{name}";
    }

    /// <summary>Nested local functions get their own entry; don't double-count.</summary>
    private static bool StartsNewMember(SyntaxNode node) =>
        node is LocalFunctionStatementSyntax;

    private static bool IsDecisionPoint(SyntaxNode node) => node switch
    {
        IfStatementSyntax => true,
        WhileStatementSyntax => true,
        ForStatementSyntax => true,
        ForEachStatementSyntax => true,
        DoStatementSyntax => true,
        CatchClauseSyntax => true,
        CaseSwitchLabelSyntax => true,
        CasePatternSwitchLabelSyntax => true,
        SwitchExpressionArmSyntax => true,
        ConditionalExpressionSyntax => true,
        BinaryExpressionSyntax b when b.IsKind(SyntaxKind.LogicalAndExpression)
                                   || b.IsKind(SyntaxKind.LogicalOrExpression)
                                   || b.IsKind(SyntaxKind.CoalesceExpression) => true,
        AssignmentExpressionSyntax a when a.IsKind(SyntaxKind.CoalesceAssignmentExpression) => true,
        _ => false
    };
}
