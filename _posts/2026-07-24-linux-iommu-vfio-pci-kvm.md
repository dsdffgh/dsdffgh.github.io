---
title: "Linux 虚拟化中的 IOMMU/VFIO/PCI 直通与 KVM"
date: 2026-07-24
categories: [virtualization, passthrough]
tags: ["IOMMU", "VFIO", "PCI passthrough", "KVM", "QEMU"]
---

在 Linux 上，硬件直通主要依赖硬件和内核支持，而不专属于 KVM。IOMMU（Intel VT-d 或 AMD-Vi）是主板和 CPU 提供的硬件功能，用于把设备的 DMA 请求限制到特定内存范围内，从而实现安全的设备直通。Linux 内核通常通过 `intel_iommu=on` 或 `amd_iommu=on` 等启动参数启用 IOMMU。[^redhat-pci][^qemu-passthrough]

VFIO（Virtual Function I/O）是 Linux 内核中的设备直通框架，允许用户态程序安全地控制物理设备，并将设备分配给虚拟机。启用 VFIO 时，通常需要加载 `vfio`、`vfio_pci`、`vfio_iommu_type1`、`vfio_virqfd` 等模块；在 QEMU 启动参数中，则可以通过 `-device vfio-pci,host=<bus:slot.func>` 把 PCI 设备传递给 guest。[^qemu-passthrough]

## KVM 环境下的硬件直通

KVM 本身是 Linux 内核中的虚拟化模块，主要提供 CPU 虚拟化支持。KVM 并不是 IOMMU/VFIO 的唯一接口，但在 Linux 桌面和服务器场景中，KVM + QEMU 是最常见的 PCI passthrough 组合。

在 KVM 中使用 PCI 直通，一般需要先在 BIOS/UEFI 中启用 VT-d 或 AMD-Vi，再在内核启动参数中加入 `intel_iommu=on` 或 `amd_iommu=on`。很多配置还会同时加入 `iommu=pt`，让没有被直通的设备尽量使用 pass-through 模式以减少额外开销。[^redhat-pci][^qemu-passthrough]

之后需要让 VFIO 接管目标设备。常见方式是在 GRUB 参数中加入：

```text
vfio-pci.ids=<vendor-id>:<device-id>
```

这样宿主机启动后不会把目标 PCI 设备绑定到默认驱动，而是由 `vfio-pci` 接管。最后由 QEMU 或 libvirt 把设备加入虚拟机。使用 libvirt/virt-manager 时，配置通常表现为 XML 中的 `<hostdev>` 元素；底层仍会映射到 VFIO 和 QEMU 的设备直通机制。[^qemu-passthrough]

KVM 环境下还需要区分托管模式和非托管模式。托管模式下，libvirt 会在虚拟机启动时自动解绑设备，并在虚拟机关机后重新绑定给宿主；非托管模式则要求管理员手动处理设备解绑和恢复。[^libvirt-pci]

## 其他虚拟化技术的硬件直通

- **Xen 虚拟化**：Xen 是 Type-1 hypervisor，也支持 PCI passthrough。Xen 同样依赖 IOMMU，但启动参数和设备分配方式与 KVM 不同，例如 Xen 侧通常需要启用 `iommu=on`。[^redhat-pci][^xen-iommu]
- **纯 QEMU（无 KVM）**：QEMU 即使不启用 KVM，也可以在理论上使用 VFIO 传递设备；但 CPU 执行会退化为软件模拟，性能通常远低于 KVM 加速模式。因此这种组合更多用于测试或低性能需求场景。
- **LXC/LXD 容器**：容器共享宿主机内核，通常不是通过 IOMMU 独占 PCI 设备，而是通过挂载 `/dev/dri/*` 等设备节点和 cgroup 权限让容器访问宿主设备。这更接近设备共享，不是虚拟机意义上的 PCI passthrough。[^lxc-gpu]
- **Virt-Manager/Libvirt**：Virt-Manager 是图形管理工具，libvirt 是虚拟化管理层。它们本身不是硬件虚拟化机制，而是管理 KVM/QEMU、Xen、LXC 等后端。对于 KVM 直通，libvirt 会负责设备解绑、绑定和 QEMU 参数生成。[^libvirt-pci]

## 关键组件与配置

- **内核模块**：`kvm`、`kvm_intel` 或 `kvm_amd` 提供 CPU 虚拟化；`vfio`、`vfio_pci`、`vfio_iommu_type1`、`vfio_virqfd` 等提供设备直通和 IOMMU 隔离。
- **内核启动参数**：Intel 平台常用 `intel_iommu=on`，AMD 平台常用 `amd_iommu=on`，并可按情况加入 `iommu=pt`。在设备分组或复位存在问题时，可能还会涉及 `pci=realloc`、`pci=acs_override=downstream` 等参数。
- **用户空间工具**：KVM 场景常用 `qemu-system-x86_64` 或 libvirt/virt-manager。命令行方式可以直接使用 `-device vfio-pci,host=<pci-address>`；libvirt 方式则通过 `virsh nodedev-detach`、`<hostdev>` 等配置表达。
- **典型流程**：启用 IOMMU，配置 VFIO 绑定，重建 initramfs 并重启，通过 `lspci -k` 验证设备已由 `vfio-pci` 接管，然后由 QEMU 或 libvirt 启动虚拟机并传入该 PCI 设备。

## 小结

硬件直通的核心是 IOMMU 和 VFIO。KVM 不是直通本身的必要条件，但在 Linux 上通常与 QEMU 配合使用，以同时获得 CPU 虚拟化加速和设备直通能力。Xen 也支持 PCI passthrough；容器则通常采用设备节点共享方式，隔离模型和虚拟机直通不同。

## 参考资料

[^redhat-pci]: Red Hat Documentation, [Chapter 15. PCI passthrough](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/5/html/virtualization/chap-virtualization-pci_passthrough).

[^qemu-passthrough]: CSDN, [linux QEMU 的 PCI 设备直通（pass through）](https://blog.csdn.net/shenjunpeng/article/details/154060519).

[^libvirt-pci]: CSDN, [libvirt 笔记 PCI 设备直通](https://blog.csdn.net/weixin_42834523/article/details/120544068).

[^xen-iommu]: XCP-ng Blog, [IOMMU paravirtualization for Xen](https://xcp-ng.org/blog/2024/04/18/iommu-paravirtualization-for-xen/).

[^lxc-gpu]: hellowood, [在 PVE 的 LXC 容器中直通核心显卡](https://blog.hellowood.dev/posts/%E5%9C%A8pve%E7%9A%84lxc%E5%AE%B9%E5%99%A8%E4%B8%AD%E7%9B%B4%E9%80%9A%E6%A0%B8%E5%BF%83%E6%98%BE%E5%8D%A1/).
