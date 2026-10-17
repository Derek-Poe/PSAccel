# PSAccel.psm1
# GPU-accelerated data filtering via Direct3D 11
# Author: Derek Poe (@Derek-Poe), 2025
# Version: 0.2.0

# Resolve the bundled source independently of the caller's working directory.
if (-not ('PSAccel' -as [type])) {
    Add-Type -TypeDefinition ([System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'PSAccel.cs'))) -Language CSharp
}

function ParseScriptblockVariable {
    param([scriptblock]$FilterScript, [string]$Variable)

    $Variable = [Regex]::Replace($Variable, "\$", "")
    try {
        # GetNewClosure captures variables in a dynamic module. Read that
        # session state without invoking the predicate or losing its binding.
        $val = if ($null -ne $FilterScript.Module) {
            $FilterScript.Module.SessionState.PSVariable.GetValue($Variable)
        } else { $PSCmdlet.GetVariableValue($Variable) }
        if ($null -eq $val) {
            throw "Variable `$$Variable is null or not defined."
        }
        Write-Verbose "Bound variable '`$$Variable' to value: $val"
    } catch {
        throw "RHS variable `$$Variable not found or not accessible."
    }
    return $val
}

function Assert-PSAccelExpression {
    param([scriptblock]$Expression)
    $ast = $Expression.Ast
    if ($ast.ParamBlock -or $ast.BeginBlock -or $ast.ProcessBlock -or
        -not $ast.EndBlock -or $ast.EndBlock.Statements.Count -ne 1) {
        throw 'Use one numeric predicate expression without statements or parameters.'
    }
    $allowed = @('ScriptBlockAst', 'NamedBlockAst', 'PipelineAst', 'CommandExpressionAst',
        'BinaryExpressionAst', 'ParenExpressionAst', 'MemberExpressionAst',
        'VariableExpressionAst', 'ConstantExpressionAst', 'StringConstantExpressionAst', 'UnaryExpressionAst')
    foreach ($node in $ast.FindAll({ $true }, $true)) {
        $kind = $node.GetType().Name
        if ($kind -notin $allowed) { throw "Unsupported predicate syntax: $kind" }
        if ($kind -eq 'PipelineAst' -and $node.PipelineElements.Count -ne 1) {
            throw 'Pipelines are not supported inside a predicate.'
        }
        if ($kind -eq 'BinaryExpressionAst' -and
            $node.Operator.ToString() -notin @('Igt','Ilt','Ige','Ile','Ieq','Ine','And','Or')) {
            throw "Unsupported predicate operator: $($node.Operator)"
        }
        if ($kind -eq 'UnaryExpressionAst' -and $node.TokenKind.ToString() -notin @('Minus','Plus')) {
            throw 'Only numeric unary signs are supported.'
        }
        if ($kind -eq 'MemberExpressionAst') {
            if ($node.Static -or $node.Expression -isnot [System.Management.Automation.Language.VariableExpressionAst] -or
                $node.Expression.VariablePath.UserPath -ne '_' -or
                $node.Member -isnot [System.Management.Automation.Language.StringConstantExpressionAst] -or
                $node.Member.Value -cnotmatch '^[A-Za-z][A-Za-z0-9_]*$') {
                throw 'Properties must use simple $_.Property syntax.'
            }
        }
        if ($kind -eq 'StringConstantExpressionAst' -and
            $node.Parent -isnot [System.Management.Automation.Language.MemberExpressionAst]) {
            throw 'String comparisons are not supported; use numeric properties and constants.'
        }
        if ($kind -eq 'VariableExpressionAst' -and $node.VariablePath.UserPath -eq '_' -and
            $node.Parent -isnot [System.Management.Automation.Language.MemberExpressionAst]) {
            throw 'Use a numeric property such as $_.Value rather than the whole input object.'
        }
    }
}

function ConvertTo-PSAccelNumber {
    param($Value)
    if ($Value -isnot [byte] -and $Value -isnot [sbyte] -and $Value -isnot [int16] -and
        $Value -isnot [uint16] -and $Value -isnot [int32] -and $Value -isnot [uint32] -and
        $Value -isnot [int64] -and $Value -isnot [uint64] -and $Value -isnot [single] -and
        $Value -isnot [double] -and $Value -isnot [decimal]) {
        throw 'Predicate constants and variables must be finite numbers.'
    }
    $number = [single]$Value
    if ([single]::IsNaN($number) -or [single]::IsInfinity($number)) {
        throw 'Predicate constants and variables must be finite numbers.'
    }
    $literal = $number.ToString('R', [Globalization.CultureInfo]::InvariantCulture)
    if ($literal -notmatch '[.Ee]') { $literal += '.0' }
    return $literal + 'f'
}

