---
title: "Linux 自旋锁"
date: 2024-06-05
categories: [linux, kernel]
tags: ["spinlock", "locking"]
---
不可递归。这不同于其他操作系统

用于在短时间内轻量加锁。所以持有时间应该尽可能短。

<asm/spinlock.h>与体系相关

<linux/spinlock.h>实际用到的接口定义

### 在中断处理程序中使用自旋锁（spinlock）需要特别小心，以避免常见的并发问题和系统性能问题。以下是一些关键的注意事项：

#### 1. **禁止中断（Disabling Interrupts）**

当在中断上下文中使用自旋锁时，通常需要禁止中断，以防止死锁情况的发生。自旋锁在获取锁时会一直循环检查锁的状态，如果在持有锁的情况下发生中断，且中断处理程序也试图获取同一个锁，这将导致死锁。因此，在获取自旋锁时，可以禁止中断：

```c
unsigned long flags;
spin_lock_irqsave(&lock, flags);
// 临界区代码
spin_unlock_irqrestore(&lock, flags);

```

如果你能确定中断在加锁前是激活的，那就不需要解锁后恢复中断以前的状态了。你可以无条件地在解锁时激活中断。这时使用

```c
spin_lock_irq(&lock);
//code
spin_unlock_irq(&lock);
```

#### 2. **避免睡眠（Avoid Sleeping）**

中断处理程序和自旋锁都不允许进行任何会导致睡眠的操作。自旋锁本质上是一种忙等待（busy-wait）机制，如果在持有自旋锁的情况下发生睡眠，会导致系统无法响应其他中断或事件，严重影响系统性能。

#### 3. **临界区代码尽量简短（Keep Critical Section Short）**

在中断上下文中，保持临界区代码简短且高效非常重要。这有助于减少锁的持有时间，降低自旋锁竞争的可能性，并提高系统响应性。避免在临界区中执行复杂或耗时的操作。

#### 4. **防止死锁（Prevent Deadlocks）**

确保自旋锁的使用顺序一致，避免死锁。即，如果有多个锁需要在中断处理程序中使用，确保按照相同的顺序获取和释放这些锁。

#### 5. **正确初始化和销毁自旋锁（Proper Initialization and Destruction）**

确保在使用自旋锁之前已经正确初始化，并在不再需要时销毁自旋锁。例如：

```c
spinlock_t my_lock;
spin_lock_init(&my_lock);

```

#### 6. **小心使用嵌套自旋锁（Careful with Nested Spinlocks）**

如果需要在中断处理程序中嵌套使用自旋锁，确保使用适当的中断安全版本，并注意避免死锁。嵌套自旋锁需要特别小心处理，以确保不会导致意外的系统行为。

#### 示例代码

以下是一个在中断处理程序中安全使用自旋锁的示例代码：

```c
#include <linux/spinlock.h>
#include <linux/interrupt.h>

spinlock_t my_lock;

irqreturn_t my_interrupt_handler(int irq, void *dev_id) {
    unsigned long flags;

    // 禁止中断并获取自旋锁
    spin_lock_irqsave(&my_lock, flags);
//　spin_lock_irqsave------>__raw_spin_lock_irqsave
    // 临界区代码，处理中断
    // ...

    // 释放自旋锁并恢复中断
    spin_unlock_irqrestore(&my_lock, flags);

    return IRQ_HANDLED;
}

static int __init my_module_init(void) {
    spin_lock_init(&my_lock);
    // 注册中断处理程序
    request_irq(my_irq, my_interrupt_handler, IRQF_SHARED, "my_interrupt", my_dev_id);
    return 0;
}

static void __exit my_module_exit(void) {
    // 释放中断
    free_irq(my_irq, my_dev_id);
}

module_init(my_module_init);
module_exit(my_module_exit);

```

在这个示例中，`spin_lock_irqsave` 和 `spin_unlock_irqrestore` 用于在中断处理程序中安全地使用自旋锁。这些函数会在获取锁时保存当前的中断状态，并在释放锁时恢复中断状态，以确保系统的正常运行和中断处理的安全性。

---

spin_lock_irqsave →__raw_spin_lock_irqsave

