---
title: "进程调度"
date: 2024-06-27
categories: [linux, kernel]
tags: ["scheduler", "process"]
---
> 原始记录日期：June 27, 2024 → July 9, 2024

![Untitled](/assets/images/linux-kernel-notes/linux-process-scheduling/image-01.png)

### 主动调度

```c
asmlinkage __visible void __sched schedule(void)
{
	struct task_struct *tsk = current;

	sched_submit_work(tsk);
	do {
		preempt_disable();
		__schedule(false);
		sched_preempt_enable_no_resched();
	} while (need_resched());
}
```

```c
/*
 * __schedule() is the main scheduler function.
 *
 * The main means of driving the scheduler and thus entering this function are:
 *
 *   1. Explicit blocking: mutex, semaphore, waitqueue, etc.
 *
 *   2. TIF_NEED_RESCHED flag is checked on interrupt and userspace return
 *      paths. For example, see arch/x86/entry_64.S.
 *
 *      To drive preemption between tasks, the scheduler sets the flag in timer
 *      interrupt handler scheduler_tick().
 *
 *   3. Wakeups don't really cause entry into schedule(). They add a
 *      task to the run-queue and that's it.
 *
 *      Now, if the new task added to the run-queue preempts the current
 *      task, then the wakeup sets TIF_NEED_RESCHED and schedule() gets
 *      called on the nearest possible occasion:
 *
 *       - If the kernel is preemptible (CONFIG_PREEMPT=y):
 *
 *         - in syscall or exception context, at the next outmost
 *           preempt_enable(). (this might be as soon as the wake_up()'s
 *           spin_unlock()!)
 *
 *         - in IRQ context, return from interrupt-handler to
 *           preemptible context
 *
 *       - If the kernel is not preemptible (CONFIG_PREEMPT is not set)
 *         then at the next:
 *
 *          - cond_resched() call
 *          - explicit schedule() call
 *          - return from syscall or exception to user-space
 *          - return from interrupt-handler to user-space
 *
 * WARNING: must be called with preemption disabled!
 */
static void __sched notrace __schedule(bool preempt)
{
	struct task_struct *prev, *next;
	unsigned long *switch_count;
	struct pin_cookie cookie;
	struct rq *rq;
	int cpu;

	cpu = smp_processor_id();
	rq = cpu_rq(cpu);
	prev = rq->curr;

	schedule_debug(prev);

	if (sched_feat(HRTICK))
		hrtick_clear(rq);

	local_irq_disable();
	rcu_note_context_switch();

	/*
	 * Make sure that signal_pending_state()->signal_pending() below
	 * can't be reordered with __set_current_state(TASK_INTERRUPTIBLE)
	 * done by the caller to avoid the race with signal_wake_up().
	 */
	smp_mb__before_spinlock();
	raw_spin_lock(&rq->lock);
	cookie = lockdep_pin_lock(&rq->lock);

	rq->clock_skip_update <<= 1; /* promote REQ to ACT */

	switch_count = &prev->nivcsw;
	if (!preempt && prev->state) {
		if (unlikely(signal_pending_state(prev->state, prev))) {
			prev->state = TASK_RUNNING;
		} else {
			deactivate_task(rq, prev, DEQUEUE_SLEEP);
			prev->on_rq = 0;

			/*
			 * If a worker went to sleep, notify and ask workqueue
			 * whether it wants to wake up a task to maintain
			 * concurrency.
			 */
			if (prev->flags & PF_WQ_WORKER) {
				struct task_struct *to_wakeup;

				to_wakeup = wq_worker_sleeping(prev);
				if (to_wakeup)
					try_to_wake_up_local(to_wakeup, cookie);
			}
		}
		switch_count = &prev->nvcsw;
	}

	if (task_on_rq_queued(prev))
		update_rq_clock(rq);

	next = pick_next_task(rq, prev, cookie);
	clear_tsk_need_resched(prev);
	clear_preempt_need_resched();
	rq->clock_skip_update = 0;

	**if (likely(prev != next)) {**
		rq->nr_switches++;
		rq->curr = next;
		++*switch_count;

		trace_sched_switch(preempt, prev, next);
		rq = **context_switch(r**q, prev, next, cookie); /* unlocks the rq */
	} else {
		lockdep_unpin_lock(&rq->lock, cookie);
		raw_spin_unlock_irq(&rq->lock);
	}

	balance_callback(rq);
}
```

### 抢占式调度

