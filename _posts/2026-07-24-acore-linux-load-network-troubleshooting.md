---
title: "ACore Linux 加载与 Windows TAP 网络排查记录"
date: 2026-07-24
categories: [virtualization, qemu]
tags: ["ACore", "QEMU", "TAP", "Windows", "troubleshooting"]
---

## 1. 最终结果

本文记录 2026-06-18 至 2026-06-22 从原始压缩包重建 QEMU、gos5、inter_linux 和 Linux kernel，逐段处理启动停滞，直到 Windows 宿主机可以 ping 通 ACore Linux 的实际过程。

```text
QEMU PID:          29988
QEMU 网络后端:     TAP，tap0
Windows tap0:      169.254.127.40/16
MSL loader:        169.254.127.50:1118
ACore Linux eth0:  169.254.127.51/16
Guest MAC:         2a:98:5a:42:00:00
Windows ping:      4/4，0% 丢包
```

当前 QEMU 使用 `tcg,thread=multi`、4 个 vCPU、`fte2000-board,secure=on` 和：

```text
-net nic,model=cadence_gem,netdev=t0
-netdev tap,ifname=tap0,script=no,downscript=no,id=t0
-display none -monitor none -serial null -serial stdio
```

最终证据：

```text
串口: D:\temp\acore-original-repro-20260618-1705\serial-disable-display.log
加载: D:\temp\acore-original-repro-20260618-1705\udp-load-disable-display.log
构建: D:\temp\acore-original-repro-20260618-1705\build-disable-display.log
```

旧文档引用了另一组成功日志、过时的 kernel config 来源和不适用于本次最终运行的耗时。本文只采用上述新日志和当前 PID 29988。

## 2. 输入、目录和产物

```text
QEMU 压缩包:  D:\zdk\code\virtual_platform.7z
应用压缩包:  D:\software\ACoreMCICS_V0.3.1.1.3_20260227\gos5.zip
kernel 包:    D:\zdk\code\ACoreLinuxSrc-Kernel-RTV1.3.0.0-Phytium.tar.gz
复现目录:     D:\temp\acore-original-repro-20260618-1705
QEMU:         ...\qemu-source
gos5:         ...\application\gos5
inter_linux:  ...\application\inter_linux
kernel 构建:  WSL ext4 /home/acore-final-20260622/.../kernel-source
```

最终 QEMU：

```text
D:\temp\acore-original-repro-20260618-1705\qemu-source\build-repro\qemu-system-aarch64.exe
```

最终镜像：

```text
D:\temp\acore-original-repro-20260618-1705\application\inter_linux\armv8a_64\bin\gos5.bin
SHA-256: 5F6F746BE5FE6163A57A56987935DAA3556CC9DB495C00490B989697D67DF262
```

gos5 工程产物与 inter_linux 中的镜像 SHA-256 相同，证明加载的是最新构建。

## 3. 启动阶段和地址

同一串口依次包含 MSL、ACoreOSMCS/hypervisor 和 Linux 输出：

| 地址 | 阶段 | 用途 |
| --- | --- | --- |
| `169.254.127.40/16` | Windows | `tap0` 主机地址 |
| `169.254.127.50:1118` | MSL | Linux 启动前接收镜像 |
| `169.254.127.51/16` | Linux | guest `eth0` 地址 |

看到下列内容只是 MSL 等待加载：

```text
MSL CHANNEL UDP:
IP:169.254.127.50, PORT:1118
MAC:02-21-18-31-26-19
```

每次判断同时检查 QEMU PID、命令行、串口长度和更新时间、initcall 的 `calling/returned`、panic call trace、ARP 和 ping。`169.254.127.40: Destination host unreachable` 是 Windows 自己返回，并非 guest 回复。

## 4. 完整时间线

### 2026-06-18：原始包复现

