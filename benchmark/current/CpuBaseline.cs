using System;
using System.Collections.Generic;
using System.Management.Automation;
using System.Security.Cryptography;
using System.Text;

// Deliberately specialized to the documented synthetic schema and predicates.
// Reads the same PSObject properties as PSAccel; no preprojection/cache is used.
public static class PSAccelCurrentBenchmark
{
    public static PSObject[] Filter(PSObject[] input, string scenario)
    {
        var selected = new List<PSObject>();
        foreach (PSObject row in input)
        {
            int value = (int)row.Properties["Value"].Value;
            bool match;
            if (scenario == "SingleProperty")
                match = value >= 900;
            else if (scenario == "ThreeProperty")
                match = (value >= 500 && (int)row.Properties["Group"].Value < 4)
                    || (int)row.Properties["Offset"].Value == 0;
            else
                throw new ArgumentException("Unknown benchmark scenario.", "scenario");
            if (match) selected.Add(row);
        }
        return selected.ToArray();
    }

    public static string VerifyAndHash(PSObject[] expected, PSObject[] actual)
    {
        if (actual.Length != expected.Length)
            throw new InvalidOperationException("Selected row count differs from native reference.");
        // Hash newline-delimited decimal Id values in UTF-8, in returned order.
        var ids = new StringBuilder();
        for (int i = 0; i < actual.Length; i++)
        {
            if (!Object.ReferenceEquals(expected[i].BaseObject, actual[i].BaseObject))
                throw new InvalidOperationException("Selected object identity/order differs at " + i);
            ids.Append(((int)actual[i].Properties["Id"].Value).ToString(
                System.Globalization.CultureInfo.InvariantCulture)).Append('\n');
        }
        using (var sha = SHA256.Create())
        {
            return BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(ids.ToString())))
                .Replace("-", "").ToLowerInvariant();
        }
    }
}