#### 用户态

得到当前进程，测试是否被标记应该调度，检查thread_info的flag：TIF_NEED_RESCHED，否则设置

```c
/*
 * resched_curr - mark rq's current task 'to be rescheduled now'.
 *
 * On UP this means the setting of the need_resched flag, on SMP it
 * might also involve a cross-CPU call to trigger the scheduler on
 * the target CPU.
 */
void resched_curr(struct rq *rq)
{
	struct task_struct *curr = rq->curr;
	int cpu;

	lockdep_assert_held(&rq->lock);

	if (**test_tsk_need_resched(curr)**)
		return;

	cpu = cpu_of(rq);

	if (cpu == smp_processor_id()) {
		set_tsk_need_resched(curr);
		set_preempt_need_resched();
		return;
	}

	if (set_nr_and_not_polling(curr))
		smp_send_reschedule(cpu);
	else
		trace_sched_wake_idle_without_ipi(cpu);
}
```

**系统调用返回时刻**

```c
arch/x86/entry/common.c
__visible void do_syscall_64(struct pt_regs *regs);
{
...
	syscall_return_slowpath(regs);
}
```

```c
/*
 * Called with IRQs on and fully valid regs.  Returns with IRQs off in a
 * state such that we can immediately switch to user mode.
 */
__visible inline void syscall_return_slowpath(struct pt_regs *regs)
{
	...
	prepare_exit_to_usermode(regs);
}
```

```c
/* Called with IRQs disabled. */
__visible inline void prepare_exit_to_usermode(struct pt_regs *regs)
{
	struct thread_info *ti = current_thread_info();
...
	if (unlikely(cached_flags & EXIT_TO_USERMODE_LOOP_FLAGS))
		**exit_to_usermode_loop**(regs, cached_flags);

#ifdef CONFIG_COMPAT
	/*
	 * Compat syscalls set TS_COMPAT.  Make sure we clear it before
	 * returning to user mode.  We need to clear it *after* signal
	 * handling, because syscall restart has a fixup for compat
	 * syscalls.  The fixup is exercised by the ptrace_syscall_32
	 * selftest.
	 *
	 * We also need to clear TS_REGS_POKED_I386: the 32-bit tracer
	 * special case only applies after poking regs and before the
	 * very next return to user mode.
	 */
	ti->status &= ~(TS_COMPAT|TS_I386_REGS_POKED);
#endif

	user_enter_irqoff();

	mds_user_clear_cpu_buffers();
}
```

在这里检查并调度

```c
static void exit_to_usermode_loop(struct pt_regs *regs, u32 cached_flags)
{
	/*
	 * In order to return to user mode, we need to have IRQs off with
	 * none of _TIF_SIGPENDING, _TIF_NOTIFY_RESUME, _TIF_USER_RETURN_NOTIFY,
	 * _TIF_UPROBE, or _TIF_NEED_RESCHED set.  Several of these flags
	 * can be set at any time on preemptable kernels if we have IRQs on,
	 * so we need to loop.  Disabling preemption wouldn't help: doing the
	 * work to clear some of the flags can sleep.
	 */
	while (true) {
		/* We have work to do. */
		local_irq_enable();

		**if (cached_flags & _TIF_NEED_RESCHED)
			schedule();**

		if (cached_flags & _TIF_UPROBE)
			uprobe_notify_resume(regs);

		/* deal with pending signal delivery */
		if (cached_flags & _TIF_SIGPENDING)
			do_signal(regs);

		if (cached_flags & _TIF_NOTIFY_RESUME) {
			clear_thread_flag(TIF_NOTIFY_RESUME);
			tracehook_notify_resume(regs);
		}

		if (cached_flags & _TIF_USER_RETURN_NOTIFY)
			fire_user_return_notifiers();

		/* Disable IRQs and retry */
		local_irq_disable();

		cached_flags = READ_ONCE(current_thread_info()->flags);

		if (!(cached_flags & EXIT_TO_USERMODE_LOOP_FLAGS))
			break;
	}
}

```

**中断返回时刻**

