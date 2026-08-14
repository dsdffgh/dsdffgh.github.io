---
title: "下半部与软中断"
date: 2024-06-18
categories: [linux, kernel]
tags: ["softirq", "bottom half", "interrupt"]
---
### 软件中断注册和触发

```c
#ifndef __ARCH_IRQ_STAT
irq_cpustat_t irq_stat[NR_CPUS] ____cacheline_aligned;
EXPORT_SYMBOL(irq_stat);
#endif

static struct softirq_action softirq_vec[NR_SOFTIRQS] __cacheline_aligned_in_smp;

DEFINE_PER_CPU(struct task_struct *, ksoftirqd);

const char * const softirq_to_name[NR_SOFTIRQS] = {
	"HI", "TIMER", "NET_TX", "NET_RX", "BLOCK", "IRQ_POLL",
	"TASKLET", "SCHED", "HRTIMER", "RCU"
};
```

```c
//软中断的处理函数
struct softirq_action
{
	void	(*action)(struct softirq_action *);
};
```

#### 注册软中断处理函数

```c
//kernel/softirq.c
void open_softirq(int nr, void (*action)(struct softirq_action *))
{
	softirq_vec[nr].action = action;
}
```

例如

```c
void __init softirq_init(void)
{
	int cpu;

	for_each_possible_cpu(cpu) {
		per_cpu(tasklet_vec, cpu).tail =
			&per_cpu(tasklet_vec, cpu).head;
		per_cpu(tasklet_hi_vec, cpu).tail =
			&per_cpu(tasklet_hi_vec, cpu).head;
	}

	open_softirq(TASKLET_SOFTIRQ, tasklet_action);
	open_softirq(HI_SOFTIRQ, tasklet_hi_action);
}
```

这里注册了两个软中断处理函数

内核软中断子系统初始化了两个 per-cpu 变量：

- tasklet_vec：**普通 tasklet**，回调 tasklet_action()
- tasklet_hi_vec：**高优先级 tasklet**，回调 tasklet_hi_action()

#### 软中断的触发

```c
inline void raise_softirq_irqoff(unsigned int nr)
{
	__raise_softirq_irqoff(nr);

	/*
	 * If we're in an interrupt or softirq, we're done
	 * (this also catches softirq-disabled code). We will
	 * actually run the softirq once we return from
	 * the irq or softirq.
	 *
	 * Otherwise we wake up ksoftirqd to make sure we
	 * schedule the softirq soon.
	 */
	if (!in_interrupt())
		wakeup_softirqd();
}

void raise_softirq(unsigned int nr)
{
	unsigned long flags;

	local_irq_save(flags);
	raise_softirq_irqoff(nr);
	local_irq_restore(flags);
}

void __raise_softirq_irqoff(unsigned int nr)
{
	trace_softirq_raise(nr);
	or_softirq_pending(1UL << nr);
}
```

调用栈为raise_softirq （首先禁止本地中断）→ raise_softirq_irqoff → __raise_softirq_irqoff →  or_softirq_pending(x)
通过 **`raise_softirq()`** 将一个软中断  **标记为 deferred interrupt**，这会**唤醒该软中断（但还没有开始处理）**；

```c
#ifndef __ARCH_SET_SOFTIRQ_PENDING
#define set_softirq_pending(x) (local_softirq_pending() = (x))
#define or_softirq_pending(x)  (local_softirq_pending() |= (x))
#endif

...

/*
 * Simple wrappers reducing source bloat.  Define all irq_stat fields
 * here, even ones that are arch dependent.  That way we get common
 * definitions instead of differing sets for each arch.
 */

#ifndef __ARCH_IRQ_STAT
extern irq_cpustat_t irq_stat[];		/* defined in asm/hardirq.h */
#define __IRQ_STAT(cpu, member)	(irq_stat[cpu].member) // irq_stat[cpu].member 就是 __softirq_pending
#endif

  /* arch independent irq_stat fields */
#define local_softirq_pending() \
	__IRQ_STAT(smp_processor_id(), __softirq_pending)
```

__softirq_pending可以看作软中断的中断寄存器，通过这个变量知道是否有软中断被触发

其中详细看看这几个数据类型