```c
//　spin_lock_irqsave------>__raw_spin_lock_irqsave
static inline unsigned long __raw_spin_lock_irqsave(raw_spinlock_t *lock)
{
    unsigned long flags;

    local_irq_save(flags);
    preempt_disable();
    spin_acquire(&lock->dep_map, 0, 0, _RET_IP_);
    /*
     * On lockdep we dont want the hand-coded irq-enable of
     * do_raw_spin_lock_flags() code, because lockdep assumes
     * that interrupts are not re-enabled during lock-acquire:
     */
#ifdef CONFIG_LOCKDEP
    LOCK_CONTENDED(lock, do_raw_spin_trylock, do_raw_spin_lock);
#else
    do_raw_spin_lock_flags(lock, &flags);
#endif
    return flags;
}
```

使用spin_lock_irqsave在于你不期望在离开临界区后，改变中断的开启/关闭状态！进入临界区是关闭的，离开后它同样应该是关闭的！

如果自旋锁在中断处理函数中被用到，那么在获取该锁之前需要关闭本地中断，spin_lock_irqsave 只是下列动作的一个便利接口：
1 保存本地中断状态(这里的本地即当前的cpu的所有中断)
2 关闭本地中断
3 获取自旋锁
解锁时通过 spin_unlock_irqrestore完成释放锁、恢复本地中断到之前的状态等工作

---

### arm 下的实现

```cpp
static inline void arch_spin_lock(arch_spinlock_t *lock)
{
	unsigned long tmp;
	u32 newval;
	arch_spinlock_t lockval;

	prefetchw(&lock->slock);
	__asm__ __volatile__(
"1:	ldrex	%0, [%3]\n"
"	  add	%1, %0, %4\n"
"	  strex	%2, %1, [%3]\n"
"	  teq	%2, #0\n"
"	  bne	1b"
		: "=&r" (lockval), "=&r" (newval), "=&r" (tmp)
		: "r" (&lock->slock), "I" (1 << TICKET_SHIFT)
		: "cc");

	while (lockval.tickets.next != lockval.tickets.owner) {
		wfe();
		lockval.tickets.owner = ACCESS_ONCE(lock->tickets.owner);
	}

	smp_mb();
}
```

这段代码是 ARM 架构下的自旋锁（spinlock）实现的一部分，使用 ARM 的特定汇编指令来实现锁的功能。下面是对这个函数的逐行解释：

```c
static inline void arch_spin_lock(arch_spinlock_t *lock)

```

这是 `arch_spin_lock` 函数的定义，它是一个内联函数。这个函数的目的是获取一个自旋锁。`arch_spinlock_t` 类型的指针 `lock` 是函数的参数，它指向要获取的锁。

```c
unsigned long tmp;
u32 newval;
arch_spinlock_t lockval;

```

声明了三个变量：`tmp` 用于存储临时数据，`newval` 用于存储锁的新值，`lockval` 用于存储锁的当前值。

```c
prefetchw(&lock->slock);

```

`prefetchw` 是一个提示指令，建议 CPU 预取下一次将写入的 lock 的地址，以加快访问速度。

```c
"1:	ldrex	%0, [%3]\\n"

```

`ldrex` 是 ARM 的一条加载指令，表示从地址 `[%3]` （`lock->slock`）载入一个排他性锁定值到 `%0` （`lockval` ）。

```c
"	add	%1, %0, %4\\n"

```

`add` 是一个加法指令，把 `%0` 的值和 `%4` （`1 << TICKET_SHIFT`）相加，结果存储在 `%1` （`newval`）。

```c
"	strex	%2, %1, [%3]\\n"

```

`strex` 尝试将 `%1` (新计算的 `lock` 值) 写入锁的地址 (`[%3]`)。如果写入成功，`%2`（`tmp`）被设置为 0。如果写入未成功（说明其他核先行执行了写入操作），`%2`会被设置成一个非零值。

```c
"	teq	%2, #0\\n"
"	bne	1b"

```

`teq` 指令用来测试 `%2`（`tmp`）是否为 0，即 `strex` 是否成功。`bne` 是一个条件分支指令，如果 `%2` 不为 0，即 `strex` 失败，会跳转回标签 `1` 重新尝试。

```c
: "=&r" (lockval), "=&r" (newval), "=&r" (tmp)

```

这里是汇编代码的输出部分。它将寄存器与上面定义的 C 变量关联起来。

