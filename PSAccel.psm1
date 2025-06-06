# PSAccel.psm1
# GPU-accelerated data filtering via Direct3D 11
# Author: Derek Poe (@Derek-Poe), 2025
# Version: 0.1.1

# C# will be embedded inline in module release
Add-Type -TypeDefinition ([System.IO.File]::ReadAllText("PSAccel.cs")) -Language CSharp

function ParseScriptblockVariable {
    param([scriptblock]$FilterScript, [string]$Variable)

    $Variable = [Regex]::Replace($Variable, "\$", "")
    try {
        $val = $PSCmdlet.GetVariableValue($Variable)
        if ($null -eq $val) {
            throw "Variable `$$Variable is null or not defined."
        }
        Write-Verbose "Bound variable '`$$Variable' to value: $val"
    } catch {
        throw "RHS variable `$$Variable not found or not accessible."
    }
    return $val
}

function BuildHLSL {
    param([scriptblock]$Expression, [String]$ScriptType)

    # Extract binary expression from AST
    $binExpr = $Expression.Ast.Find({ $args[0] -is [System.Management.Automation.Language.BinaryExpressionAst] }, $true)
    if (-not $binExpr) {
        throw "Unsupported filter expression: $($Expression.ToString())"
    }

    $parsedExpression = $Expression.ToString()

    Write-Verbose "Parsed Expression - Raw: $parsedExpression"

    $embeddedVars = [Regex]::Matches($parsedExpression, "\$\w+") | % {$_.Value} |Select -Unique
    forEach($var in $embeddedVars){
        if($var -eq "`$_"){ continue }
        $parsedVal = (ParseScriptblockVariable $Expression $var).ToString("0.0######") + "f"
        $parsedExpression = [Regex]::Replace($parsedExpression, [Regex]::Escape($var), $parsedVal)
    }

    Write-Verbose "Parsed Expression - Variables Matched: $parsedExpression"

    $parsedExpression = [Regex]::Replace($parsedExpression, "(?i)\s-lt\s", " < ")
    $parsedExpression = [Regex]::Replace($parsedExpression, "(?i)\s-gt\s", " > ")
    $parsedExpression = [Regex]::Replace($parsedExpression, "(?i)\s-le\s", " <= ")
    $parsedExpression = [Regex]::Replace($parsedExpression, "(?i)\s-ge\s", " >= ")
    $parsedExpression = [Regex]::Replace($parsedExpression, "(?i)\s-eq\s", " == ")
    $parsedExpression = [Regex]::Replace($parsedExpression, "(?i)\s-ne\s", " != ")
    $parsedExpression = [Regex]::Replace($parsedExpression, "(?i)\s-and\s", " && ")
    $parsedExpression = [Regex]::Replace($parsedExpression, "(?i)\s-or\s", " || ")

    Write-Verbose "Parsed Expression - Operators Matched: $parsedExpression"

    [string[]]$calcProps = [Regex]::Matches($parsedExpression, "\`$_\.\w+") | % {($_.Value -split "\.")[-1]} | Select -Unique

    Write-Verbose "Parsed Expression - Calculation Properties: $($calcProps -join ", ")"

    $rowStruct = "struct Row { `n"
    $rowStruct += $calcProps | % {"    float $_; `n"}
    $rowStruct += "}; `n"
    $rowDelcare = ""
    $rowDelcare += $calcProps | % {"    float $_ = data[i].$_; `n"}

    switch ($ScriptType){
        "Filter" {
            $parsedExpression = [Regex]::Replace($parsedExpression, [Regex]::Escape("`$_."), "")
            $hlsl = @"
$rowStruct
StructuredBuffer<Row> data : register(t0);
RWStructuredBuffer<uint> output : register(u0);

[numthreads(256, 1, 1)]
void CSMain(uint3 DTid : SV_DispatchThreadID)
{
    uint i = DTid.x;
    if (i >= data.Length) return;    
$rowDelcare
    output[i] = ($parsedExpression) ? 1 : 0;
};
"@
            break
        }
    }
    return $calcProps, $hlsl
}

function PSA_Where-Object {
    [CmdletBinding()]
    [Alias("?G", "PSA_?")]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [scriptblock]$FilterScript,

        [Parameter(ValueFromPipeline = $true, Position = 1)]
        [object]$InputObject,

        [Parameter(Mandatory = $false)]
        [object[]]$InputData
    )

    begin {
        $st = Get-Date

        Write-Verbose "$(New-TimeSpan $st (Get-Date)) :: Starting HLSL Generation"
        $calcProps, $hlsl = BuildHLSL $FilterScript "Filter"
        Write-Verbose "$(New-TimeSpan $st (Get-Date)) :: HLSL Generation Complete"
        Write-Verbose "HLSL: $hlsl"

        Write-Verbose "$(New-TimeSpan $st (Get-Date)) :: Starting Piped Data Accumulation"
        $buffer = [System.Collections.Generic.List[psobject]]::new()
    }

    process {
        if (-not $InputData) {
            $buffer.Add($InputObject)
        }
    }

    end {
        Write-Verbose "$(New-TimeSpan $st (Get-Date)) :: Piped Data Accumulation Complete"

        $finalInput = if ($InputData) { [PSObject[]]$InputData } else { [PSObject[]]$buffer.ToArray() }
        if (-not $finalInput -or $finalInput.Count -eq 0) {
            return
        }

        Write-Verbose "$(New-TimeSpan $st (Get-Date)) :: Starting GPU Filter Pipeline"
        $filtered = [PSAccel]::RunAccelFilterFromObjects($finalInput, $calcProps, $hlsl)
        Write-Verbose "$(New-TimeSpan $st (Get-Date)) :: GPU Filter Pipeline Complete"

        return $filtered
    }
}

Export-ModuleMember -Function PSA_Where-Object -Alias ?G, PSA_?