```c

typedef struct {
	unsigned int __softirq_pending;
#ifdef CONFIG_SMP
	unsigned int ipi_irqs[NR_IPI];
#endif
} ____cacheline_aligned irq_cpustat_t;

```

**软中断的特征：谁触发谁执行。**

__raise_softirq_irqoff → or_softirq_pending

传进去了cpu的id号，所以把软中断标记设置到了当前cpu的软件中断寄存器里，如果当前cpu和触发的cpu是同一个，才会执行软件中断处理函数。因为__softirq_pending保存在cpu中，每个cpu只能看到自己的值。所以有上述结果：**谁触发谁执行。**

```c
#define or_softirq_pending(x)  (local_softirq_pending() |= (x))
//参看前面
```

### 软件中断处理函数的执行时机

其中硬件中断优先级最高，软中断处理优先级也比其它中断高

#### 1. ksofyirqd线程

静态机制，在内核编译时确定

```c
static struct smp_hotplug_thread softirq_threads = {
	.store			= &ksoftirqd,
	.thread_should_run	= ksoftirqd_should_run,
	.thread_fn		= run_ksoftirqd,
	.thread_comm		= "ksoftirqd/%u",
};

static __init int spawn_ksoftirqd(void)
{
	cpuhp_setup_state_nocalls(CPUHP_SOFTIRQ_DEAD, "softirq:dead", NULL,
				  takeover_tasklets);
	BUG_ON(smpboot_register_percpu_thread(&softirq_threads));

	return 0;
}
```

spawn_ksoftirqd创建线程。这个线程的个数和cpu数量相等

执行函数为，首先禁止本地中断（硬件中断）

```c
softirq.c	kernel	19710	2020/7/1	395
static void run_ksoftirqd(unsigned int cpu)
{
	**local_irq_disable();**
	if (local_softirq_pending()) {
		/*
		 * We can safely run softirq on inline stack, as we are not deep
		 * in the task stack here.
		 */
		**__do_softirq();**
		local_irq_enable();
		cond_resched_rcu_qs();
		return;
	}
	**local_irq_enable();**
}
```

#### 2. 硬件中断返回irq_exit()

```c
softirq.c	kernel	19710	2020/7/1	395
/*
 * Exit an interrupt context. Process softirqs if needed and possible:
 */
void irq_exit(void)
{
#ifndef __ARCH_IRQ_EXIT_IRQS_DISABLED
	local_irq_disable();
#else
	WARN_ON_ONCE(!irqs_disabled());
#endif

	account_irq_exit_time(current);
	preempt_count_sub(HARDIRQ_OFFSET);
	if (!in_interrupt() && local_softirq_pending())
		**invoke_softirq();**

	tick_irq_exit();
	rcu_irq_exit();
	trace_hardirq_exit(); /* must be last! */
}
```

```c
static inline void invoke_softirq(void)
{
	if (ksoftirqd_running(local_softirq_pending()))
		return;

	if (!force_irqthreads) {
#ifdef CONFIG_HAVE_IRQ_EXIT_ON_IRQ_STACK
		/*
		 * We can safely execute softirq on the current stack if
		 * it is the irq stack, because it should be near empty
		 * at this stage.
		 */
		**__do_softirq();**
#else
		/*
		 * Otherwise, irq_exit() is called on the task stack that can
		 * be potentially deep already. So call softirq in its own stack
		 * to prevent from any overrun.
		 */
		do_softirq_own_stack();
#endif
	} else {
		wakeup_softirqd();
	}
}
```

#### 3. 直接调用，例如在网络子系统里等

```c
dev.c	net\core	216894	2020/7/1	4724
netif_rx_ni → do_softirq() → do_softirq_own_stack() → __do_softirq()
```

### 软中断的执行过程