1. 展开原始 QEMU 和应用并完成 MSL UDP 加载。
2. 原始组合稳定停在 `psciLibInit, version(1, 1)`。QEMU 存活，串口 30 秒无增长。
3. 检查 fte2000 的 GICv3 redistributor。问题点在 QEMU 暴露给 guest 的 `redist-region-count` 和实际 MMIO 映射方式不匹配：Linux 按一个 region 访问多个 vCPU 的 redistributor 时，QEMU 侧需要用同一种布局描述和映射它们。
4. 修正并重建 QEMU 后，同一 payload 越过 PSCI。
5. 新停滞发生在 `ahci 31a40000.sata`。QEMU 没有实现 DT 中的两个 SATA 控制器。
6. 在 `vmLinux.c` 中对即将传给 Linux 的内存 DTB 调用 `fdt_del_node()`，删除两个 SATA 节点后继续启动。原始 DTB 文件本身没有被改写。
7. 启用 `initcall_debug ignore_loglevel loglevel=8`，识别出 `phytium_mci_driver_init` 进入后长期没有返回。
8. 同样在运行期删除两个 MMC/MCI 节点后，原始 kernel/rootfs 到达 `acorelinux631 login:`。

### 2026-06-22：kernel、rootfs 和网络

1. 原始 config 中 `VIRTIO` 和 `VIRTIO_MMIO` 为 built-in，`VIRTIO_NET`、`FAILOVER`、`NET_FAILOVER` 为 module，early userspace 不能直接保证创建 `eth0`。
2. Windows 展开的 kernel tree 存在 `Documentation/Kbuild` 文件与 `Documentation/kbuild/` 目录冲突。NTFS 默认无法可靠表示该大小写结构，树中还有约 8.5 GB 旧产物。
3. 在 Ubuntu 24.04 WSL ext4 中直接解压原始 kernel 包并构建，只复制最终 `Image` 回 Windows。
4. 将 `VIRTIO`、`VIRTIO_MMIO`、`VIRTIO_NET`、`FAILOVER`、`NET_FAILOVER` 设为 built-in。
5. `Image` SHA-256 为 `5f95bbfbbc26187b2b81d1a047b88e7287166c932b7e5cd5de0e9b3c8e7b976e`。
6. rootfs 注入静态 AArch64 `/codex-init`，启用 `eth0` 并设置 `169.254.127.51/16`。
7. 重建 gos5，再重建 inter_linux。`gosImages.S` 使用 `.incbin` 嵌入 Image、DTB 和 ramdisk，inter_linux 随后复制并签名 `gos5.bin`。
8. 第一版新 kernel 的串口表面停在正式 PL011 console 接管处；后续证明 PL011 本身并非失败点。bootconsole 被关闭后，下一处 display panic 没有继续从 early console 打出来。
9. 使用 `earlycon=pl011,0x2800d000 keep_bootcon` 后保留 early console，继续取得日志，发现 display driver panic。
10. QEMU 使用 `-display none`，未实现显示 PHY。运行期删除 `/soc/dc@32000000` 后，kernel 进入 rootfs。
11. 串口出现 `eth0`、静态地址和 `[codex-init] ready`；Windows ping 4/4 成功。

## 5. 停滞位置、错误证据和处理

### 5.1 PSCI / GICv3

PSCI 是 ARM 操作系统通过 SMC/HVC 请求 CPU on/off、suspend、reset 等服务的标准接口。GICv3 是中断控制器，负责 Distributor、Redistributor、SGI/PPI/SPI、timer interrupt 和 IPI。两者属于不同模块，但多核启动时会连续出现：PSCI 负责让 secondary CPU 进入指定入口，随后每个 CPU 都要通过 GICv3 redistributor 和 CPU interface 正常收中断。`psciLibInit` 位于 Linux EL1、ACore hypervisor/firmware 和 QEMU GIC/CPU 模型交界处，早于 Linux driver 和 rootfs。

QEMU 处理：

- GICv3 对 guest 声明一个 redistributor region，region 内包含全部 vCPU 的 redistributor。
- redistributor MMIO 与上述声明保持一致，只把 region 1 映射一次到 `0x30880000`。
- 关闭 guest `pauth`，保留原包已有的 SVE 关闭设置。
- fte2000 的 `GICR_WAKER` 初始为 active，避免 guest 等待 `ChildrenAsleep` 清除。

