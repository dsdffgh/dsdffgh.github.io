---
title: "Linux 内存管理"
date: 2024-06-29
categories: [linux, kernel]
tags: ["memory management", "buddy allocator"]
---
> 原始记录日期：June 29, 2024 → July 3, 2024

### buddy allocator

通用内存分配，不区分对象

```c
mmzone.h	include\linux	39165	2020/7/1	126
struct zone {
	/* free areas of different sizes */
	struct free_area	free_area[MAX_ORDER];
}
struct free_area {
	struct list_head	free_list[MIGRATE_TYPES]; /* unmovable, movable reclaimable, ... */
	unsigned long		nr_free;
};
```

![Untitled](/assets/images/linux-kernel-notes/linux-memory-management/image-01.png)

想要分配内存时，遍历这个free_area域

```c
page_alloc.c	mm	208775	2020/7/1	4115
for (current_order = order; current_order < MAX_ORDER; ++current_order) {
		area = &(zone->free_area[current_order]);
		page = list_first_entry_or_null(&area->free_list[migratetype],
							struct page, lru);
		if (!page)
			continue;
		list_del(&page->lru);
		rmv_page_order(page);
		area->nr_free--;
		expand(zone, page, order, current_order, area, migratetype);
		set_pcppage_migratetype(page, migratetype);
		return page;
```

所有的空闲页框分组为11个块链表，每个块链表分别包含大小为1，2，4，8，16，32，64，128，256，512和1024个连续页框的页框块。最大可以申请1024个连续页框，对应4MB大小的连续内存。每个页框块的第一个页框的物理地址是该块大小的整数倍，如图

Buddy算法一直在对页框做拆开合并拆开合并的动作。Buddy算法牛逼就牛逼在运用了世界上任何正整数都可以由2^n的和组成。这也是Buddy算法管理空闲页表的本质。它是以页为单位分配内存。