```c
: "r" (&lock->slock), "I" (1 << TICKET_SHIFT)

```

这一部分是汇编代码的输入部分，它将 C 变量传递给汇编代码中使用的寄存器。

```c
: "cc");

```

这里指定了汇编代码使用到的标志寄存器。

```c
while (lockval.tickets.next != lockval.tickets.owner) {
	wfe();
	lockval.tickets.owner = ACCESS_ONCE(lock->tickets.owner);
}

```

这个 `while` 循环等待锁变得可用。`wfe()` 指令将 CPU 置于等待事件状态，这意味着直到发生事件，否则它不会继续执行。此代码等待锁的所有者释放锁。

因为多核或多线程的环境，如果 `lockval.tickets.owner` 不是当前的锁持有者，那可能是因为这个值是在之前的读取操作中保存的一个旧值，或者是因为其他正在运行的线程更改了锁的所有者。这样做可以防止编译器优化掉这些读取，确保每次循环迭代都能获得实时的锁所有者状态。

在 Linux 内核中，`ACCESS_ONCE` 宏通常用于对访问的变量进行一次性访问。这主要是为了防止编译器对特定操作做出优化，确保指令在访问易变的变量时不会被重新排序或合并，保证了内存访问的顺序性和一致性。这里读取锁的持有者。它确保了在一个易变的上下文中，读取操作只进行一次，并且读取的是这个变量的当前值。

这种用法重要的是在多线程或多核处理器上，确保读取操作不会由于编译器优化而分割成多个步骤或与其他指令重排序。这样可以安全地读取锁的当前所有者，并且任何与锁相关的变更都立即对查询者可见。这在实现锁的机制以及检测锁状态时是非常重要的。

```c
smp_mb();

```

`smp_mb()` 是内存屏障函数，确保前面的操作在多处理器系统中已完成，没有其他操作可以绕过这个屏障。

总的来说，这段代码使用 ARM 的特定指令实现了一种简单、有效的锁定机制，允许线程在不被其他线程干扰的情况下安全地进入关键区域。

---

**在多线程或多核处理器中，为什么需要使用 `ACCESS_ONCE` 宏来读取锁的当前所有者？**

在多线程或多核处理器中，由于并发执行和优化，操作系统或编译器可能会重新排序指令，这可能会导致在访问共享数据时出现不一致或者意外的行为。这种重排序通常对提高程序性能有好处，因为它允许更有效地利用 CPU 管道和缓存，但在同步原语（如锁）中，它可能打破必要的顺序性，导致竞争条件。

`ACCESS_ONCE` 宏在读取或者写入到一个变量时，确保只生成一条机器级的内存访问指令。这意味着整个操作不会被编译器优化成多个指令，也不会和其他内存操作指令重排序，确保了读取或写入操作的原子性。在访问锁的当前所有者时，我们需要确保获取的值是准确和最新的，因此使用 `ACCESS_ONCE` 来避免潜在的编译器优化，保证在复杂的并发场景下正常工作。

简言之，`ACCESS_ONCE` 宏用来确保程序正确地读取了共享数据的最新值，避免了因编译器优化导致的指令重排序问题，这在处理同步问题时是至关重要的。

### seqlock

加锁的逻辑
(1)假设临界区内没有任何的thread，这时候任何read thread或者write thread可以进入;
(2)在临界区没有write thread的情况下read thread可以随意进入，也就是说reader不会阻挡reader;
(3)假设临界区内有一个write thread，这时候任何的read thread或者write thread都不可以进入;

(4)在临界区只有有read thread的情况下write thread可以立刻执行，不会等待;

可见，seqlock给writer赋予了更高的优先级。

### rw spinlock

加锁的逻辑:
(1)假设临界区内没有任何的thread，这时候任何read thread或者write thread可以进入:
(2)假设临界区内有一个read thread，这时候新来的read thread可以任意进入，但是write thread不可以进入;
(3)假设临界区内有一个write thread，这时候任何的read thread或者write thread都不可以进入;
(4)假设临界区内有一个或者多个read thread，write thread当然不可以进入临界区，但是该write thread也无法阻止后续read thread的进入,他要一直等到临界区一个read thread也没有的时候，才可以进入。

可见，rw spinlock给reader赋予了更高的优先级。
