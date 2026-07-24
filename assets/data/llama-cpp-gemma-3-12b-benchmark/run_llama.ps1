param (
    [ValidateSet('Quant', 'NGL', 'CTX', 'KV', 'All')]
    [string]$Mode = 'All',
    [string]$CliPath = ".\build-cuda\bin\llama-completion.exe",
    [string]$ModelDir = ".\models\gemma-3-1b-it",
    [int]$PredictTokens = 64,
    [int]$TimeoutSec = 900
)

$ErrorActionPreference = "Stop"

try {
    $Mode = $Mode.Substring(0, 1).ToUpperInvariant() + $Mode.Substring(1).ToLowerInvariant()
    $Mode = if ($Mode -eq "Ngl") { "NGL" } elseif ($Mode -eq "Ctx") { "CTX" } elseif ($Mode -eq "Kv") { "KV" } else { $Mode }
}
catch {
    Write-Error $_
    exit 1
}

# 强制要求系统环境包含 Python 以支持绘图
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    Write-Warning "未检测到 Python，将仅导出 CSV 数据而不绘制曲线图。"
}

$Global:Results = @()
$Global:VramTimeSeries = @() # 用于绘制曲线的时间序列池
$Global:LogPath = ".\run_llama.log"
$Global:RawLogDir = ".\benchmark_logs"
$Global:NvidiaSmiPath = $null

function Write-RunLog {
    param([string]$Message)
    $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -LiteralPath $Global:LogPath -Value $line -Encoding UTF8
}

trap {
    Write-RunLog "FATAL $($_.Exception.Message)"
    Write-Error $_
    exit 1
}

Set-Content -LiteralPath $Global:LogPath -Value ("{0} run_llama start Mode={1} ModelDir={2} PredictTokens={3} TimeoutSec={4}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Mode, $ModelDir, $PredictTokens, $TimeoutSec) -Encoding UTF8
New-Item -ItemType Directory -Force -Path $Global:RawLogDir | Out-Null

$nvidiaSmiCmd = Get-Command nvidia-smi -ErrorAction SilentlyContinue
if ($nvidiaSmiCmd) {
    $Global:NvidiaSmiPath = $nvidiaSmiCmd.Source
}
else {
    $candidateNvidiaSmiPaths = @(
        (Join-Path $env:WINDIR "System32\nvidia-smi.exe"),
        (Join-Path $env:ProgramFiles "NVIDIA Corporation\NVSMI\nvidia-smi.exe")
    )

    foreach ($candidateNvidiaSmi in $candidateNvidiaSmiPaths) {
        if (Test-Path -LiteralPath $candidateNvidiaSmi) {
            $Global:NvidiaSmiPath = $candidateNvidiaSmi
            break
        }
    }

    if (-not $Global:NvidiaSmiPath) {
        $driverStoreRoot = Join-Path $env:WINDIR "System32\DriverStore\FileRepository"
        if (Test-Path -LiteralPath $driverStoreRoot) {
            $driverStoreNvidiaSmi = Get-ChildItem -LiteralPath $driverStoreRoot -Recurse -Filter "nvidia-smi.exe" -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1
            if ($driverStoreNvidiaSmi) {
                $Global:NvidiaSmiPath = $driverStoreNvidiaSmi.FullName
            }
        }
    }
}

if (-not $Global:NvidiaSmiPath) {
    Write-Warning "未检测到 nvidia-smi，将记录速度，但显存峰值和曲线为空。"
    Write-RunLog "WARN nvidia-smi-not-found"
}

$Prompt = "Please explain in points: 1. What are the effects of quantization, GPU offload, and KV cache in llama.cpp? 2. Provide an experimental plan."

# 【核心修复 1】：将 Prompt 强制落盘为 UTF-8 文件，彻底避开命令行参数逃逸
$PromptFile = ".\temp_prompt.txt"
Set-Content -Path $PromptFile -Value $Prompt -Encoding UTF8

function Resolve-GgufModel {
    param([string]$Quant)

    if (-not (Test-Path -LiteralPath $ModelDir)) {
        throw "未找到模型目录: $ModelDir"
    }

    $files = @(Get-ChildItem -LiteralPath $ModelDir -Filter "*.gguf" -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch "^mmproj" })
    if ($files.Count -eq 0) {
        $configPath = Join-Path $ModelDir "config.json"
        if (Test-Path -LiteralPath $configPath) {
            try {
                $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($config.model_type -eq "gemma4_assistant" -or ($config.architectures -contains "Gemma4AssistantForCausalLM")) {
                    throw "模型目录是 Gemma 4 assistant/drafter，不是可单独 benchmark 的 31B target 模型: $ModelDir。请使用 google/gemma-4-31B-it 的 GGUF 文件。"
                }
            }
            catch {
                if ($_.Exception.Message -like "*Gemma 4 assistant/drafter*") {
                    throw
                }
            }
        }
        throw "模型目录中没有 GGUF 文件: $ModelDir。当前脚本不能直接运行 safetensors，请先转换或下载 GGUF 量化文件。"
    }

    $match = $files | Where-Object { $_.BaseName -match "(^|[-_.])$([regex]::Escape($Quant))($|[-_.])" } | Select-Object -First 1
    if (-not $match) {
        $available = ($files | Select-Object -ExpandProperty Name) -join ", "
        throw "未找到量化类型 $Quant 对应的 GGUF 文件。目录: $ModelDir；可用文件: $available"
    }

    return $match.FullName
}

