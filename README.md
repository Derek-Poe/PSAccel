# PSAccel

**PowerShell GPU Acceleration Toolkit**

GPU-accelerated data filtering for PowerShell using Direct3D 11 compute shaders.

---

## What is PSAccel?

PSAccel is a PowerShell module that introduces GPU acceleration to everyday PowerShell tasks—starting with `Where-Object`. By offloading filtering logic to your system's GPU, even in its early development, PSAccel can deliver up to **4x faster performance** on large datasets compared to native filtering.

This is achieved through a custom C# backend that compiles dynamically-generated HLSL shaders on the fly and binds them to structured buffers via Direct3D 11 interop.

**PSAccel is designed to run on clean, out-of-the-box Windows installations.** No third-party libraries or external tools are required—just PowerShell and your system's built-in Direct3D runtime.


---

## Current Feature: `PSA_Where-Object`

Use `PSA_Where-Object` (or `?G`) to filter numeric properties with GPU acceleration.

### Supported:

* Comparison operations: `-gt`, `-lt`, `-ge`, `-le`, `-eq`, `-ne`
* Numeric scalar comparisons (`float`, `int`, `double`)
* `$_` shorthand and pipeline input

### Example:

```powershell
1..1000000 | ForEach-Object { [pscustomobject]@{ Score = $_ } } | ?G { $_.Score -gt 950000 }
```

---

## 📈 Benchmark Results

PSAccel dramatically outperforms native `Where-Object` on larger datasets:

| Dataset Size | Native Time | PSA Time | Speedup |
| ------------ | ----------- | -------- | ------- |
| 50,000       | 0.90 s      | 0.45 s   | 2.0x    |
| 100,000      | 2.68 s      | 1.11 s   | 2.4x    |
| 500,000      | 48.7 s      | 14.3 s   | 3.4x    |
| 1,000,000    | 193.8 s     | 52.4 s   | 3.7x    |

📊 See full benchmark data and plots in `/benchmark`

\\

---

## Benchmark Yourself

You can generate your own results:

```powershell
Import-Module .\PSAccel.psm1
Measure-PsaFilterPerformance -ReturnResults
```

> This will benchmark native vs accelerated filtering and output a CSV + graphs.

---

## Installation

1. Clone or download the repo
2. Import the module:

   ```powershell
   Import-Module .\PSAccel.psm1
   ```
3. Run your accelerated filtering via `PSA_Where-Object`

---

## Distributed Acceleration

PSAccel isn't limited to local execution. Thanks to PowerShell's remoting capabilities, GPU-accelerated filtering can be dispatched across multiple remote systems—even without installing the module on the target machine.

Because the entire module can be passed inline using `$using:`, there's no requirement to pre-deploy code to your compute nodes. This allows for **zero-install distributed GPU computation** on out-of-the-box Windows systems (with WinRM enabled).

### Example: One-liner remote dispatch

```powershell
Invoke-Command -ComputerName "RemoteNode01" -ScriptBlock {
    Add-Type -TypeDefinition $using:psaCode -Language CSharp
    $using:data | $using:GPU_Where-Object { $_.Value -gt 1000 }
}
```

Where `$psaCode` contains your inline `PSAccel.cs`, and `$GPU_Where-Object` is the function defined locally. The `$using:` scope ensures that both data and logic are transmitted without local file dependencies.

> This makes PSAccel suitable for **ad hoc distributed processing**, remote job execution, or even GPU resource pooling across heterogeneous systems.

---

## Roadmap

 Dynamic shader compilation

 Structured buffer dispatch

 PowerShell pipeline integration

 Multi-property comparison

 String filtering support

 GPU usage telemetry

---

## Why It Matters

PowerShell wasn’t built for high-throughput numeric filtering, but with DirectCompute and a well-optimized interop layer, we can bring parallelism to everyday tasks using PowerShell's user-friendly interface.

---

## License

MIT License. See [LICENSE](./LICENSE).

---

## Attribution Request
If you use PSAccel in your project, research, or publication, I kindly ask that you give credit by referencing this repository or mentioning my name. While not legally required under the MIT License, attribution helps support open development.

---

## Author

[Derek Poe](https://github.com/Derek-Poe)
Coder. Engineer. Doesn't know when to sleep.




> **Disclaimer:** PSAccel is an independent project and is not affiliated with, endorsed by, or supported by Microsoft Corporation.  
> Windows, Direct3D, and other Microsoft products mentioned herein are trademarks of Microsoft Corporation.