选择 QEMU 修改是因为 A/B 对照中，同一应用只更换修正后的 QEMU 就能继续。rootfs 和 IP 无法影响这个阶段。这里的判断标准是：guest 看到的 redistributor 描述必须和 QEMU 实际提供的 MMIO region 一致。

当时是从三个现象判断出来的。

第一，QEMU 机器代码里 CPU 数量是动态的：

```
unsigned int smp_cpus = ms->smp.cpus;

qdev_prop_set_uint32(gicdev, "num-cpu", smp_cpus);
```

但同一个 `create_gic()` 里，GICv3 redistributor region 数量却写死了 4 个：

```
qlist_append_int(redist_region_count, 1);
qlist_append_int(redist_region_count, 1);
qlist_append_int(redist_region_count, 1);
qlist_append_int(redist_region_count, 1);
```

这就产生了结构性矛盾：`num-cpu` 可以是 1、2、4 等，但 redistributor region 始终按 4 个区域声明。GICv3 的 redistributor 是按 CPU 亲和关系发现的，每个 CPU 至少要有对应的 redistributor frame。CPU 拓扑和 redistributor 描述数量不一致时，Linux 看到的中断控制器布局就不再可信。

第二，MMIO 映射代码并不是固定映射 4 个，而是按 `smp_cpus` 映射：

```
for (i = 0; i < smp_cpus; i++) {
    sysbus_mmio_map(s, i + 1, 0x30880000 + 0x20000 * i);
}
```

也就是说，实际映射的 redistributor region 数量跟 `smp_cpus` 走，但传给 GICv3 设备模型的 `redist-region-count` 固定是 4。一个地方说“有 4 个 redistributor region”，另一个地方只映射当前 CPU 数量对应的 region，这就是“描述与映射方式不一致”。

第三，Linux 启动日志能侧面验证这个布局。正常情况下 Linux 会打印类似：

```
GICv3: CPU0: found redistributor 200 region 0:0x00000000308c0000
```

如果多核布局和 redistributor 描述不一致，常见表现是 secondary CPU 找不到自己的 redistributor，或者 CPU affinity 对不上，后续会影响 PPI、timer interrupt、IPI、SMP bring-up。虽然你现在日志里只看到 CPU0，是因为当前有效启动主要跑在单核路径上；但代码层面已经能看出：一旦 `-smp` 和固定 4 region 不匹配，问题会暴露。

所以当时的修法是把固定 4 次 append 改成按 `smp_cpus` 生成：

```
for (i = 0; i < MAX(1u, smp_cpus); i++) {
    qlist_append_int(redist_region_count, 1);
}
```

这样 `num-cpu`、redistributor region 描述、`sysbus_mmio_map()` 的循环次数三者一致。这个修改不是为了改 Linux 某个日志，而是让 GICv3 设备模型的拓扑描述和 QEMU 实际映射保持一致。

### 5.2 AHCI 与 MCI

DT 中 `status = "okay"` 会让 Linux 创建设备。QEMU 未提供对应 MMIO、中断或时钟行为时，probe 会等待或访问无实现寄存器。

本次没有编辑原始 `.dts` 或 `.dtb` 文件。`vmLinux.c` 在 `bootiTest()` 前拿到已加载到内存的 DTB 地址 `0xf2000000`，通过 `fdt_path_offset()` 找节点，再通过 `fdt_del_node()` 删除节点。Linux 最终看到的是已经删过节点的内存 DTB，因此不会 probe 这些设备。

删除：

```text
/soc/sata@31a40000
/soc/sata@32014000
/soc/mmc@28000000
/soc/mmc@28001000
```

选择修正 DT，是因为当前虚拟硬件确实没有这些设备。修改 Linux AHCI/MCI driver 会保留错误硬件描述；实现 SATA/MMC 虚拟设备工作量更大，也超出当前 Linux 启动和联网验证所需范围。

### 5.3 PL011 console

表面失败边界：