function Try-ResolveGgufModel {
    param([string]$Quant)

    try {
        return Resolve-GgufModel $Quant
    }
    catch {
        return $null
    }
}

function Resolve-BenchmarkModel {
    foreach ($quant in @("Q4_K_M", "Q8_0", "f16", "bf16")) {
        $model = Try-ResolveGgufModel $quant
        if ($model) {
            return $model
        }
    }

    throw "未找到可用于 benchmark 的 GGUF 文件。"
}

function Get-TokensPerSecond {
    param([string]$Text)

    $normalized = $Text -replace "`e\[[0-9;?]*[ -/]*[@-~]", ""
    $normalized = $normalized -replace "tokens\s+per\s+second", "tokens per second"

    $matches = [regex]::Matches($normalized, "eval time\s*=\s*[\s\S]*?\(\s*([0-9.]+)\s*ms per token,\s*([0-9.]+)\s*tokens per second\)", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($matches.Count -gt 0) {
        return [math]::Round([double]$matches[$matches.Count - 1].Groups[2].Value, 2)
    }

    $matches = [regex]::Matches($normalized, "Generation:\s*([0-9.]+)\s*t/s", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($matches.Count -gt 0) {
        return [math]::Round([double]$matches[$matches.Count - 1].Groups[1].Value, 2)
    }

    $matches = [regex]::Matches($normalized, "(?:eval|generation)[^`r`n]*?([0-9.]+)\s*(?:tokens/s|tok/s|t/s)", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($matches.Count -gt 0) {
        return [math]::Round([double]$matches[$matches.Count - 1].Groups[1].Value, 2)
    }

    return 0
}

function Get-GpuMemoryUsedMB {
    if (-not $Global:NvidiaSmiPath) {
        return $null
    }

    $currentStr = (& $Global:NvidiaSmiPath --query-gpu=memory.used --format=csv,noheader,nounits 2>$null) -join ""
    $current = 0
    if ([int]::TryParse($currentStr.Trim(), [ref]$current)) {
        return $current
    }

    return $null
}

function Invoke-LLMTest {
    # 【核心修复 1】：补齐被遗漏的 Prompt 参数声明，彻底杜绝传参报错越界
    param([string]$TestName, [string]$Model, [int]$Ctx, [int]$Ngl, [string]$Prompt, [string]$ExtraArgs = "")

    Write-Host "`n[▶] 正在运行测试: $TestName" -ForegroundColor Cyan

    if (-not (Test-Path -LiteralPath $CliPath)) {
        throw "未找到推理程序: $CliPath"
    }
    if (-not (Test-Path -LiteralPath $Model)) {
        throw "未找到模型文件: $Model"
    }
    Write-Host "    -> 模型: $([System.IO.Path]::GetFileName($Model)) | ctx=$Ctx | ngl=$Ngl | n=$PredictTokens" -ForegroundColor DarkGray
    Write-RunLog "START $TestName model=$([System.IO.Path]::GetFileName($Model)) ctx=$Ctx ngl=$Ngl n=$PredictTokens"

    $argList = @("-m", $Model, "-f", $PromptFile, "-c", $Ctx.ToString(), "-n", $PredictTokens.ToString(), "-ngl", $Ngl.ToString(), "-t", "12")
    if (![string]::IsNullOrWhiteSpace($ExtraArgs)) { $argList += $ExtraArgs.Split(' ') }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = (Resolve-Path -LiteralPath $CliPath).Path
    foreach ($arg in $argList) {
        [void]$psi.ArgumentList.Add($arg)
    }
    $psi.WorkingDirectory = (Get-Location).Path
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi

    $maxVram = 0
    $testVramTimeSeries = @()
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $lastProgressSecond = 0
    [void]$proc.Start()
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $proc.StandardInput.Close()

    try {
        # 显存监控循环
        while (!$proc.HasExited) {
            if ($watch.Elapsed.TotalSeconds -gt $TimeoutSec) {
                Write-Warning "进程超时，正在停止: $TestName"
                Write-RunLog "TIMEOUT $TestName elapsed=$([int]$watch.Elapsed.TotalSeconds)s"
                Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
                break
            }

            $current = Get-GpuMemoryUsedMB
            if ($null -ne $current) {
                if ($current -gt $maxVram) { $maxVram = $current }

                $testVramTimeSeries += [PSCustomObject]@{
                    TestName = $TestName
                    TimeSec  = [math]::Round($watch.Elapsed.TotalSeconds, 2)
                    VRAM_MB  = $current
                }

                $elapsedWholeSecond = [int]$watch.Elapsed.TotalSeconds
                if ($elapsedWholeSecond -ge ($lastProgressSecond + 10)) {
                    $lastProgressSecond = $elapsedWholeSecond
                    Write-Host ("    .. {0}s | 当前显存 {1} MB | 峰值 {2} MB" -f $elapsedWholeSecond, $current, $maxVram) -ForegroundColor DarkGray
                    Write-RunLog ("PROGRESS {0} elapsed={1}s vram={2}MB peak={3}MB" -f $TestName, $elapsedWholeSecond, $current, $maxVram)
                }
            }
            Start-Sleep -Milliseconds 200
        }
    }
    finally {
        if (-not $proc.HasExited) {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        }
    }

    $proc.WaitForExit()
    $proc.WaitForExit()
    $output = $stdoutTask.GetAwaiter().GetResult()
    $errorOutput = $stderrTask.GetAwaiter().GetResult()
    $combinedOutput = "$output`n$errorOutput"
    $safeName = $TestName -replace '[^A-Za-z0-9_.-]', '_'
    $rawLogPath = Join-Path $Global:RawLogDir "$safeName.log"
    Set-Content -LiteralPath $rawLogPath -Value $combinedOutput -Encoding UTF8

    $tps = Get-TokensPerSecond $combinedOutput

    if ($tps -le 0) {
        $message = ($combinedOutput -split "`r?`n" | Where-Object {
            $_ -match "error|failed|corrupt|incomplete" -and $_ -notmatch "common_fit_params: failed to fit params"
        } | Select-Object -First 3) -join " "
        if ([string]::IsNullOrWhiteSpace($message)) {
            $message = "未能解析有效速度。"
        }
        Write-Warning "跳过 $TestName：$message 原始日志: $rawLogPath"
        Write-RunLog "SKIP $TestName exit=$($proc.ExitCode) message=$message raw=$rawLogPath"
        return
    }
    elseif ($proc.ExitCode -ne 0) {
        Write-RunLog "WARN $TestName exit=$($proc.ExitCode) but-speed-parsed tps=$tps raw=$rawLogPath"
    }

    $record = [PSCustomObject]@{
        TestCategory = $TestName.Split('-')[0]
        ModelParams  = $TestName
        ContextSize  = $Ctx
        OffloadLayers= $Ngl
        PeakVRAM_MB  = $maxVram
        TokensPerSec = $tps
    }

    $Global:Results += $record
    $Global:VramTimeSeries += $testVramTimeSeries
    Write-Host "    -> 速度: $tps Tok/s | 显存峰值: $maxVram MB" -ForegroundColor Green
    Write-RunLog "DONE $TestName exit=$($proc.ExitCode) tps=$tps peak=$maxVram raw=$rawLogPath"
}

# 矩阵定义
if ($Mode -in 'Quant', 'All') {
    @("Q4_K_M", "Q8_0", "f16") | ForEach-Object {
        $quantModel = Try-ResolveGgufModel $_
        if ($quantModel) {
            Invoke-LLMTest -TestName "Quant-$_" -Model $quantModel -Prompt $Prompt -Ctx 2048 -Ngl 999
        }
        else {
            Write-Warning "跳过 Quant-$_：模型目录中没有对应 GGUF 文件。"
            Write-RunLog "SKIP Quant-$_ missing-model"
        }
    }
}
if ($Mode -in 'NGL', 'All') {
    $nglModel = Resolve-BenchmarkModel
    @(0, 1, 16, 999) | ForEach-Object {
        Invoke-LLMTest -TestName "NGL-$_" -Model $nglModel -Prompt $Prompt -Ctx 2048 -Ngl $_
    }
}
if ($Mode -in 'CTX', 'All') {
    $ctxModel = Resolve-BenchmarkModel
    @(2048, 4096, 8192) | ForEach-Object {
        Invoke-LLMTest -TestName "CTX-$_" -Model $ctxModel -Prompt $Prompt -Ctx $_ -Ngl 999
    }
}
if ($Mode -in 'KV', 'All') {
    $mPath = Resolve-BenchmarkModel
    Invoke-LLMTest -TestName "KV-Offload-ON" -Model $mPath -Prompt $Prompt -Ctx 4096 -Ngl 999
    Invoke-LLMTest -TestName "KV-Offload-OFF" -Model $mPath -Prompt $Prompt -Ctx 4096 -Ngl 999 -ExtraArgs "--no-kv-offload"
}

if ($Global:Results.Count -eq 0) {
    Write-RunLog "FAIL no-results"
    throw "没有可导出的测试结果。请确认 $ModelDir 中至少有一个可用的 GGUF 文件。"
}

# 1. 导出汇总与时间序列数据
$RunStamp = Get-Date -Format "yyyyMMdd_HHmmss"
$SummaryCsvPath = ".\Benchmark_Summary.csv"
$VramCsvPath = ".\VRAM_TimeSeries.csv"
$VramCsvForPlot = ".\VRAM_TimeSeries_$RunStamp.csv"
$PlotPath = ".\VRAM_Analysis_$Mode.png"
$TimestampedPlotPath = ".\VRAM_Analysis_${Mode}_$RunStamp.png"

$Global:Results | Export-Csv -Path $SummaryCsvPath -NoTypeInformation -Encoding UTF8 -Force -ErrorAction Stop
$Global:VramTimeSeries | Export-Csv -Path $VramCsvForPlot -NoTypeInformation -Encoding UTF8 -Force -ErrorAction Stop
Write-RunLog "EXPORT summary=$SummaryCsvPath vram=$VramCsvForPlot"
try {
    Copy-Item -LiteralPath $VramCsvForPlot -Destination $VramCsvPath -Force -ErrorAction Stop
}
catch {
    Write-Warning "无法更新 $VramCsvPath，绘图将使用本次运行的 $VramCsvForPlot。错误: $_"
    Write-RunLog "WARN copy-vram-csv message=$_"
}

# 2. 动态生成 Python 绘图脚本并执行
$PyScript = @"
import pandas as pd
import matplotlib.pyplot as plt
import seaborn as sns
import sys
import os

try:
    csv_path = os.environ.get('VRAM_CSV_PATH', 'VRAM_TimeSeries.csv')
    if not os.path.exists(csv_path):
        print(f'{csv_path} was not found.')
        sys.exit(1)
    if os.path.getsize(csv_path) == 0:
        print(f'{csv_path} is empty; skip plotting.')
        sys.exit(0)

    df = pd.read_csv(csv_path)
    if df.empty:
        print('VRAM_TimeSeries.csv is empty; skip plotting.')
        sys.exit(0)

    sns.set_theme(style='darkgrid')

    preferred_order = ['Quant', 'NGL', 'CTX', 'KV']
    titles = {
        'Quant': 'Quantization comparison',
        'NGL': 'GPU offload layers comparison',
        'CTX': 'Context size comparison',
        'KV': 'KV cache offload comparison',
    }
    df['Category'] = df['TestName'].str.split('-', n=1).str[0]
    present = [category for category in preferred_order if category in set(df['Category'])]

    if not present:
        print('No benchmark categories found; skip plotting.')
        sys.exit(0)

    if len(present) == 1:
        fig, axes = plt.subplots(1, 1, figsize=(11, 6), sharex=False, sharey=False)
        axes = [axes]
    elif len(present) == 2:
        fig, axes = plt.subplots(1, 2, figsize=(14, 5.5), sharex=False, sharey=False)
        axes = axes.flatten()
    else:
        fig, axes = plt.subplots(2, 2, figsize=(14, 9), sharex=False, sharey=False)
        axes = axes.flatten()

    for ax, category in zip(axes, present):
        data = df[df['Category'] == category]
        sns.lineplot(data=data, x='TimeSec', y='VRAM_MB', hue='TestName', linewidth=2, ax=ax)
        ax.set_title(titles[category], fontsize=12)
        ax.set_xlabel('Time (seconds)')
        ax.set_ylabel('VRAM used (MB)')
        ax.legend(title=None, fontsize=9)

    for ax in axes[len(present):]:
        ax.axis('off')

    fig.suptitle('VRAM Consumption by Benchmark Group', fontsize=15)
    fig.tight_layout(rect=[0, 0, 1, 0.96])

    output_path = os.environ.get('VRAM_PLOT_PATH', 'VRAM_Analysis_Curve.png')
    timestamped_output_path = os.environ.get('VRAM_TIMESTAMPED_PLOT_PATH', '')
    plt.savefig(output_path, dpi=300)
    if timestamped_output_path:
        plt.savefig(timestamped_output_path, dpi=300)
    if os.path.basename(output_path) == 'VRAM_Analysis_All.png':
        plt.savefig('VRAM_Analysis_Curve.png', dpi=300)
    print(f'\n[OK] VRAM curve rendered: {output_path}')
except Exception as e:
    print(f'Plot failed: {e}')
"@

Set-Content -Path ".\plot_vram.py" -Value $PyScript -Encoding UTF8

if ((Get-Command python -ErrorAction SilentlyContinue) -and $Global:VramTimeSeries.Count -gt 0) {
    # 确保依赖存在，无声安装 matplotlib 和 seaborn (如果已安装会极快跳过)
    Write-Host "`n[▶] 正在检查 Python 依赖并绘制曲线图..." -ForegroundColor Cyan
    python -m pip install -q pandas matplotlib seaborn
    $env:VRAM_CSV_PATH = (Resolve-Path -LiteralPath $VramCsvForPlot).Path
    $env:VRAM_PLOT_PATH = $PlotPath
    $env:VRAM_TIMESTAMPED_PLOT_PATH = $TimestampedPlotPath
    try {
        python .\plot_vram.py
        Write-RunLog "PLOT $PlotPath"
    }
    finally {
        Remove-Item Env:\VRAM_CSV_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:\VRAM_PLOT_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:\VRAM_TIMESTAMPED_PLOT_PATH -ErrorAction SilentlyContinue
    }
}
elseif ($Global:VramTimeSeries.Count -eq 0) {
    Write-Warning "没有显存时间序列，跳过绘图。"
    Write-RunLog "SKIP plot no-vram-series"
}
