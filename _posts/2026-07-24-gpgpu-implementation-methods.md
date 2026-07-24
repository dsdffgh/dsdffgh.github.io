---
title: "GPGPU 实现方式"
date: 2026-07-24
categories: [virtualization, passthrough]
tags: ["GPGPU", "VFIO", "mdev", "KVM", "vGPU"]
---

## 一、VFIO 、mdev、KVM是什么

### VFIO全称

**VFIO (Virtual Function I/O Framework)**
 是 Linux 内核提供的一个 **安全的设备直通框架**。

VFIO 是为了让 **用户空间程序（如 QEMU）能安全地直接访问物理设备** 而设计的。

------

#### 主要作用

| 功能               | 说明                                              |
| ------------------ | ------------------------------------------------- |
| ① 提供安全访问接口 | 通过 `/dev/vfio/<group>`，QEMU 可以直接与设备通信 |
| ② 统一设备直通机制 | 不论是 GPU、网卡、FPGA 都可以通过 VFIO 接入       |
| ③ 管理 IOMMU 隔离  | 保护宿主机安全，防止设备 DMA 访问宿主内存         |
| ④ 与 mdev 配合     | 管理“虚拟化的物理设备”（如 vGPU）                 |

------

####  VFIO 内核模块

```bash
vfio.ko
vfio-pci.ko
vfio_iommu_type1.ko
```

当你执行：

```bash
modprobe vfio-pci
```

它会替代原厂驱动（如 `nvidia.ko`、`ixgbe.ko`），
 接管 PCI 设备控制权，然后提供给用户态（QEMU）使用。

------

### KVM 驱动（Kernel-based Virtual Machine）

#### 定义

`KVM` 是 Linux 内核自带的 **硬件虚拟化模块**，它把 Linux 变成一个 **Type-1 Hypervisor（宿主机虚拟化内核）**。
 内核模块文件为：

```bash
kvm.ko
kvm-intel.ko 或 kvm-amd.ko
```

------

#### 主要功能

| 功能            | 说明                                                         |
| --------------- | ------------------------------------------------------------ |
| 虚拟CPU（vCPU） | 由 KVM 模块管理，使用硬件虚拟化指令（Intel VT-x / AMD-V）执行客体代码。 |
| 内存虚拟化      | 管理 Guest 的物理内存映射（EPT/NPT）。                       |
| 中断注入        | 模拟外设中断、系统调用等事件。                               |
| 与 QEMU 协作    | QEMU 负责设备仿真，KVM 提供虚拟机执行加速。                  |

------

####  举例理解：

> 你启动虚拟机时：
>
> ```bash
> qemu-system-x86_64 -enable-kvm ...
> ```
>
> 这个 `-enable-kvm` 就是调用内核中的 `KVM` 模块，让虚拟机不再是软件模拟（慢），而是通过硬件虚拟化（快）。

------

### mdev 驱动（Mediated Device Framework）

#### 定义

`mdev` 全称 **Mediated Device Framework**，是 Linux 内核提供的一种机制，允许将一个 **物理设备（如 GPU、FPGA、NIC）虚拟化成多个“虚拟设备”** 分配给不同虚拟机使用。

------

#### 驱动位置

路径一般如下：

```bash
/sys/class/mdev_bus/
```

或者驱动模块名：

```bash
vfio_mdev.ko
vfio_mdev_device.ko
```

------

#### 工作原理

| 层次       | 组件                                                    | 功能                                                |
| ---------- | ------------------------------------------------------- | --------------------------------------------------- |
| 应用层     | QEMU / libvirt                                          | 请求创建 vGPU、vNIC 等虚拟设备                      |
| 内核框架   | mdev core                                               | 提供统一接口（create/remove）来管理 mediated device |
| 设备驱动   | 供应商实现（如 NVIDIA vGPU、Intel GVT-g、Ilumina vDPU） | 真正控制物理硬件的资源切分                          |
| 用户态访问 | VFIO（通过 `/dev/vfio/<id>`）                           | 提供安全的设备访问接口给 QEMU                       |

------

#### 举例理解：

假设你有一块支持 SR-IOV 或 vGPU 的显卡（比如 NVIDIA A100 或 Iluvatar C4）：

```bash
/sys/class/mdev_bus/0000:65:00.0/mdev_supported_types/
```

每个子目录代表一个可创建的虚拟功能（mdev type），
 你可以创建多个 vGPU 给不同虚拟机使用，例如：

```bash
echo <UUID> > /sys/class/mdev_bus/0000:65:00.0/mdev_supported_types/nvidia-222/mdev_create
```

------

## 二、三者在虚拟化中的分层关系

我们先看层级结构：

```
[ 应用层 ]          QEMU / libvirt
     │
     ▼
[ 内核用户接口层 ]   VFIO（负责访问物理设备）
     │
     ▼
[ 设备虚拟化层 ]     mdev（mediated device framework）
     │
     ▼
[ 硬件虚拟化层 ]     KVM（CPU/内存虚拟化）
     │
     ▼
[ 物理硬件层 ]       GPU / NIC / FPGA 等设备
```

------

## 三、三者之间的职责关系

| 模块     | 层级           | 主要功能                 | 是否涉及直通     | 举例                                                    |
| -------- | -------------- | ------------------------ | ---------------- | ------------------------------------------------------- |
| **KVM**  | CPU/内存虚拟化 | 加速虚拟机执行           | ❌ 否             | `-enable-kvm`                                           |
| **VFIO** | 设备直通接口   | 把物理设备暴露给虚拟机   | ✅ 是             | `-device vfio-pci,host=0000:65:00.0`                    |
| **mdev** | 设备虚拟化     | 把一个设备虚拟出多个实例 | ✅ 是（共享直通） | `-device vfio-pci,sysfsdev=/sys/bus/mdev/devices/<UUID> |

##  四、直通（Passthrough）分类与关系

直通是虚拟化中访问真实硬件的方式，
 根据 VFIO/mdev 的使用方式不同，可分为两类：

| 类型                                   | 技术                   | 含义                                         | 使用场景                            |
| -------------------------------------- | ---------------------- | -------------------------------------------- | ----------------------------------- |
| **① 设备直通（Direct Passthrough）**   | VFIO + PCI passthrough | 整个物理设备独占给一台虚拟机                 | GPU、NIC 全直通（如 GPU CUDA 虚机） |
| **② 介导直通（Mediated Passthrough）** | VFIO + mdev            | 物理设备被虚拟化成多个虚拟功能（vGPU、vNIC） | 多虚机共享 GPU                      |

------

## 举个具体例子（结合场景）

### 现在的硬件：

> Iluvatar C4 GPU，支持 vGPU（通过 `mdev`）
>  使用 QEMU + KVM 启动虚拟机，并绑定 mdev UUID。

流程如下：

```
          [ QEMU 虚拟机 ]
                 │
                 │ 使用 VFIO 调用 /dev/vfio/<group>
                 ▼
        ┌──────────────────────────┐
        │          VFIO            │
        │ 安全映射 + IOMMU 管理     │
        └──────────────────────────┘
                 │
                 ▼
        ┌──────────────────────────┐
        │           mdev           │
        │ 虚拟化 GPU 并创建 vGPU   │
        └──────────────────────────┘
                 │
                 ▼
        ┌──────────────────────────┐
        │     Iluvatar GPU 驱动     │
        │ (供应商实现的 kmd 驱动) │
        └──────────────────────────┘
```

QEMU 参数如下：

```bash
-device vfio-pci,sysfsdev=/sys/bus/mdev/devices/<UUID>
```