```text
printk: console [ttyAMA1] enabled
printk: bootconsole [pl11] disabled
```

最终 bootargs：

```text
console=ttyAMA1,115200 earlycon=pl011,0x2800d000 keep_bootcon
root=/dev/ram0 rw ramdisk_size=0x2000000
net.ifnames=0 rdinit=/codex-init init=/codex-init initcall_debug
```

这两行的意思是：早期启动先用 `earlycon=pl011,0x2800d000` 注册的 bootconsole 打日志；Linux 的 PL011 driver probe 到 `2800d000.uart` 后，把正式 console 注册为 `ttyAMA1`；默认情况下 bootconsole 随后注销。第一版日志刚好停在这个交接点，容易误判为 PL011 console 失败。

最终没有修改 PL011 driver，处理方式是在 bootargs 加 `keep_bootcon`。它让 early console 在正式 console 接管后继续保留，所以后面的 initcall 和 panic 还能打印出来。保留后看到的下一段证据是 `phytium_display_init` 访问显示 PHY 超时并 panic，因此 PL011 只是日志被中断的位置，并非需要处理的设备。

### 5.4 Phytium display panic

失败证据：

```text
calling phytium_display_init+0x0/0x60 @ 1
[drm:phytium_wait_cmd_done] *ERROR* wait cmd reply timeout
Unable to handle kernel paging request at ffffffc012bae000
ESR = 0x96000047
pc : phytium_phy_writel+0x4c/0xcc
lr : pe220x_dp_hw_init_phy+0x48/0x36c
Kernel panic - not syncing: Attempted to kill init
```

DT 中 `dc@32000000` 的 compatible 为 `phytium,dc`。确认过程没有把 panic 里的虚拟地址 `ffffffc012bae000` 直接换算成 `0x32000000`，定位依据是 driver 和 DT 绑定关系：

1. 串口显示 `calling phytium_display_init+0x0/0x60 @ 1`，说明进入 Phytium display driver 的 initcall。`@ 1` 是执行 initcall 的任务，并非显示设备编号。
2. panic 调用栈给出 `phytium_phy_writel` 和 `pe220x_dp_hw_init_phy`，说明失败在 PE220X DisplayPort PHY 初始化和寄存器写入路径。
3. 查看 `drivers/gpu/drm/phytium/phytium_display_drv.c`，`phytium_display_init()` 通过 `platform_driver_register(&phytium_platform_driver)` 注册 platform driver。
4. 查看 `drivers/gpu/drm/phytium/phytium_platform.c`，`display_of_match[]` 中 `.compatible = "phytium,dc"`，因此该 driver 会绑定 DT 中 compatible 为 `phytium,dc` 的节点。
5. 查看启动时打印出的 DT 和原始 DT 内容，匹配到节点 `/soc/dc@32000000`。QEMU 当前使用 `-display none`，没有提供对应显示 PHY。

调用链证明 driver 正在访问不存在的虚拟显示硬件。这个节点也在 `vmLinux.c` 中对内存 DTB 运行期删除。删除 `/soc/dc@32000000` 后：

```text
calling phytium_display_init+0x0/0x60 @ 1
initcall phytium_display_init+0x0/0x60 returned 0 after 900 usecs
```

### 5.5 virtio 网络

网络链路分成三段看：

```text
Windows host tap0
  <-> QEMU -netdev tap + cadence_gem NIC
  <-> ACore virtual platform / netswitch
  <-> Linux guest virtio-mmio device
  <-> eth0
```

QEMU 命令行里的设备是 `-net nic,model=cadence_gem,netdev=t0`，后端是 `tap0`。Linux guest 里看到的是 ACore 给 Linux 暴露的 `virtio_mmio@3b001000`，最终由 `virtio_net` driver 创建 `eth0`。串口里先有 ACore 侧 `virtio_net@gmac0` 和 MAC 地址，再有 Linux 侧 `virtio_mmio`、`virtio_net_driver_init` 和 `eth0`，对应的就是这条路径。

