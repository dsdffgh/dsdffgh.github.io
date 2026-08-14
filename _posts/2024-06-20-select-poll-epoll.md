---
title: "select / poll / epoll"
date: 2024-06-20
categories: [linux, kernel]
tags: ["epoll", "IO multiplexing"]
---
[select/poll/epoll对比分析 - Gityuan博客 | 袁辉辉的技术博客](https://gityuan.com/2015/12/06/linux_epoll/)

[源码解读poll/select内核机制 - Gityuan博客 | 袁辉辉的技术博客](https://gityuan.com/2019/01/05/linux-poll-select/)

[Linux内核poll/select机制简析 - huey_x - 博客园](https://www.cnblogs.com/hueyxu/p/14358545.html)

1. API结构 

`select`：

- 使用固定大小的fd_set，文件描述符数量有上限（典型为1024）。
- 每次调用都需要重新初始化文件描述符集。

`poll`:

- 使用一个pollfd数组，没有文件描述符数量的上限（仅受系统资源限制）
- 同样需要每次调用重新遍历文件描述符数组。

`epoll`：（红黑树）

- 通过内核维护的文件描述符列表，不需要每次调用都传递整个文件描述符集。
- 使用epoll_ctl添加/删除感兴趣的文件描述符。
1.  性能
- `select`和 `poll`:

每次调用都会遍历整个文件描述符集或数组，监视的文件描述符越多，开销越大，效率降低。 

- `epoll`:

使用事件驱动模型，只在有事件时返回，性能与文件描述符的数量无关，适合大量并发连接的场景。

3. 文件描述符数量限制 

- select：受文件描述符集的大小限制（通常为1024）
- poll和epoll：没有硬性限制，最大数量只受系统资源限制。
1. 触发方式：
- `select` 和 `poll` ：只支持水平触发（Level Triggered），时间不会消失，必须处理完毕
- `epoll` ：支持边缘触发（Edge Triggered）和水平触发，边缘触发更高效但使用复杂
1. 内存效率
- `select` : 每次调用会拷贝fd_set， 浪费内存和cpu
- `poll` : 使用pollfd 数组，每次需要重新构建
- `epoll` : 内核维护文件描述符，用户态和内核态的数据交换更少，内存效率更高
1. 适用场景
- `select` : 适合少量文件描述符和较老的代码，简单，性能较差
- `poll` : 适合大规模的文件描述符，但在大量连接时性能不佳
- `epoll` : 适合大量并发连接，如高性能服务器或网络程序