![](https://s4.51cto.com/oss/201812/06/4c9dd93bb483ae2e1c06fa2d15f83de3.jpg)

申请一个256个页框的块，先从256个页框的链表里查找空闲块，没有就从512的找，找到了以后把512的拆开，剩下的一个移动到256的链表里去。

buddy的分配也会造成内存碎片的问题，虽然对用户程序不影响，但是内核没有办法获取大块连续内存。在嵌入式设备一般采用CMA来解决。

CMA的全称是contiguous memory allocator， 其工作原理是：预留一段的内存给驱动使用，但当驱动不用的时候，CMA区域可以分配给用户进程用作匿名内存或者页缓存。而当驱动需要使用时，就将进程占用的内存通过回收或者迁移的方式将之前占用的预留内存腾出来，供驱动使用。

### slab allocator

slab分配器分配内存以字节为单位，基于伙伴分配器的大内存进一步细分成小内存分配。换句话说，slab 分配器仍然从 Buddy 分配器中申请内存，之后自己对申请来的内存细分管理。

The buddy system is for generic memory allocation

 Most of the time objects of specific types are used. They have a fixed structure.

- No reason to allocate and deallocate them.
- Take up a large memory region and use it for dedicated object storage (of only.one type)
- For fast access, keep a cache of pre-initialized objects
- Use and return → Similar to a pool of objects

![Untitled](/assets/images/linux-kernel-notes/linux-memory-management/image-02.png)

这个结构描述的一段内存就是一个slab缓存池

```c
struct kmem_cache {
/* 2) touched by every alloc & free from the backend */
    slab_flags_t flags;        /* constant flags */
    unsigned int num;        /* 每个 slab 中的 objs 数量 */
/* 3) cache_grow/shrink */
    /* 每个 slab 所使用的页框数量 order */
    unsigned int gfporder;
    /* force GFP flags, e.g. GFP_DMA */
    gfp_t allocflags;
    size_t colour;            /* cache colouring range */
    unsigned int colour_off;    /* colour offset */
    struct kmem_cache *freelist_cache;
    unsigned int freelist_size;
/* 4) cache creation/removal */
    const char *name;
    struct list_head list;
    int refcount;
    int object_size;
    int align;
    struct kmem_cache_node *node[MAX_NUMNODES];
};
```

#### The slab allocator has three principle aims:

- The allocation of small blocks of memory to help eliminate internal fragmentation that would be otherwise caused by the buddy system;
    
    分配小块内存，以帮助消除由伙伴系统引起的内部碎片;
    
- The caching of commonly used objects so that the system does not waste time allocating, initialising and destroying objects. Benchmarks on Solaris showed excellent speed improvements for allocations with the slab allocator inuse�[[Bon94](https://www.kernel.org/doc/gorman/html/understand/understand031.html#bonwick94)];
    
    常用对象的缓存，使系统不会浪费时间分配、初始化和销毁对象。Solaris 上的基准测试显示，使用板分配器 [Bon94] 进行分配时，分配速度得到了极大的提高;
    
- The better utilisation of hardware cache by aligning objects to the L1 or L2 caches.
    
    通过将对象与 L1 或 L2 缓存对齐，可以更好地利用硬件缓存。
    

专用的 slab 通过 `kmem_cache_alloc()`函数进行内存申请。例如，在`kernel/fork.c`文件中，`vm_area_alloc()`函数的功能是申请一个 `vm_area_struct`结构体实例，通过`vma = kmem_cache_alloc(vm_area_cachep, GFP_KERNEL);`来完成该过程。

而 kmalloc() 只是适用于分配通用类型的 slab。或者说

> To help eliminate internal fragmentation  normally caused by a binary buddy allocator, two sets of caches of small memory buffers ranging from 2^5 (32) bytes to 2^17 (131072) bytes are maintained. One cache set is suitable for use with DMA devices. These caches are called size-N and size-N(DMA) where *N* is the size of the allocation, and a function kmalloc() (see Section [8.4.1](https://www.kernel.org/doc/gorman/html/understand/understand011.html#Sec:%20kmalloc)) is provided for allocating them. With this, the single greatest problem with the low level page allocator is addressed.
> 

> The final task of the slab allocator is hardware cache utilization. If there
is space left over after objects are packed into a slab, the remaining space
is used to *color* the slab. Slab coloring is a scheme which attempts to have objects in **different slabs** use
different lines in the cache. **By placing objects at a different starting offset
within the slab**, it is likely that objects will use different lines in the CPU
cache helping ensure that objects from the same slab cache will be unlikely
to flush each other. With this scheme, space that would otherwise be wasted
fulfills a new function. Figure ?? shows how a page allocated from the buddy allocator is used to store objects that using coloring to align the objects to the L1 CPU cache.
> 

板分配器的最终任务是硬件缓存利用率。如果将对象打包到板中后仍有剩余空间，则剩余空间将用于为板着色。板着色是一种方案，它试图让不同板中的对象在缓存中使用不同的线条。通过将对象放置在 slab 中的不同起始偏移量，对象可能会在 CPU 缓存中使用不同的行，从而有助于确保来自同一 slab 缓存的对象不太可能相互刷新。通过这种方案，原本会浪费的空间实现了新的功能。图片 ？？显示如何使用从好友分配器分配的页面来存储对象，这些对象使用着色将对象与 L1 CPU 缓存对齐。

![内存对齐](/assets/images/linux-kernel-notes/linux-memory-management/image-03.png)

The result of this is best explained by an example. Let us say that s_mem (the address of the first object) on the slab is 0 for convenience, that 100 bytes are wasted on the slab and alignment is to beat 32 bytes to the L1 Hardware Cache on a Pentium II.

用一个例子来最好地解释其结果。为了方便起见，假设 slab 上的 s_mem （第一个对象的地址）为 0，在 slab 上浪费了 100 个字节，并且与 Pentium II 上的 L1 硬件缓存对齐为 32 个字节。

In this scenario, the first slab created will have its objects start at 0. The second will start at 32, the third at 64, the fourth at 96 and the fifth will start back at 0. With this, objects from each of the slabs will not hit the same hardware cache line on the CPU. The value of colour is 3 and colour_off is 32.

在此方案中，创建的第一个板的对象将从 0 开始。第二个将从 32 开始，第三个从 64 开始，第四个从 96 开始，第五个将从 0 开始。这样一来，每个板上的对象就不会命中 CPU 上的同一硬件缓存行。 colour 的值为 3， colour_off 的值为 32。

#### **Cache Creation**

The function kmem_cache_create() is responsible for creating new
caches and adding them to the cache chain. The tasks that are taken to create
a cache are函数 kmem_cache_create() 负责创建新缓存并将其添加到缓存链中。创建缓存所执行的任务包括

- Perform basic sanity checks for bad usage;
    
    对不良使用情况进行基本的健全性检查;
    
- Perform debugging checks if  is set;
    
    CONFIG_SLAB_DEBUG
    
    如果设置了 CONFIG_SLAB_DEBUG ，则执行调试检查;
    
- Allocate a  from the 
slab cache ;
    
    kmem_cache_t
    
    cache_cache
    
    从 cache_cache 板缓存中分配一个 kmem_cache_t ;
    
- Align the object size to the word size;
    
    将对象大小与字大小对齐;
    
- Calculate how many objects will fit on a slab;
    
    计算一块板上可容纳多少个物体;
    

![Untitled](/assets/images/linux-kernel-notes/linux-memory-management/image-04.png)

Figure [8.3](https://www.kernel.org/doc/gorman/html/understand/understand011.html#fig:%20kmem_cache_create) shows the call graph relevant to the creation of a cache; each function is fully described in the Code Commentary.

---

- Align the object size to the hardware cache;
    
    将对象大小与硬件缓存对齐;
    
- Calculate colour offsets ;
    
    计算颜色偏移量 ;
    
- Initialise remaining fields in cache descriptor;
    
    初始化缓存描述符中的剩余字段;
    
- Add the new cache to the cache chain.
    
    将新缓存添加到缓存链中。
    

```c
include/linux/mm_types.h
struct page {
    union {
        struct {    /* Page cache and anonymous pages */
            ...
        };

        struct {    /* slab, slob and slub */
            union {
                struct list_head slab_list;
                struct {    /* Partial pages */
                    struct page *next;

                    int pages;    /* Nr of pages left */
                    int pobjects;    /* Approximate count */
                };
            };
            struct kmem_cache *slab_cache;
            /* Double-word boundary */
            void *freelist;        /* first free object */
            union {
                void *s_mem;    /* slab: first object */
                unsigned long counters;        /* SLUB */
                ...
            };
        };
        ...
    };
};
```

[Linux 内核 | 内存管理——Slab 分配器 - 一丁点儿](https://www.dingmos.com/index.php/archives/23/)

[Slab Allocator](https://www.kernel.org/doc/gorman/html/understand/understand011.html)