只把 virtio transport 编入 kernel、把 `virtio_net` 留作 module，会让 `eth0` 的创建依赖 rootfs 中的 module 文件、module CRC、`depmod/modprobe` 和 init 脚本顺序。为了验证 QEMU TAP、ACore 网络转接、Linux driver 三者是否连通，本次把 `VIRTIO`、`VIRTIO_MMIO`、`VIRTIO_NET`、`FAILOVER`、`NET_FAILOVER` 都设为 built-in，让网卡在 kernel initcall 阶段创建。

最终日志：

```text
calling virtio_mmio_init+0x0/0x48 @ 1
probe of 3b001000.virtio_mmio returned 1
calling virtio_net_driver_init+0x0/0xd4 @ 1
initcall virtio_net_driver_init+0x0/0xd4 returned 0
```

rootfs 的更新主要是为了放入静态 AArch64 `/codex-init`，并通过 `rdinit=/codex-init init=/codex-init` 让它作为 PID 1 执行。它做的事很少：打印基本信息，等待网卡出现，执行 `ip link set eth0 up`，给 `eth0` 设置 `169.254.127.51/16`，再打印 `ip addr show`。这部分没有改 virtio driver 代码，作用是把用户态网络配置从完整发行版启动流程中拿出来，使 ping 验证只依赖 kernel 已经创建的 `eth0` 和 TAP 二层连接。

所以 virtio 网络相关动作包含多部分。built-in 解决的是 Linux 内核阶段能自动枚举 `virtio_mmio@3b001000` 并创建 `eth0`；TAP 解决的是 Windows 和 QEMU 之间的二层连接；`/codex-init` 解决的是 guest 用户态 IP 配置；最终 ping 验证的是整条链路。

### 5.6 文件证据与修改对应关系

| 查看对象 | 发现的关键信息 | 后续修改或验证 |
| --- | --- | --- |
| `D:\temp\acore-original-repro-20260618-1705\serial-disable-display.log` | `phytium_display_init` 后出现 `phytium_wait_cmd_done` timeout，call trace 指向 `phytium_phy_writel` 和 `pe220x_dp_hw_init_phy` | 不再把 PL011 当作失败点，转向 display driver 和 DT 绑定关系 |
| `...\kernel-source\drivers\gpu\drm\phytium\phytium_display_drv.c` | `phytium_display_init()` 注册 `phytium_platform_driver`，该 initcall 与串口里的 `calling phytium_display_init` 对应 | 确认 panic 属于 Phytium display platform driver 初始化阶段 |
| `...\kernel-source\drivers\gpu\drm\phytium\phytium_platform.c` | `display_of_match[]` 匹配 `.compatible = "phytium,dc"` | 在 DT 中查找 compatible 为 `phytium,dc` 的节点 |
| `...\kernel-source\drivers\gpu\drm\phytium\pe220x_dp.c` | `pe220x_dp_hw_init_phy()` 内大量调用 `phytium_phy_writel()`，并通过 `phytium_wait_cmd_done()` 等待显示硬件回复 | 确认失败来自显示 PHY 寄存器访问，排除 console 和 rootfs |
| 启动时打印出的 DT / 原始 DT | 找到 `/soc/dc@32000000`，compatible 为 `phytium,dc`，状态可被 Linux probe | 在 `vmLinux.c` 中增加运行期删除 `/soc/dc@32000000` |
| `D:\temp\acore-original-repro-20260618-1705\application\gos5\src\vmLinux.c` | 已加载 DTB 地址为 `0xf2000000`；可调用 `fdt_path_offset()` 和 `fdt_del_node()` 修改内存 DTB；`bootiTest()` 使用这个 DTB 启动 Linux | 在 `bootiTest()` 前删除两个 SATA、两个 MMC 和一个 display 节点，并加入 `keep_bootcon rdinit=/codex-init init=/codex-init` |
| `D:\temp\acore-original-repro-20260618-1705\build-kernel-wsl-ext4.log` | 最终构建日志显示 `CONFIG_FAILOVER=y`、`CONFIG_VIRTIO_NET=y`、`CONFIG_NET_FAILOVER=y`、`CONFIG_VIRTIO=y`、`CONFIG_VIRTIO_MMIO=y`，并记录最终 `Image` SHA-256 | 以 WSL ext4 构建日志作为最终 kernel 配置证据；Windows 展开树里的旧 `.config` 不作为最终产物依据 |
| 串口 DT 片段 | Linux guest 看到 `virtio_mmio@3b001000`，compatible 为 `virtio,mmio` | 确认 Linux 侧网卡路径是 `virtio-mmio -> virtio_net -> eth0` |
| QEMU 命令行和 Windows TAP 状态 | QEMU 使用 `-netdev tap,ifname=tap0` 和 `-net nic,model=cadence_gem`，Windows `tap0` 为 `169.254.127.40/16` | 使用 TAP，保持 Windows、MSL loader、guest 在同一二层链路 |
| rootfs 中新增的静态 `/codex-init` | PID 1 执行 `ip link set eth0 up` 和 `ip addr replace 169.254.127.51/16 dev eth0` | rootfs 更新只承担用户态 IP 配置和日志输出，driver 创建仍由 kernel built-in 完成 |

