---
title: "llama.cpp Gemma 3 12B 显存测试记录"
date: 2026-07-24
categories: [llm, benchmark, gpu]
tags: ["llama.cpp", "Gemma 3", "GGUF", "VRAM", "CUDA"]
---

这次测试记录的是 `llama.cpp` 在 Windows 本机上执行 Gemma 3 12B GGUF 模型时的显存占用和生成速度。测试脚本是 `run_llama.ps1`，模型目录为 `D:\workspace\llamacpp\llama.cpp\models\gemma-3-12b-it`，本次实际可用的权重文件是 `gemma-3-12b-it-Q4_K_M.gguf` 和 `gemma-3-12b-it-Q8_0.gguf`。

执行命令：

```powershell
.\run_llama.ps1 -ModelDir .\models\gemma-3-12b-it -Mode All -PredictTokens 64 -TimeoutSec 600
```

本次一共得到 11 条有效结果。`f16` 没有对应 GGUF 文件，因此被跳过。

## 测试项含义

这四类测试不能放在同一条横轴里解释，它们比较的是不同变量。

`Quant` 比较不同量化格式。本次包含 `Q4_K_M` 和 `Q8_0`，用来看权重量化方式对速度和显存的影响。

`NGL` 比较 `--n-gpu-layers`。本次包含 `0`、`1`、`16`、`999`，用来看模型层数放到 GPU 后对速度和显存的影响。

`CTX` 比较上下文长度。本次包含 `2048`、`4096`、`8192`，用来看 context size 增大后速度和显存的变化。

`KV` 比较 KV cache offload。本次包含 `KV-Offload-ON` 和 `KV-Offload-OFF`，用来看 KV cache 位置对速度和显存的影响。

## 汇总结果

| TestCategory | ModelParams | ContextSize | OffloadLayers | PeakVRAM_MB | TokensPerSec |
| --- | --- | ---: | ---: | ---: | ---: |
| Quant | Quant-Q4_K_M | 2048 | 999 | 7771 | 24.45 |
| Quant | Quant-Q8_0 | 2048 | 999 | 7826 | 1.22 |
| NGL | NGL-0 | 2048 | 0 | 1760 | 1.38 |
| NGL | NGL-1 | 2048 | 1 | 1769 | 1.33 |
| NGL | NGL-16 | 2048 | 16 | 3917 | 1.85 |
| NGL | NGL-999 | 2048 | 999 | 7821 | 24.64 |
| CTX | CTX-2048 | 2048 | 999 | 7830 | 24.05 |
| CTX | CTX-4096 | 4096 | 999 | 7822 | 22.63 |
| CTX | CTX-8192 | 8192 | 999 | 7822 | 19.59 |
| KV | KV-Offload-ON | 4096 | 999 | 7796 | 22.64 |
| KV | KV-Offload-OFF | 4096 | 999 | 7790 | 18.89 |

原始汇总数据：[Benchmark_Summary.csv](/assets/data/llama-cpp-gemma-3-12b-benchmark/Benchmark_Summary.csv)

显存时间序列：[VRAM_TimeSeries.csv](/assets/data/llama-cpp-gemma-3-12b-benchmark/VRAM_TimeSeries.csv)

## 总览图

总览图按四个测试组显示，类似 MATLAB `subplot`。这样能避免把量化格式、GPU offload 层数、上下文长度和 KV cache 这几类不同变量混在同一张图里。

![VRAM Analysis All](/assets/images/llama-cpp-gemma-3-12b-benchmark/VRAM_Analysis_All.png)

## Quant

`Q4_K_M` 的速度是 24.45 tokens/s，峰值显存 7771 MB。`Q8_0` 的峰值显存是 7826 MB，接近 Q4，但速度只有 1.22 tokens/s。

这组结果说明，在这台机器和这次命令参数下，Q8 并没有换来更好的吞吐，反而显著变慢。由于两者峰值显存都接近 7.8 GB，瓶颈不只来自最终显存峰值，还可能和内存搬运、分层 offload、模型加载状态有关。

![VRAM Analysis Quant](/assets/images/llama-cpp-gemma-3-12b-benchmark/VRAM_Analysis_Quant.png)

## NGL

`NGL-0` 和 `NGL-1` 的峰值显存在 1.76 GB 左右，但速度只有 1.38 和 1.33 tokens/s。`NGL-16` 的显存升到 3917 MB，速度提高到 1.85 tokens/s。`NGL-999` 的显存升到 7821 MB，速度达到 24.64 tokens/s。

这组结果最明显：只让少量层进入 GPU，对速度帮助很有限；接近全 GPU offload 后，吞吐提升非常大，但显存也接近 8 GB。

![VRAM Analysis NGL](/assets/images/llama-cpp-gemma-3-12b-benchmark/VRAM_Analysis_NGL.png)

## CTX

在 `ngl=999` 下，`ctx=2048`、`4096`、`8192` 的峰值显存分别是 7830、7822、7822 MB，速度分别是 24.05、22.63、19.59 tokens/s。

这说明本次测试里上下文长度增加后，峰值显存变化不明显，但生成速度下降。这个现象可能和短输出长度有关：`PredictTokens=64` 时，模型权重和运行时缓存已经占据主要显存，context size 对峰值显存的差异没有完全展开；但计算负担已经体现在速度下降上。

![VRAM Analysis CTX](/assets/images/llama-cpp-gemma-3-12b-benchmark/VRAM_Analysis_CTX.png)

## KV Cache

`KV-Offload-ON` 的速度是 22.64 tokens/s，峰值显存 7796 MB。`KV-Offload-OFF` 的速度是 18.89 tokens/s，峰值显存 7790 MB。

这组结果里，两者峰值显存几乎一样，但 KV offload 打开时速度更高。由于显存峰值差异很小，这里的主要差别更像是执行路径效率，而不是显存容量本身。

![VRAM Analysis KV](/assets/images/llama-cpp-gemma-3-12b-benchmark/VRAM_Analysis_KV.png)

## 备注

本次测试使用 `llama-completion.exe` 作为推理程序，避免 `llama-cli.exe` 在某些 PowerShell 场景里进入交互等待。脚本也更新了 `nvidia-smi.exe` 查找路径：如果 PATH 和 `System32` 找不到，会继续在 NVIDIA 安装目录和 Windows DriverStore 里查找，这样非交互执行时也能记录显存曲线。
