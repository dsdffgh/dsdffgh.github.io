---
title: "Linux emmc管理"
date: 2024-06-29
categories: [linux, kernel, emmc]
tags: ["Block Device", "emmc"]
---

# emmc概要

eMMC 是 NAND Flash 和 Flash Controller 的集成器件，通过标准 MMC 接口提供块存储能力，内部完成 ECC、坏块管理、磨损均衡等 Flash 管理。

裸 NAND 需要主控承担更多 Flash 管理工作，而 eMMC 内部已经集成控制器，对主机提供逻辑块接口，因此软件开发更加简单。

```text
SoC
 |
eMMC接口
 |
+------------------+
| Controller       |
| NAND Flash       |
+------------------+
```

# emmc启动

对于soc板卡，上电以后，首先要从rom启动（因为是内部固化程序，会有个简易驱动初始化MMC Controller 然后读取SPL/uboot/FSBL，把它们加载到ram）。emmc中的boot分区会存SPL/uboot。

```
eMMC
├── Boot Partition 0
│    ├── Image
│    └── board.dtb
├── Boot Partition 1
├── RPMB
└── User Area
```

启动就会rom->SPL->uboot，uboot再初始化一遍emmc，然后读取kernel image和dtb并加载。一个dts例子：

<pre class="overflow-visible! px-0!" data-start="2183" data-end="2393"><div class="relative w-full mt-4 mb-1"><div class=""><div class="contents"><div class="border border-token-border-light border-radius-3xl corner-superellipse/1.1 rounded-3xl"><div class="relative h-full w-full border-radius-3xl bg-(--code-block-surface) corner-superellipse/1.1 overflow-clip rounded-3xl [--code-block-surface:var(--bg-elevated-secondary)] dark:[--code-block-surface:var(--composer-surface-primary)] lxnfua_clipPathFallback"><div class="pointer-events-none absolute inset-x-4 top-12 bottom-4"><div class="pointer-events-none sticky z-40 shrink-0 z-1!"><div class="sticky bg-token-border-light"></div></div></div><div class="relative"><div class="h-full min-h-0 min-w-0"><div class="h-full min-h-0 min-w-0"><div class=""><div class="relative"><div class=""><div class="relative z-0 flex h-full min-h-0 max-w-full"><div id="866183f6-ddb1-44b4-8bb6-9bc045b57cc9:19:editor" dir="ltr" class="Rx43rG_codemirror z-10 flex h-full min-h-0 w-full flex-col items-stretch"><div class="cm-editor ͼ1 ͼ3 ͼs ͼ16"><div class="cm-announced" aria-live="polite"></div><div tabindex="-1" class="cm-scroller"><div spellcheck="false" autocorrect="off" autocapitalize="off" writingsuggestions="false" translate="no" contenteditable="false" class="cm-content" role="textbox" aria-multiline="true" aria-readonly="true" aria-label="Edit code"><div class="cm-line">mmc0: mmc@12340000 {</div><div class="cm-line">    compatible = &#34;vendor,soc-mmc&#34;;</div><div class="cm-line">    reg = &lt;0x12340000 0x1000&gt;;</div><div class="cm-line"><br/></div><div class="cm-line">    interrupts = &lt;...&gt;;</div><div class="cm-line"><br/></div><div class="cm-line">    clocks = &lt;...&gt;;</div><div class="cm-line"><br/></div><div class="cm-line">    bus-width = &lt;8&gt;;</div><div class="cm-line"><br/></div><div class="cm-line">    non-removable;</div><div class="cm-line"><br/></div><div class="cm-line">    status = &#34;okay&#34;;</div><div class="cm-line">};</div></div></div></div></div></div></div></div></div></div></div><div class=""><div class=""></div></div></div></div></div></div></div></div></pre>

emmc通常是焊死的，所以会有*non-removable*。

下一步是Platform Bus根据compatible匹配驱动，调用probe()。
probe一般会获取寄存器资源然后ioremap到内核空间，获取IRQ、reset、pinctrl等内容，还要申请DMA和分配`struct mmc_host`（代表一个mmc host controller)。

初始化结束后mmc_add_host，mmc core开始枚举emmc设备，发送CMD来reset、确认、读取CID（获取card identifcation如名称、版本序列号等）……

然后用`struct mmc_card`描述emmc device，因为MMC子系统有自己的mmc bus，这就注册好了device model，交给mmc block driver来继续匹配（进入Linux Block Layer）并probe。把它从mmc协议设备转换为linux block device。建立如下内容：

```text
request queue
blk-mq
gendisk
容量
扇区大小
设备名
```

`struct gendisk`被注册给Linux Block Layer后出现`/sys/block/mmcblk0`,一般驱动注册后会自动创建`/dev/mmcblk0`，然后若存在分区表，Linux Block Layer就会直接解析分区生成

```text
/dev/mmcblk0p1
/dev/mmcblk0p2
/dev/mmcblk0p3
```

如果 Kernel Command Line：

```shell
root=/dev/mmcblk0p2
```

kernel回去找这个分区，识别并挂载rootfs，运行init。

当发生读`/dev/mmcblk0`的时候：

```shell
dd if=/dev/mmcblk0 of=/tmp/test bs=4K count=1
```

```text
User
 |
 | read()
 ↓
VFS
 |
 ↓
Block Layer
 |
 ↓
blk-mq
 |
 ↓
mmcblk
 |
 ↓
MMC Core
 |
 ↓
MMC Host Driver
 |
 ↓
SoC MMC Controller
 |
 | CMD / DATA
 ↓
eMMC Controller
 |
 ↓
NAND
```



## 一个qemu让运行的linux能启动的最小模拟


“让 Linux 驱动 probe 并继续启动”的设备模型，不是完整硬件仿真。完整实现还缺这些内容：

**MMC / `phytium,mci`**

* 真实卡模型：现在没有绑定 ​eMMC​/SD 后端，也不会生成可读写的 `mmcblk` 设备。
* MMC 协议响应：需要实现 CMD0、CMD1、CMD2、CMD3、CMD6、CMD7、CMD8、CMD9、CMD13、CMD17/18、CMD24/25 等命令，以及 OCR、CID、CSD、EXT\_CSD。
* 数据通路：当前没有实现 FIFO 数据读写、block read/write、scatter-gather DMA 描述符解析、ADMA/IDMAC 传输。
* 中断语义：现在只模拟了启动阶段需要的 CMD/RTO/DTO 和 W1C 行为，完整实现要按真实硬件时序产生 command complete、data done、CRC、timeout、DMA 中断。
* 卡状态：需要完整处理 card busy、card detect、write protect、reset、power on/off、voltage switch、bus width、clock divider。
* MMC1：当前设备也映射了，但设备树里 `mmc@28001000` 是 `disabled`，完整验证还需要启用节点后确认双控制器行为。