## 6. 方案比较

| 问题 | 备选方案 | 采用方案 | 选择理由 |
| --- | --- | --- | --- |
| PSCI 后停止 | 改 Linux、改 rootfs、改 QEMU | 改 QEMU GIC/CPU | 故障早于 driver/rootfs，A/B 对照有效 |
| SATA/MMC | 模拟设备、改 driver、运行期修正内存 DTB | `vmLinux.c` 在 `bootiTest()` 前删除无实现节点 | Linux 看到的 DT 与虚拟硬件一致 |
| console 停止输出 | 等待、改 chardev、保留 bootconsole | `keep_bootcon` | 判断出 PL011 并非失败点，继续取得后续 display panic |
| display panic | 实现 PHY、改 DRM、运行期修正内存 DTB | 删除 `/soc/dc@32000000` | 当前为 headless QEMU，虚拟硬件没有显示 PHY |
| 网卡为 module | 修复 module、依赖 systemd、built-in | built-in + 静态 init | kernel 阶段创建 `eth0`，rootfs 只负责设置 IP |
| kernel 构建 | NTFS、改源码名称、WSL ext4 | WSL ext4 | 保留 Linux 文件系统语义 |
| QEMU 网络 | user-mode NAT、TAP | TAP | MSL 与 guest 都需要直接二层连接 |

## 7. 修改文件

```text
QEMU:
  ...\qemu-source\hw\arm\vexpress-fte2000.c
  ...\qemu-source\hw\intc\arm_gicv3_common.c

gos5/inter_linux:
  ...\application\gos5\src\vmLinux.c
  ...\application\gos5\src\Image
  ...\application\gos5\src\acore.rootfs.ext2.gz.u-boot
  ...\application\gos5\CMakePresets.json
  ...\application\inter_linux\vars.cmake

辅助流程:
  WSL kernel .config
  ...\network-final-work2\codex_init.c
  C:\Users\qiyan\Documents\Codex\2026-05-19\skill-creator-c-users-qiyan-codex\acore_network_patch\Invoke-AcoreLinuxNetworkPatch.ps1
```

`vmLinux.c` 设置最终 bootargs，并在 `bootiTest()` 前对地址 `0xf2000000` 的内存 DTB 调用 `fdt_del_node()`，删除两个 SATA、两个 MMC 和一个 display 节点。原始 `.dtb` 文件没有直接编辑；改变发生在传给 Linux 之前。CMake preset 和 `vars.cmake` 中的旧绝对路径改为当前 ACoreMCICS 与 temp 路径。

## 8. 构建命令

### 8.1 kernel

```bash
cd /home/acore-final-20260622/.../kernel-source
scripts/config --enable VIRTIO --enable VIRTIO_MMIO --enable VIRTIO_NET --enable FAILOVER --enable NET_FAILOVER
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j8 Image
cp arch/arm64/boot/Image /mnt/d/temp/acore-original-repro-20260618-1705/application/gos5/src/Image
```

