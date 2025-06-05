# PSAccel.psm1
# GPU-accelerated data filtering via Direct3D 11
# Author: Derek Poe (@Derek-Poe), 2025
# Version: 0.1.0

# C# will be embedded inline in module release
Add-Type -TypeDefinition ([System.IO.File]::ReadAllText("PSAccel.cs")) -Language CSharp

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
        Write-Verbose "$(New-TimeSpan $st (Get-Date)) :: Starting Expression Parsing"

        # Extract binary expression from AST
        $binExpr = $FilterScript.Ast.Find({ $args[0] -is [System.Management.Automation.Language.BinaryExpressionAst] }, $true)
        if (-not $binExpr) {
            throw "Unsupported filter expression: $($FilterScript.ToString())"
        }

        $property  = $binExpr.Left.Member.Value
        $operator  = $binExpr.Operator.ToString()
        $rightCode = $binExpr.Right.Extent.Text
        Write-Verbose "rightCode: $rightCode"

        # Evaluate RHS value
        if ($rightCode -match "^\s*\$[\w:]+$") {
            $rhsVarName = $rightCode -replace "^\s*\$"
            try {
                $val = $PSCmdlet.GetVariableValue($rhsVarName)
                if ($null -eq $val) {
                    throw "Variable `$${rhsVarName} is null or not defined."
                }
                Write-Verbose "^Bound variable '$rhsVarName' to value: $val"
                $threshold = $val
            } catch {
                throw "RHS variable `$${rhsVarName} not found or not accessible."
            }
        } else {
            $threshold = $binExpr.Right.Value
        }

        Write-Verbose "$(New-TimeSpan $st (Get-Date)) :: Expression Parsing Complete"
        Write-Verbose "Accelerated filter on '$property' $operator $threshold"

        $buffer = [System.Collections.Generic.List[psobject]]::new()
        Write-Verbose "$(New-TimeSpan $st (Get-Date)) :: Starting Piped Data Accumulation"
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
        $filtered = [PSAccel]::RunAccelFilterFromObjects($finalInput, $property, $operator, [float]$threshold)
        Write-Verbose "$(New-TimeSpan $st (Get-Date)) :: GPU Filter Pipeline Complete"

        return $filtered
    }
}

Export-ModuleMember -Function PSA_Where-Object -Alias ?G, PSA_?