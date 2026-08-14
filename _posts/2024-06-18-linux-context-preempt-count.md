---
title: "上下文和 preempt_count"
date: 2024-06-18
categories: [linux, kernel]
tags: ["preempt_count", "interrupt", "context"]
---
> 原始记录日期：June 18, 2024 → June 19, 2024

[https://arthurchiao.art/blog/linux-irq-softirq-zh/](https://arthurchiao.art/blog/linux-irq-softirq-zh/)

![Untitled](/assets/images/linux-kernel-notes/linux-context-preempt-count/image-01.png)

```c
//arch/arm64/include/asm/preempt.h
static inline int preempt_count(void)
{
    return READ_ONCE(current_thread_info()->preempt.count); //(struct thread_info *)current->preempt.count
}
```

preempt_count 这个成员被用来判断当前进程是否可以被抢占。**如果 preempt_count 不等于0（可能是代码调用preempt_disable显式的禁止了抢占，也可能是处于中断上下文等），说明当前不能进行抢占**，如果 preempt_count 等于0，说明已经具备了抢占的条件（当然具体是否要抢占当前进程还是要看当前进程的 thread info 中的 flag 成员是否设定了 _TIF_NEED_RESCHED 这个标记，可能是当前的进程的时间片用完了，也可能是由于中断唤醒了优先级更高的进程）。

内核可以使用`preemptible()`， 这个宏会检查当前上下文是否可以被抢占。理论上，如果`preempt_count()`为0，则表示没有禁止抢占的操作，当前上下文应该是可抢占的。

下文所参考的宏定义

```c
#define PREEMPT_BITS	8
#define SOFTIRQ_BITS	8
#define HARDIRQ_BITS	4
#define NMI_BITS	1

#define PREEMPT_SHIFT	0
#define SOFTIRQ_SHIFT	(PREEMPT_SHIFT + PREEMPT_BITS)
#define HARDIRQ_SHIFT	(SOFTIRQ_SHIFT + SOFTIRQ_BITS)
#define NMI_SHIFT	(HARDIRQ_SHIFT + HARDIRQ_BITS)

#define __IRQ_MASK(x)	((1UL << (x))-1)

...

#define PREEMPT_OFFSET	(1UL << PREEMPT_SHIFT)
#define SOFTIRQ_OFFSET	(1UL << SOFTIRQ_SHIFT)
#define HARDIRQ_OFFSET	(1UL << HARDIRQ_SHIFT)
#define NMI_OFFSET	(1UL << NMI_SHIFT)

#define SOFTIRQ_DISABLE_OFFSET	(2 * SOFTIRQ_OFFSET)
```

1. Preemption-disable Count 位段
    
    占8bit，用来记录当前进程被显式的禁止抢占的嵌套的次数。也就是说，每调用一次 preempt_disable()就会加1，调用 preempt_enable()，就会减1。preempt_disable() 和 preempt_enable() 必须成对出现，可以嵌套，最大嵌套的深度是255，因为只有8bit。
    
2. Software interrupt count
    
    占8bit，用来记录当前正在运行进程被软中断打断嵌套的次数。对此位段进行操作有两个场景：
    (1) 也是在进入soft irq handler之前给此位段加1，退出soft irq handler之后给此位段减1。由于soft irq handler在一个CPU上是不会并发的，总是串行执行，因此，这个场景下只需要一个bit就够了，也就是上图中的bit8。通过该bit可以知道当前task是否在sofirq context。
    
    ```c
    softirq.c	kernel	19710	2020/7/1	395
    asmlinkage __visible void __softirq_entry __do_softirq(void)
    {
    	...
    	__local_bh_disable_ip(_RET_IP_, SOFTIRQ_OFFSET);// 从进程上下文切换到了软中断上下文
    	...
    }
    ```
    
    ```c
    static __always_inline void __local_bh_disable_ip(unsigned long ip, unsigned int cnt)
    {
    	preempt_count_add(cnt);//改变了上下文环境
    	barrier();
    }
    ```
    
    (2) 由于内核同步的需求，**进程上下文需要禁止所有 下半部-所有软中断和tasklet**。这时候，kernel提供了 local_bh_enable()和 local_bh_disable()这样的接口函数。这部分的概念是和preempt disable/enable 类似的，占用了bit9--bit15，最大可以支持127次嵌套。
    
    ```c
    #ifdef CONFIG_TRACE_IRQFLAGS
    extern void __local_bh_disable_ip(unsigned long ip, unsigned int cnt);
    #else
    static __always_inline void __local_bh_disable_ip(unsigned long ip, unsigned int cnt)
    {
    	preempt_count_add(cnt);
    	barrier();
    }
    #endif
    
    static inline void local_bh_disable(void)
    {
    	__local_bh_disable_ip(_THIS_IP_, SOFTIRQ_DISABLE_OFFSET);
    }
    ```
    
3. Hardware interrupt count 位段
    
    占4bit，用来记录当前正在运行进程被硬中断打断嵌套的次数，用来描述当前中断handler嵌套的深度。
    
    通用的IRQ handler被 irq_enter()和 irq_exit()这两个函数包围。irq_enter()说明进入到IRQ context，而 irq_exit()则说明退出IRQ context。在irq_enter()函数中会调用 preempt_count_add(HARDIRQ_OFFSET)，为"Hardware interrupt count"的bit field增加1。在 irq_exit()函数中，会调用 preempt_count_sub(HARDIRQ_OFFSET) 减去1。占用了4bit说明硬件中断handler最大可以嵌套15层。
    
    在旧的内核中，占12bit，支持4096个嵌套。当然，在旧的kernel中还区分fast interrupt handler和slow interrupt handler，中断handler最大可以嵌套的次数理论上等于系统IRQ的个数。在实际中，这个数目不可能那么大（内核栈就受不了），因此，即使系统支持了非常大的中断个数，也不可能各个中断依次嵌套，达到理论的上限。基于这样的考虑，后来内核减少为10bit（在general arch的代码中修改为10，实际上，各个arch可以redefine自己的hardirq count的bit数）。但是，当内核大佬们决定废弃slow interrupt handler的时候，实际上，中断的嵌套已经不会发生了。因此，理论上，hardirq count要么是0，要么是1。不过呢，不能总拿理论说事，实际上，万一有写奇葩或者老古董driver在handler中打开中断，那么这时候中断嵌套还是会发生的，但是，应该不会太多，因此，目前占用4bit，应付15个奇葩driver是妥妥的。
    
    以arm为例
    
    ```c
    irq.c	arch\arm\kernel	3276	2020/7/1	38
    
    /*
     * handle_IRQ handles all hardware IRQ's.  Decoded IRQs should
     * not come via this function.  Instead, they should provide their
     * own 'handler'.  Used by platform code implementing C-based 1st
     * level decoding.
     */
    void handle_IRQ(unsigned int irq, struct pt_regs *regs)
    {
    	__handle_domain_irq(NULL, irq, false, regs);
    }
    
    /*
     * asm_do_IRQ is the interface to be used from assembly code.
     */
    asmlinkage void __exception_irq_entry
    asm_do_IRQ(unsigned int irq, struct pt_regs *regs)
    {
    	handle_IRQ(irq, regs);
    }
    //arm处理硬件中断的总入口
    ```
    
    ```c
    irqdesc.c	kernel\irq	21756	2020/7/1	490
    
    /**
     * __handle_domain_irq - Invoke the handler for a HW irq belonging to a domain
     * @domain:	The domain where to perform the lookup
     * @hwirq:	The HW irq number to convert to a logical one
     * @lookup:	Whether to perform the domain lookup or not
     * @regs:	Register file coming from the low-level handling code
     *
     * Returns:	0 on success, or -EINVAL if conversion has failed
     */
    int __handle_domain_irq(struct irq_domain *domain, unsigned int hwirq,
    			bool lookup, struct pt_regs *regs)
    {
    	struct pt_regs *old_regs = set_irq_regs(regs);
    	unsigned int irq = hwirq;
    	int ret = 0;
    
    	**irq_enter();**
    
    #ifdef CONFIG_IRQ_DOMAIN
    	if (lookup)
    		irq = irq_find_mapping(domain, hwirq);
    #endif
    
    	/*
    	 * Some hardware gives randomly wrong interrupts.  Rather
    	 * than crashing, do something sensible.
    	 */
    	if (unlikely(!irq || irq >= nr_irqs)) {
    		ack_bad_irq(irq);
    		ret = -EINVAL;
    	} else {
    		generic_handle_irq(irq);
    	}
    
    	**irq_exit();**
    	set_irq_regs(old_regs);
    	return ret;
    }
    #endif
    ```
    
    从这个irq_enter()进去
    
    ```c
    softirq.c	kernel	19710	2020/7/1	395
    
    /*
     * Enter an interrupt context.
     */
    void irq_enter(void)
    {
    	rcu_irq_enter();
    	if (is_idle_task(current) && !in_interrupt()) {
    		/*
    		 * Prevent raise_softirq from needlessly waking up ksoftirqd
    		 * here, as softirq will be serviced on return from interrupt.
    		 */
    		local_bh_disable();
    		tick_irq_enter();
    		_local_bh_enable();
    	}
    
    	__irq_enter();
    }
    ```
    
    ```c
    
    /*
     * It is safe to do non-atomic ops on ->hardirq_context,
     * because NMI handlers may not preempt and the ops are
     * always balanced, so the interrupted value of ->hardirq_context
     * will always be restored.
     */
    #define __irq_enter()					\
    	do {						\
    		account_irq_enter_time(current);	\
    		preempt_count_add(HARDIRQ_OFFSET);	\
    		trace_hardirq_enter();			\
    	} while (0)
    ```
    
    add one and we're in (hard) IRQ context
    
4. Reschedule needed位段
    
    最高 bit31 这个"reschedule needed"位告诉内核，当前有一个优先级较高的进程应该在第一时间获得CPU。必须要在 preempt_count 为非零值的情况下，才会设置这个bit，否则的话内核早就可以直接对这个任务进行抢占，而没必要设置此bit并等待。
    

#### task 各类上下文

```c
 //include/linux/preempt.h
/*
 * Are we doing bottom half or hardware interrupt processing?
 *
 * in_irq()               - We're in (hard) IRQ context
 * in_softirq()           - We have BH disabled, or are processing softirqs
 * in_interrupt()         - We're in NMI,IRQ,SoftIRQ context or have BH disabled
 * in_serving_softirq() - We're in softirq context
 * in_nmi()               - We're in NMI context
 * in_task()              - We're in task context
 *
 * Note: due to the BH disabled confusion: in_softirq(),in_interrupt() really should not be used in new code.
 */
#define in_irq()        (hardirq_count()) //preempt_count() & HARDIRQ_MASK
#define in_softirq()    (softirq_count()) //preempt_count() & SOFTIRQ_MASK
#define in_interrupt()    (irq_count())     //preempt_count() & (HARDIRQ_MASK | SOFTIRQ_MASK | NMI_MASK)
#define in_serving_softirq()    (softirq_count() & SOFTIRQ_OFFSET) //preempt_count() & SOFTIRQ_OFFSET 只使用最低bit
#define in_nmi()        (preempt_count() & NMI_MASK)
#define in_task()        (!(preempt_count() & (NMI_MASK | HARDIRQ_MASK | SOFTIRQ_OFFSET)))
```

1. irq context 其实就是 hard irq context，也就是说明当前正在执行中断handler（top half），只要 preempt_count 中的 hardirq count 大于0（＝1是没有中断嵌套，如果大于1，说明有中断嵌套），那么就是IRQ context。
2. softirq context 并没有那么的直接，一般人会认为当 sofirq handler 正在执行的时候就是 softirq context。这样说当然没有错，sofirq handler 正在执行的时候，会增加"Software interrupt count"，当然是softirq context。不过，在其他context的情况下，例如进程上下文中，有可能因为同步的要求而调用local_bh_disable()，这时候，**通过 local_bh_disable()/local_bh_enable() 保护起来的代码也是执行在 softirq context 中**。当然，这时候其实并没有正在执行softirq handler。如果你确实想知道当前是否正在执行 softirq handler，可以使用  in_serving_softirq() 来完成这个使命，这是通过操作 preempt_count 的bit8来完成的。
3. 所谓中断上下文，由 in_interrupt() 来表示，就是 IRQ context + softirq context + NMI context。
4. 进程上下文由 in_task() 表示，local_bh_disable()/local_bh_enable()保护的区间，仍然属于进程上下文，感觉与in_softirq()有冲突，此时就既属于软中断上下文又属于进程上下文了。

---

1. 只要看一下 preempt_count() 的值，内核就可知道当前的情况如何，比如 preempt_count() 值是非零值，就表示当前线程不能被 scheduler 抢占，因为此时要么是抢占已经被明确被禁止了，要么是CPU当前正在处理某种中断。同理，非零值也表示当前线程不能睡眠(待确认！)。
2. preempt_disable()只适用于线程在kernel里运行的情况，而用户空间的代码则总是可以被抢占的。
3. 一个问题：如果配置为非抢占式内核，内核代码不能被抢占，那么就没有必要跟踪记录 preempt_disable()了，因为抢占是永远被关闭，不用浪费时间去维护这些信息，因此此时 preempt_count 的 preempt-disable 这几个 bit 总是为0，preemptible() 函数将总是返回 false。非抢占式内核中，在某些情况下，例如当 spin_lock 被持有时（这种情况确实是 atomic context），in_atomic()却会由于这个 preempt_count()==0 而返回 false。
    
    即使在非抢占式内核中，`preempt_count`和相关机制仍然有其用途：
    
    1. **兼容性**：Linux内核的设计倾向于在不同配置下保持接口和行为的一致性。通过保留`preempt_count`机制，可以在抢占式和非抢占式内核之间更容易地进行切换，并允许相同的代码在两种模式下运行。
    2. **调试和错误检查**：`preempt_count`记录了抢占禁止和其他相关事件（如持有的自旋锁数量）。即使在非抢占式内核中，这些信息也对于调试和保证代码行为正确性很有帮助。
    3. **自旋锁和原子上下文**：自旋锁在任何类型的内核中都需要，以保护共享数据不受并发访问的影响。使用`preempt_count`来追踪自旋锁的持有情况，以及标识原子上下文，对于确保内核的正确同步非常重要。
        
        `preempt_count`追踪自旋锁的持有情况主要是通过增加或减少其值来实现的。当代码执行到需要获取自旋锁的地方时，它会通过增加`preempt_count`的值来禁止抢占，当释放自旋锁时，相应地减少`preempt_count`的值。**这样，`preempt_count`的值实际上反映了当前上下文中禁止抢占的深度，包括由于自旋锁持有等原因导致的禁止抢占。**
        
        [linux自旋锁](linux%E8%87%AA%E6%97%8B%E9%94%81%202c82b1477b254bc98e672e4e818f6383.md) 
        
    4. **软中断和任务let的管理**：在Linux内核中，软中断（softirqs）和任务let（tasklets）是异步执行的中断上下文，它们依赖于`preempt_count`来防止在关键时刻被抢占，从而保证它们的执行顺序和完整性。
4. might_sleep(): 指示当前函数可以睡眠。如果它所在的函数处于原子上下文(atomic context)中，将打印出堆栈的回溯信息。这个函数主要用来做调试工作，在你不确定不期望睡眠的地方是否真的不会睡眠时，就把这个宏加进去。对于内核Release版本，一般没有使能 CONFIG_DEBUG_ATOMIC_SLEEP，might_sleep() 就是一个空函数。

---

#### 当前上下文不可被抢占的情况包括：

- 持有自旋锁
- 中断处理中
- 处于[软中断](%E4%B8%8B%E5%8D%8A%E9%83%A8-%E8%BD%AF%E4%B8%AD%E6%96%AD%20d05d21a86c864a7fa8622401145b0cfd.md)或tasklets上下文

---

workqueue 不依赖软中断子系统，**运行在进程上下文中**。这意味着 wq 不能像 tasklet 那样是原子的.
