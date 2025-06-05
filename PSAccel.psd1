@{
    # Script module or binary module file associated with this manifest.
    RootModule = 'PSAccel.psm1'

    # Version number of this module.
    ModuleVersion = '0.1.0'

    # ID used to uniquely identify this module
    GUID = 'f77fbe47-469b-4ea0-9839-5e5e79b3143f'

    # Author of this module
    Author = 'Derek Poe'

    # Company or vendor of this module
    CompanyName = 'Independent'

    # Copyright statement for this module
    Copyright = '(c) 2025 Derek Poe. All rights reserved.'

    # Description of the functionality provided by this module
    Description = 'GPU-accelerated data filtering for PowerShell using Direct3D 11 compute shaders.'

    # Minimum version of the PowerShell engine required
    PowerShellVersion = '5.1'

    # Modules that must be imported into the global environment prior to importing this module
    RequiredModules = @()

    # Assemblies that must be loaded prior to importing this module
    RequiredAssemblies = @()

    # Functions to export from this module
    FunctionsToExport = 'PSA_Where-Object'

    # Cmdlets to export from this module
    CmdletsToExport = @()

    # Variables to export from this module
    VariablesToExport = @()

    # Aliases to export from this module
    AliasesToExport = '?G', 'PSA_?'

    # List of all files packaged with this module
    FileList = @(
        'PSAccel.psm1',
        'PSAccel.cs',
        'Run-Benchmark.ps1',
        'README.md',
        'LICENSE'
    )

    # Private data to pass to the module specified in RootModule
    PrivateData = @{
        PSData = @{
            Tags = @('GPU', 'PowerShell', 'Acceleration', 'Filtering', 'DirectCompute', 'HLSL')
            LicenseUri = 'https://opensource.org/licenses/MIT'
            ProjectUri = 'https://github.com/Derek-Poe/PSAccel'
            IconUri = ''
            ReleaseNotes = 'Initial public release of PSAccel with GPU-accelerated `Where-Object` support.'
        }
    }
}
