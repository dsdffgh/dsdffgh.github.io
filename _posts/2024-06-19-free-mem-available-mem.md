---
title: "free-Mem 和 available-Mem"
date: 2024-06-19
categories: [linux, kernel]
tags: ["Linux memory", "free", "available"]
---
![Untitled](/assets/images/linux-kernel-notes/free-mem-available-mem/image-01.png)

```c
page_alloc.c	mm	208775	2020/7/1	4115
long si_mem_available(void)
{
	long available;
	unsigned long pagecache;
	unsigned long wmark_low = 0;
	unsigned long pages[NR_LRU_LISTS];
	struct zone *zone;
	int lru;

	for (lru = LRU_BASE; lru < NR_LRU_LISTS; lru++)
		pages[lru] = global_node_page_state(NR_LRU_BASE + lru);

	for_each_zone(zone)
		wmark_low += zone->watermark[WMARK_LOW];

	/*
	 * Estimate the amount of memory available for userspace allocations,
	 * without causing swapping.
	 */
	available = global_page_state(NR_FREE_PAGES) - totalreserve_pages;

	/*
	 * Not all the page cache can be freed, otherwise the system will
	 * start swapping. Assume at least half of the page cache, or the
	 * low watermark worth of cache, needs to stay.
	 */
	pagecache = pages[LRU_ACTIVE_FILE] + pages[LRU_INACTIVE_FILE];
	pagecache -= min(pagecache / 2, wmark_low);
	available += pagecache;

	/*
	 * Part of the reclaimable slab consists of items that are in use,
	 * and cannot be freed. Cap this estimate at the low watermark.
	 */
	available += global_page_state(NR_SLAB_RECLAIMABLE) -
		     min(global_page_state(NR_SLAB_RECLAIMABLE) / 2, wmark_low);

	if (available < 0)
		available = 0;
	return available;
}
```

文件映射是可以在必要的时刻丢掉的，因为在磁盘上有对应文件。只读页直接丢掉，可写页回写后丢掉。匿名页可以置换到swap分区（如果有的话），但是没有的话，那就不可以

再加上slab里可释放部分（磁盘上有对应数据的内容）

```c
/*
 * calculate_totalreserve_pages - called when sysctl_lowmem_reserve_ratio
 *	or min_free_kbytes changes.
 */
static void calculate_totalreserve_pages(void)
{
	struct pglist_data *pgdat;
	unsigned long reserve_pages = 0;
	enum zone_type i, j;

	for_each_online_pgdat(pgdat) {

		pgdat->totalreserve_pages = 0;

		for (i = 0; i < MAX_NR_ZONES; i++) {
			struct zone *zone = pgdat->node_zones + i;
			long max = 0;

			/* Find valid and maximum lowmem_reserve in the zone */
			for (j = i; j < MAX_NR_ZONES; j++) {
				if (zone->lowmem_reserve[j] > max)
					max = zone->lowmem_reserve[j];
			}

			/* we treat the high watermark as reserved pages. */
			max += high_wmark_pages(zone);

			if (max > zone->managed_pages)
				max = zone->managed_pages;

			pgdat->totalreserve_pages += max;

			reserve_pages += max;
		}
	}
	totalreserve_pages = reserve_pages;
}
```

- The provided code snippet is a function definition for `calculate_totalreserve_pages`, which is intended for recalculating the total reserved pages in the system. This recalculation might be triggered by changes in system settings such as `sysctl_lowmem_reserve_ratio` or `min_free_kbytes`. Let's break down what this function does:
    1. **Page Data (`pglist_data`) Iteration**: It iterates through all online page data structures (nodes in the system that contain memory) using the `for_each_online_pgdat(pgdat)` macro. This macro facilitates looping through each memory node data structure in a system.
    2. **Initialization**: For each `pglist_data` structure found, it sets the `totalreserve_pages` to 0. This is to ensure a fresh calculation for each node.
    3. **Zone Iteration**: Inside each node, it iterates through all memory zones (e.g., DMA, DMA32, Normal, etc.) using a for loop from 0 to `MAX_NR_ZONES`. Each memory zone is represented by a `zone` structure, which contains information specific to that zone, like the number of managed pages or low memory reserves for different types of pages.
    4. **Maximum Lowmem Reserve Calculation**: For each zone, it finds the highest `lowmem_reserve` value among all types of zones. This value represents the number of pages reserved in the zone to prevent low memory conditions for higher priority processes.
    5. **High Watermark Addition**: To this maximum reserve value, it adds the high watermark value of the zone (`high_wmark_pages(zone)`), which represents the minimum number of free pages desirable in the zone to smoothly handle memory requests.
    6. **Handling Excess Reserves**: If the sum of the maximum reserve and the high watermark is greater than the total number of managed pages in the zone (`zone->managed_pages`), it adjusts the sum to be equal to `zone->managed_pages`. This ensures that the reserved pages do not exceed what's available in the zone.
    7. **Update Totals**: The function updates both the total reserved pages for the current node (`pgdat->totalreserve_pages`) and a global total (`reserve_pages`), which captures the cumulative reserved pages across all nodes.
    8. **Global Update**: Finally, it updates the global `totalreserve_pages` variable with the value of `reserve_pages`, reflecting the total reserved pages system-wide.
    
    This function is critical for memory management, ensuring that there are always enough reserved pages available to prevent memory starvation for critical processes, especially under low memory conditions.
    

---

#### 题外话

```c
#define min(x, y) ({                            \
	typeof(x) _min1 = (x);                  \
	typeof(y) _min2 = (y);                  \
	(void) (&_min1 == &_min2);              \
	_min1 < _min2 ? _min1 : _min2; })
```

`（void）（&x==&y）；`这句话，看起来很多余，仔细分析一下，你会发现这条语句很有意思。

一是用来给用户提示一个警告，对于不同类型的指针比较，编译器会发出一个警告，提示两种数据的类型不同。

二是两个数进行比较运算，运算的结果却没有用到，有些编译器可能会给出一个warning，加一个（void）后，就可以消除这个警告。