```c
arch\x86\entry\entry_64.S

common_interrupt:
	ASM_CLAC
	addq	$-0x80, (%rsp)			/* Adjust vector to [-256, -1] range */
	**interrupt do_IRQ**
	/* 0(%rsp): old RSP */
ret_from_intr:
	DISABLE_INTERRUPTS(CLBR_NONE)
	TRACE_IRQS_OFF
	decl	PER_CPU_VAR(irq_count)

	/* Restore saved previous stack */
	popq	%rsp

	testb	$3, CS(%rsp)
	**jz	retint_kernel**

	/* Interrupt came from user space */
GLOBAL(retint_user)
	mov	%rsp,%rdi
	**call	prepare_exit_to_usermode**
	TRACE_IRQS_IRETQ
	SWITCH_USER_CR3
	SWAPGS
	jmp	restore_regs_and_iret

```

#### 内核态

**内核态启动可抢占**

```c
preempt.h	include\linux	8815	2020/7/1	4

#define preempt_enable() \
do { \
	barrier(); \
	if (unlikely(preempt_count_dec_and_test())) \
		__preempt_schedule(); \
} while (0)
```

**从中断返回内核态**

```c
arch\x86\entry\entry_64.S

common_interrupt:
	ASM_CLAC
	addq	$-0x80, (%rsp)			/* Adjust vector to [-256, -1] range */
	**interrupt do_IRQ**
	/* 0(%rsp): old RSP */
ret_from_intr:
	DISABLE_INTERRUPTS(CLBR_NONE)
	TRACE_IRQS_OFF
	decl	PER_CPU_VAR(irq_count)

	/* Restore saved previous stack */
	popq	%rsp

	testb	$3, CS(%rsp)
	**jz	retint_kernel**
```

[上下文和 preempt_count](%E4%B8%8A%E4%B8%8B%E6%96%87%E5%92%8C%20preempt_count%20bdff91d304b7435483321e3791c8b4b2.md) 

---

**时间片：进程在被抢占前所能持续运行的时间。**

**时间片过长会导致系统对交互的响应表现欠佳**，让人觉得系统无法并发处理程序；时间片太短会明显增大进程切换带来的处理器耗时，因此会有相当一部分系统时间用在进程切换上，而这些进程的运行时间片却很短。

linux的CFS调度器并不直接分配时间片到进程，它是将处理器的使用比划分给了进程。这样一来，进程所获得处理器时间是和系统负载密切相关。这个比例进一步收nice值的影响。

**调度器**面对的情形就是这样, 其任务是在程序之间共享CPU时间, 创造并行执行的错觉, 该任务分为两个不同的部分, 其中一个涉及**调度策略**, 另外一个涉及**上下文切换**.

---

#### idle process 与中断

**为什么需要 idle process**

idle process 用于 process accouting，以及降低能耗。

在设计上，调度器没有进程可调度时（例如所有进程都在等待输入），需要停下来，什么都不做，等待下一个中断把它唤醒。
中断可能来自外设（例如网络包、磁盘读操作完成），也可能来自某个进程的定时器。

**Linux 调度器中，实现这种“什么都不做”的方式就是引入了 idle 进程**。

- 只有当**没有任何其他进程需要调度时，才会调度到 idle 进程**（因此它的优先级是最低的）。
- 在实现上，这个 idle 进程其实就是内核自身的一部分。
- 当执行到 idle 进程时，它的行为就是**“等待中断事件”**。

Linux 会为**每个 CPU 创建一个 idle task**（因为每个 CPU 上一个调度器），并固定在这个 CPU 上执行。
当这个 CPU 上没有其他进程可执行时，就会调度到 idle 进程。它的开销就是 `top` 里面的
**`id`** 统计。

注意，这个 idle process 和 process 的 idle 状态是两个完全不相关的东西，后者指的是 process 在等待
某个事件（例如 I/O 事件）。

**idle process 实现**

idle 如何实现视具体处理器和操作系统而定，但**目的都是一样的：减少能耗**。

最基本的实现方式：[HLT](https://en.wikipedia.org/wiki/HLT_%28x86_instruction%29)指令会让处理器停止执行（并进入节能模式），直到下一个中断触发它继续执行。
不过有个模块肯定是要保持启用的：中断控制器（interrupt controller）。
当外设触发中断时，中断控制器会通过特定针脚给 CPU 发送信号，唤醒处理器的执行。
实际上现代处理器的行为要比这个复杂的多，但主要还是在节能和快速响应之间做出折中。
有的 CPU 还会在 idle 期间降低处理器频率，以实现节能目标。

[下半部-软中断](%E4%B8%8B%E5%8D%8A%E9%83%A8-%E8%BD%AF%E4%B8%AD%E6%96%AD%20d05d21a86c864a7fa8622401145b0cfd.md)