日志：`D:\temp\acore-original-repro-20260618-1705\build-kernel-wsl-ext4.log`。

### 8.2 rootfs

```bash
aarch64-linux-gnu-gcc -O2 -static -Wall -Wextra -o codex-init.bin codex_init.c
debugfs -w -R 'rm /codex-init' acore.rootfs.ext2
debugfs -w -R 'write codex-init.bin /codex-init' acore.rootfs.ext2
debugfs -w -R 'set_inode_field /codex-init mode 0100755' acore.rootfs.ext2
debugfs -w -R 'rm /sbin/init' acore.rootfs.ext2
debugfs -w -R 'symlink /sbin/init /codex-init' acore.rootfs.ext2
e2fsck -fn acore.rootfs.ext2
gzip -n -9 -c acore.rootfs.ext2 > acore.rootfs.ext2.new.gz
mkimage -A arm64 -O linux -T ramdisk -C gzip -n 'ACore rootfs' -d acore.rootfs.ext2.new.gz acore.rootfs.ext2.gz.u-boot.new
```

### 8.3 gos5 后 inter_linux

```powershell
$env:PATH = 'D:\software\ACoreMCICS_V0.3.1.1.3_20260227\host\gnu\gcc-13.2.0\aarch64\bin;D:\msys64\mingw64\bin;' + $env:PATH
$build = 'D:\workspace\vscode_intead\codo-vscode-ext\scripts\codo_cmake_build.ps1'
$app = 'D:\temp\acore-original-repro-20260618-1705\application'
Push-Location "$app\gos5"
& $build -Action rebuild -ProjectPath "$app\gos5" -Config armv8a_64 -Jobs 4
Pop-Location
Push-Location "$app\inter_linux"
& $build -Action rebuild -ProjectPath "$app\inter_linux" -Config armv8a_64 -Jobs 4
Pop-Location
```

脚本从当前目录读取 `CMakePresets.json`。ACore GCC 的 `cc1.exe` 还依赖上述 PATH 顺序。

### 8.4 QEMU

压缩包的旧 build 目录含原机器绝对路径，因此使用独立 `build-repro`。Meson 配置后：

```powershell
& 'D:\msys64\mingw64\bin\ninja.exe' -C 'D:\temp\acore-original-repro-20260618-1705\qemu-source\build-repro' qemu-system-aarch64.exe
```

QEMU 启动时也要前置 `D:\msys64\mingw64\bin`，否则本机出现过 `0xC0000409`，只留下 `config file load OK`。

## 9. 启动与加载

QEMU 核心参数：

```powershell
$root = 'D:\temp\acore-original-repro-20260618-1705'
$env:PATH = "D:\msys64\mingw64\bin;$env:PATH"
& "$root\qemu-source\build-repro\qemu-system-aarch64.exe" -accel 'tcg,thread=multi' -smp 4 -atsConfig "$root\qemu-source\conf_fte2000.json" -m 2048 -M 'fte2000-board,secure=on' -net 'nic,model=cadence_gem,netdev=t0' -netdev 'tap,ifname=tap0,script=no,downscript=no,id=t0' -display none -monitor none -serial null -serial stdio
```

MSL 加载：

```powershell
Set-Location 'D:\workspace\vscode_intead\codo-vscode-ext'
node -e "require('./out/test/vscodeTestHarness'); const { TargetUdpLoader } = require('./out/target/TargetUdpLoader'); (async () => { const conn={ip:'169.254.127.50',taPort:1118,timeout:20}; await TargetUdpLoader.loadMcsIntegration('D:/temp/acore-original-repro-20260618-1705/application/inter_linux','armv8a_64',conn,{log:console.log,onProgress:(m,p)=>console.log('[PROGRESS '+p+'%] '+m)}); console.log('[DONE]'); })().catch(e=>{console.error(e);process.exitCode=1;});"
```

## 10. 最终证据

