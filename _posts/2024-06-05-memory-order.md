---
title: "内存序列 memory order"
date: 2024-06-05
categories: [linux, kernel]
tags: ["memory order", "concurrency"]
---
内存序列（memory order）在多线程编程中用于控制操作在不同线程之间的可见性和执行顺序。C++11标准引入了内存序列，以便开发者可以细粒度地控制并发操作的同步和排序行为。内存序列通过`std::memory_order`枚举来指定，可以应用于原子操作，以确保数据一致性和线程安全。

#### 内存序列类型

#### 1. `memory_order_relaxed`

- **描述**：放松内存顺序约束，原子操作在执行时不与其他读写操作进行同步。
- **用途**：适用于无需跨线程同步保证的计数器等场景，只需保证原子操作自身的原子性。
- **示例**：
    
    ```cpp
    std::atomic<int> counter = 0;
    counter.fetch_add(1, std::memory_order_relaxed);
    
    ```
    

#### 2. `memory_order_consume` (不常用)

- **描述**：消费内存序列，在消费关系（读到数据并使用）中提供同步。
- **用途**：用于特定的消费关系场景，但由于实现复杂度和不常见的使用，常被忽略或替换为`memory_order_acquire`。
- **注意**：许多编译器对`memory_order_consume`支持较差，通常使用`memory_order_acquire`替代。

#### 3. `memory_order_acquire`

- **描述**：获取内存序列，确保后续的读写操作在当前原子操作完成后进行。
- **用途**：用于获取锁、读取共享变量等需要确保前面操作完成可见性的场景。
- **示例**：
    
    ```cpp
    std::atomic<bool> flag = false;
    while (!flag.load(std::memory_order_acquire)) {
        // 等待其他线程设置flag
    }
    
    ```
    

#### 4. `memory_order_release`

- **描述**：释放内存序列，确保之前的读写操作在当前原子操作之前完成。
- **用途**：用于释放锁、写入共享变量等需要确保后续操作可见性的场景。
- **示例**：
    
    ```cpp
    std::atomic<bool> flag = false;
    // 执行写操作
    flag.store(true, std::memory_order_release);
    
    ```
    

#### 5. `memory_order_acq_rel`

- **描述**：获取和释放内存序列，结合了`memory_order_acquire`和`memory_order_release`的语义。
- **用途**：用于读-改-写操作，需要同时确保之前和之后的操作顺序和可见性。
- **示例**：
    
    ```cpp
    std::atomic<int> counter = 0;
    counter.fetch_add(1, std::memory_order_acq_rel);
    
    ```
    

#### 6. `memory_order_seq_cst`

- **描述**：顺序一致内存序列，提供全局总顺序保证，所有线程中的原子操作都按严格顺序执行。
- **用途**：用于需要强顺序一致性保证的场景，适合大多数情况下的并发编程。
- **示例**：
    
    ```cpp
    std::atomic<int> counter = 0;
    counter.fetch_add(1, std::memory_order_seq_cst);
    
    ```
    

#### 内存序列的选择

选择合适的内存序列取决于具体的应用需求和同步要求。以下是一些常见的使用场景和推荐的内存序列：

- **计数器**：如果只是简单的计数操作，可以使用`memory_order_relaxed`。
- **标志和锁**：设置和检查标志或锁时，通常需要`memory_order_acquire`和`memory_order_release`。
- **读-改-写操作**：在需要同时确保之前和之后操作顺序时，使用`memory_order_acq_rel`。
- **强一致性**：当需要确保全局顺序一致性时，使用`memory_order_seq_cst`。

#### 示例：生产者-消费者模型

假设有一个生产者线程和一个消费者线程，生产者生成数据并设置一个标志，消费者等待标志设置后读取数据。

```cpp
#include <atomic>
#include <thread>
#include <iostream>

std::atomic<bool> flag(false);
int data = 0;

void producer() {
    data = 42;  // 写入数据
    flag.store(true, std::memory_order_release);  // 设置标志
}

void consumer() {
    while (!flag.load(std::memory_order_acquire)) {
        // 等待标志设置
    }
    std::cout << "Data: " << data << std::endl;  // 读取数据
}

int main() {
    std::thread prod(producer);
    std::thread cons(consumer);

    prod.join();
    cons.join();

    return 0;
}

```

在这个示例中，生产者在写入数据后设置标志，使用`memory_order_release`确保数据写入在标志设置前完成；消费者等待标志设置，使用`memory_order_acquire`确保在读取数据前标志已被设置。这确保了消费者线程可以看到生产者线程写入的数据。

总结来说，不同的内存序列提供了不同程度的同步和排序保证，选择合适的内存序列可以在性能和正确性之间取得平衡。在实际编程中，`memory_order_seq_cst`是最简单也是最安全的选择，但在性能关键的场景下，合理使用更松散的内存序列可以显著提升性能。
