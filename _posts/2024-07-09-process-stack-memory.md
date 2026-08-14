---
title: "进程堆栈内存"
date: 2024-07-09
categories: [linux, kernel]
tags: ["process", "stack", "memory"]
---
```
堆栈的物理内存是什么时候分配的？
堆栈的大小限制是多大？这个限制可以调整吗？
当堆栈发生溢出后应用程序会发生什么？

```

[https://github.com/0voice/linux_kernel_wiki/blob/main/文章/进程管理/Linux内核进程栈内存底层原理到Segmentation fault报错.md](https://github.com/0voice/linux_kernel_wiki/blob/main/%E6%96%87%E7%AB%A0/%E8%BF%9B%E7%A8%8B%E7%AE%A1%E7%90%86/Linux%E5%86%85%E6%A0%B8%E8%BF%9B%E7%A8%8B%E6%A0%88%E5%86%85%E5%AD%98%E5%BA%95%E5%B1%82%E5%8E%9F%E7%90%86%E5%88%B0Segmentation%20fault%E6%8A%A5%E9%94%99.md)

当进程在运行的过程中在栈上开始分配和访问变量的时候，如果物理页还没有分配，会触发缺页中断。在缺页中断中来真正地分配物理内存。

缺页中断的处理是体系相关的。
假设要访问的变量地址 address 处于栈内存 vma 对象的 vm_start 和 vm_end 之间。那么缺页中断处理就会跳转到 good_area 处运行。在这里调用 handle_mm_fault 来**完成真正物理内存的申请** 。

---

进程堆栈大小的限制在每个机器上都是不一样的，可以通过 ulimit 命令来查看，也同样可以使用该命令修改。

---

段错误

---

![Untitled](/assets/images/linux-kernel-notes/process-stack-memory/image-01.webp)