```text
delete dtb node /soc/mmc@28000000: 0
delete dtb node /soc/mmc@28001000: 0
delete dtb node /soc/sata@31a40000: 0
delete dtb node /soc/sata@32014000: 0
delete dtb node /soc/dc@32000000: 0

psciLibInit, version(1, 1)
initcall of_platform_default_populate_init+0x0/0xec returned 0
initcall phytium_display_init+0x0/0x60 returned 0
initcall virtio_net_driver_init+0x0/0xd4 returned 0
VFS: Mounted root (ext2 filesystem) on device 1:0.
Run /sbin/init as init process

[codex-init] start
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP>
    link/ether 2a:98:5a:42:00:00
    inet 169.254.127.51/16 scope global eth0
[codex-init] ready
```

Windows：

```text
Reply from 169.254.127.51: bytes=32 time=11ms TTL=64
Reply from 169.254.127.51: bytes=32 time=1ms TTL=64
Reply from 169.254.127.51: bytes=32 time<1ms TTL=64
Reply from 169.254.127.51: bytes=32 time=1ms TTL=64
Packets: Sent = 4, Received = 4, Lost = 0 (0% loss)
ARP: 169.254.127.51 -> 2A-98-5A-42-00-00
```

## 11. 验收标准

| 层级 | 必须满足 |
| --- | --- |
| QEMU | 进程存在，使用 `tap0`，没有 `-netdev user` |
| MSL | 显示 `169.254.127.50:1118` |
| Loader | 三个文件传输完成，显示直连 UDP 加载成功 |
| PSCI | `psciLibInit` 后继续出现 Linux console |
| Platform | `of_platform_default_populate_init returned 0` |
| Driver | `virtio_mmio` 和 `virtio_net_driver_init` 返回 0 |
| Kernel | 无 Oops/panic，rootfs 挂载成功 |
| PID 1 | 出现 `[codex-init] ready` |
| NIC | `eth0` 为 `UP,LOWER_UP` |
| IP | `169.254.127.51/16` 位于 `eth0` |
| Windows | reply 来自 `169.254.127.51`，4/4 |
| ARP | `.51` 对应 guest MAC，并非全 0 |

## 12. 难点与相关知识

1. **同一日志跨越三个软件层。** MSL、hypervisor 和 Linux 共用串口，需根据阶段选择 loader、QEMU、kernel 或 rootfs。
2. **DT 是硬件契约。** DT 声明存在的设备会触发 probe；QEMU 未实现时会等待或异常。SATA、MMC 和 display 都属于这一类。本次通过运行期修改内存 DTB 让 Linux 只看到当前虚拟机实现过的设备。
3. **最后一行不一定是故障函数。** PL011 交接处停止输出时，后续实际失败点可能已经发生但没有打印出来；未配对 initcall、panic call trace 和 A/B 对照更可靠。
4. **built-in 与 module 影响 early boot。** transport 为 built-in、net driver 为 module 时，接口创建仍依赖 rootfs。最终网络路径是 Windows TAP、QEMU Cadence GEM、ACore netswitch、Linux virtio-mmio、`eth0`，需要分别确认。
5. **NTFS 不适合这份 kernel tree。** 大小写冲突和符号链接语义会改变源码结构，WSL ext4 保留 Linux 文件系统行为。
6. **产物有两级封装。** 更新 kernel/rootfs 或 `vmLinux.c` 后必须重建 gos5，再重建 inter_linux，并比较 SHA-256。
7. **TAP 提供二层连接。** host 与 guest 在同一 /16 内不需要 gateway；ARP 验证二层，ping 验证 IP/ICMP。
8. **Windows DLL 搜索顺序影响工具。** 无编译错误但 `cc1.exe` 退出，以及 QEMU `0xC0000409`，均通过明确设置 PATH 解决。

## 13. 当前保留状态

```text
QEMU PID: 29988
Serial: D:\temp\acore-original-repro-20260618-1705\serial-disable-display.log
Loader: D:\temp\acore-original-repro-20260618-1705\udp-load-disable-display.log
Guest: 169.254.127.51/16
```

最终验证后 QEMU 仍在运行，Windows 可以继续执行 `ping 169.254.127.51`。