function ConvertTo-PSAccelHlslExpression {
    param($Node, $Properties, [scriptblock]$OriginalExpression)
    switch ($Node.GetType().Name) {
        'PipelineAst' { return ConvertTo-PSAccelHlslExpression $Node.PipelineElements[0] $Properties $OriginalExpression }
        'CommandExpressionAst' { return ConvertTo-PSAccelHlslExpression $Node.Expression $Properties $OriginalExpression }
        'ParenExpressionAst' { return '(' + (ConvertTo-PSAccelHlslExpression $Node.Pipeline $Properties $OriginalExpression) + ')' }
        'BinaryExpressionAst' {
            $operators = @{ Igt='>'; Ilt='<'; Ige='>='; Ile='<='; Ieq='=='; Ine='!='; And='&&'; Or='||' }
            $left = ConvertTo-PSAccelHlslExpression $Node.Left $Properties $OriginalExpression
            $right = ConvertTo-PSAccelHlslExpression $Node.Right $Properties $OriginalExpression
            # Preserve PowerShell's AST grouping, including mixed -or / -and.
            return '(' + $left + ' ' + $operators[$Node.Operator.ToString()] + ' ' + $right + ')'
        }
        'UnaryExpressionAst' {
            $sign = if ($Node.TokenKind.ToString() -eq 'Minus') { '-' } else { '+' }
            return '(' + $sign + (ConvertTo-PSAccelHlslExpression $Node.Child $Properties $OriginalExpression) + ')'
        }
        'MemberExpressionAst' {
            $name = [string]$Node.Member.Value
            if (-not $Properties.Contains($name)) { $Properties[$name] = 'p' + $Properties.Count }
            return 'data[i].' + $Properties[$name]
        }
        'ConstantExpressionAst' { return ConvertTo-PSAccelNumber $Node.Value }
        'VariableExpressionAst' {
            $value = ParseScriptblockVariable $OriginalExpression ('$' + $Node.VariablePath.UserPath)
            return ConvertTo-PSAccelNumber $value
        }
        default { throw "Unsupported predicate syntax: $($Node.GetType().Name)" }
    }
}

function Get-PSAccelExpressionKind {
    param($Node)
    switch ($Node.GetType().Name) {
        'PipelineAst' { return Get-PSAccelExpressionKind $Node.PipelineElements[0] }
        'CommandExpressionAst' { return Get-PSAccelExpressionKind $Node.Expression }
        'ParenExpressionAst' { return Get-PSAccelExpressionKind $Node.Pipeline }
        'MemberExpressionAst' { return 'number' }
        'ConstantExpressionAst' { return 'number' }
        'VariableExpressionAst' { return 'number' }
        'UnaryExpressionAst' {
            if ((Get-PSAccelExpressionKind $Node.Child) -ne 'number') {
                throw 'Numeric signs cannot be applied to predicates.'
            }
            return 'number'
        }
        'BinaryExpressionAst' {
            $expected = if ($Node.Operator.ToString() -in @('And','Or')) { 'predicate' } else { 'number' }
            if ((Get-PSAccelExpressionKind $Node.Left) -ne $expected -or
                (Get-PSAccelExpressionKind $Node.Right) -ne $expected) {
                throw 'Compare numeric operands and join comparisons with -and or -or; Boolean/numeric coercion is unsupported.'
            }
            return 'predicate'
        }
        default { throw 'Unsupported expression kind.' }
    }
}

function BuildHLSL {
    param([scriptblock]$Expression, [String]$ScriptType)
    Assert-PSAccelExpression $Expression
    if ((Get-PSAccelExpressionKind $Expression.Ast.EndBlock.Statements[0]) -ne 'predicate') {
        throw 'Use a numeric comparison predicate.'
    }
    if ($ScriptType -ne 'Filter') { throw 'Only filter shaders are supported.' }
    if (-not $Expression.Ast.Find({ $args[0] -is [System.Management.Automation.Language.BinaryExpressionAst] }, $true)) {
        throw 'Use a numeric comparison predicate.'
    }
    $properties = [ordered]@{}
    $predicate = ConvertTo-PSAccelHlslExpression $Expression.Ast.EndBlock.Statements[0] $properties $Expression
    if ($properties.Count -eq 0) { throw 'The predicate must reference at least one numeric input property.' }
    [string[]]$calcProps = @($properties.Keys)
    $fields = ($properties.Values | ForEach-Object { '    float ' + $_ + ';' }) -join "`n"
    $hlsl = @"
struct Row {
$fields
};
StructuredBuffer<Row> data : register(t0);
RWStructuredBuffer<uint> output : register(u0);
[numthreads(256, 1, 1)]
void CSMain(uint3 DTid : SV_DispatchThreadID)
{
    uint i = DTid.x;
    uint rows, stride;
    data.GetDimensions(rows, stride);
    if (i >= rows) return;
    output[i] = ($predicate) ? 1 : 0;
}
"@
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
        $ErrorActionPreference = 'Stop'
        $st = Get-Date
        $hasInputData = $PSBoundParameters.ContainsKey('InputData')

        Write-Verbose "$(New-TimeSpan $st (Get-Date)) :: Starting HLSL Generation"
        $calcProps, $hlsl = BuildHLSL $FilterScript "Filter"
        Write-Verbose "$(New-TimeSpan $st (Get-Date)) :: HLSL Generation Complete"
        Write-Verbose "HLSL: $hlsl"

        Write-Verbose "$(New-TimeSpan $st (Get-Date)) :: Starting Piped Data Accumulation"
        $buffer = [System.Collections.Generic.List[psobject]]::new()
    }

    process {
        if (-not $hasInputData -and $null -ne $InputObject) {
            $buffer.Add($InputObject)
        }
    }

    end {
        Write-Verbose "$(New-TimeSpan $st (Get-Date)) :: Piped Data Accumulation Complete"

        $finalInput = if ($hasInputData) { [PSObject[]]$InputData } else { [PSObject[]]$buffer.ToArray() }
        if (-not $finalInput -or $finalInput.Count -eq 0) {
            return
        }

        Write-Verbose "$(New-TimeSpan $st (Get-Date)) :: Starting GPU Filter Pipeline"
        try {
            $filtered = [PSAccel]::RunAccelFilterFromObjects($finalInput, $calcProps, $hlsl)
        } catch { $PSCmdlet.ThrowTerminatingError($_) }
        Write-Verbose "$(New-TimeSpan $st (Get-Date)) :: GPU Filter Pipeline Complete"

        return $filtered
    }
}

Export-ModuleMember -Function PSA_Where-Object -Alias ?G, PSA_?