```c
asmlinkage __visible void __softirq_entry __do_softirq(void)
{
	unsigned long end = jiffies + MAX_SOFTIRQ_TIME;
	unsigned long old_flags = current->flags;
	int max_restart = MAX_SOFTIRQ_RESTART;
	struct softirq_action *h;
	bool in_hardirq;
	__u32 pending;
	int softirq_bit;

	/*
	 * Mask out PF_MEMALLOC s current task context is borrowed for the
	 * softirq. A softirq handled such as network RX might set PF_MEMALLOC
	 * again if the socket is related to swap
	 */
	current->flags &= ~PF_MEMALLOC;

// 获取当前cpu上的未执行的软中断
	pending = local_softirq_pending();
	account_irq_enter_time(current);

// premmpt——count bit8 set 1， 代表进入软中断上下文环境 
	**__local_bh_disable_ip(_RET_IP_, SOFTIRQ_OFFSET);**
	in_hardirq = lockdep_softirq_start();

restart:
	/* Reset the pending bitmask before enabling irqs */
	set_softirq_pending(0);
// 软中断处理的时候硬件中断必须打开
	**local_irq_enable();**
// 得到了这个数组的基址
	h = softirq_vec;

	while ((softirq_bit = ffs(pending))) {
		unsigned int vec_nr;
		int prev_count;

		h += softirq_bit - 1;

		vec_nr = h - softirq_vec;
		prev_count = preempt_count();

		kstat_incr_softirqs_this_cpu(vec_nr);

		trace_softirq_entry(vec_nr);
		h->action(h);
		trace_softirq_exit(vec_nr);
		if (unlikely(prev_count != preempt_count())) {
			pr_err("huh, entered softirq %u %s %p with preempt_count %08x, exited with %08x?\n",
			       vec_nr, softirq_to_name[vec_nr], h->action,
			       prev_count, preempt_count());
			preempt_count_set(prev_count);
		}
		h++;
		pending >>= softirq_bit;
	}

	rcu_bh_qs();
	**local_irq_disable();**
// 再做一次判断，如果还有未处理的中断--前面开启的时候硬件中断引发的新的软中断
	pending = local_softirq_pending();
	if (pending) {
// 如果这个软中断处理函数小于2ms，没有优先级更高的进程在处理，且restart次数小于 10
		if (time_before(jiffies, end) && !need_resched() &&
		    --max_restart)
			goto restart;
// 这样做是为了更快响应
		wakeup_softirqd();
	}

	lockdep_softirq_end(in_hardirq);
	account_irq_exit_time(current);
	**__local_bh_enable(SOFTIRQ_OFFSET);**
	WARN_ON_ONCE(in_interrupt());
	tsk_restore_flags(current, old_flags, PF_MEMALLOC);
}
```

下面解释

```c
	pending = local_softirq_pending();
	account_irq_enter_time(current);
```

获取当前cpu上的未执行的软中断

拿到pending的软中断，清零softirq_pending后才可以重新开本地中断，否则中间逻辑会混乱

在这段代码中，“`h += softirq_bit - 1;`”这行代码的作用是为了定位到具体要处理的软中断（softirq）的处理函数。下面我会简要解释其中的逻辑。

首先，`softirq_vec`是一个`softirq_action`结构体数组，每个成员都对应一种软中断类型，存储了该类型软中断的处理函数。`softirq_action`结构体大概是这样定义的：

```c
struct softirq_action {
	void (*action)(struct softirq_action *);
}
```

这里的`h`变量是一个指向`softirq_action`结构体的指针，它最初被设置为数组`softirq_vec`的基地址。

接下来，`pending`变量是一个位图（bitmask），表示当前有哪些软中断待处理。每个软中断类型对应`pending`中的一位。`ffs(pending)`函数返回`pending`中第一个设置为`1`的位的位置（从1开始计数），即找到**了最高优先级的待处理软中断的位位置。**

当`h += softirq_bit - 1;`执行时，`softirq_bit - 1`实际上是计算出该类型软中断在`softirq_vec`数组中的索引。因为`ffs`函数返回的位置是从1开始计数的，而数组是从0开始索引的，所以需要减去1。

举个例子，假设`pending`中最低位（也就是第1位，对应网络接收软中断）被设置了，那么`ffs(pending)`将返回1。因为网络接收软中断对应的`softirq_action`结构体存储在`softirq_vec`数组的第0个位置，所以需要`h += 0;`，这意味着`h`本身就已经指向了正确的处理函数，无需移动。这行代码的目的是使`h`指针指向需要处理的软中断的`softirq_action`结构体，通过这种方式可以找到并调用对应的处理函数。
