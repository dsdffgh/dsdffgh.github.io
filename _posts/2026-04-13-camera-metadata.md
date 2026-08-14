---
title: "Camera Metadata"
date: 2026-04-13
categories: [android, camera]
tags: ["Android", "Camera", "Camera Metadata", "Camera2"]
---
**Camera MetaData 就是将参数以共享内存的形式，将所有的Camera 参数以 有序的结构体的形式 保存在一块连接的内存中。**

在API2 中，Java层中直接对参数进行设置并将其封装到Capture_Request即可，

而兼容 API1 ，则在 API1中的 SetParameter()/Paramters() 方法中进行转换，最终以 MetaData 的形式传递下去。

> MetaData 层次结构定义及 基本宏定义 /system/media/camera/include/system/camera_metadata_tags.h
MetaData 枚举定义及常用API 定义 /system/media/camera/include/system/camera_metadata.h
MetaData 基本函数操作结构体定义 [/system/media/camera/include/system/camera_vendor_tags.h](https://android-review.linaro.org/plugins/gitiles/platform/system/media/+/4e69694e4eb2d4b9a3e9a79025cc6c7107e6f516/camera/include/system/camera_vendor_tags.h)
MetaData 宏定义与字符串绑定 /system/media/camera/src/camera_metadata_tag_info.c
MetaData 核心代码实现 [/system/media/camera/src/camera_metadata.c](https://android-review.linaro.org/plugins/gitiles/platform/system/media/+/4e69694e4eb2d4b9a3e9a79025cc6c7107e6f516/camera/src/camera_metadata.c)
> 

```c
// system/media/camera/src/camera_metadata.c

/**
 * A packet of metadata. This is a list of entries, each of which may point to
 * its values stored at an offset in data.
 *
 * It is assumed by the utility functions that the memory layout of the packet
 * is as follows:
 *   |-----------------------------------------------|
 *   | camera_metadata_t                             |  区域一 ：何存camera_metadata_t  结构体定义
 *   |                                               |
 *   |-----------------------------------------------|
 *   | reserved for future expansion                 |  区域二 ：保留区，供未来使用
 *   |-----------------------------------------------|
 *   | camera_metadata_buffer_entry_t #0             |  区域三 ：何存所有 Tag 结构体定义
 *   |-----------------------------------------------|          TAG[0]、TAG[1]、.....、TAG[entry_count-1]
 *   | ....                                          |
 *   |-----------------------------------------------|
 *   | camera_metadata_buffer_entry_t #entry_count-1 |
 *   |-----------------------------------------------|
 *   | free space for                                |  区域四 ：剩余未使用的 Tag 结构体的内存保留，
 *   | (entry_capacity-entry_count) entries          |          该区域大小为 (entry_capacity - entry_count) 个TAG
 *   |-----------------------------------------------|
 *   | start of camera_metadata.data                 |  区域五 ：所有 Tag对应的具体 metadata 数据
 *   |                                               |
 *   |-----------------------------------------------|
 *   | free space for                                |  区域六 ：剩余未使用的 Tag 占用的内存
 *   | (data_capacity-data_count) bytes              |
 *   |-----------------------------------------------|
 *
 * With the total length of the whole packet being camera_metadata.size bytes.
 *
 * In short, the entries and data are contiguous in memory after the metadata
 * header.
 */
#define METADATA_ALIGNMENT ((size_t) 4)
struct camera_metadata {
    metadata_size_t          size;              //整个metadata数据大小
    uint32_t                 version;           //version
    uint32_t                 flags;
    metadata_size_t          entry_count;       //已经添加TAG的入口数量,（即内存块中已经包含多少TAG了）
    metadata_size_t          entry_capacity;    //最大能容纳TAG的入口数量（即最大能放多少tag）
    metadata_uptrdiff_t      entries_start;     //TAG区域相对开始处的偏移  Offset from camera_metadata
    metadata_size_t          data_count;        //记录数据段当前已用的内存空间
    metadata_size_t          data_capacity;     //总的数据段内存空间
    metadata_uptrdiff_t      data_start;        //数据区相对开始处的偏移 Offset from camera_metadata
    uint32_t                 padding;           // padding to 8 bytes boundary
    metadata_vendor_id_t     vendor_id;         // vendor id
};
typedef struct camera_metadata camera_metadata_t;
```

每个TAG 对应的数据结构体如下，占用内存 33 Byte，由于是以 8字节对齐，所以该结构体占用 40 个Byte。

```cpp
/**
 * A datum of metadata. This corresponds to camera_metadata_entry_t::data
 * with the difference that each element is not a pointer. We need to have a
 * non-pointer type description in order to figure out the largest alignment
 * requirement for data (DATA_ALIGNMENT).
 */
#define DATA_ALIGNMENT ((size_t) 8)
typedef union camera_metadata_data {
    uint8_t u8;
    int32_t i32;
    float   f;
    int64_t i64;
    double  d;
    camera_metadata_rational_t r;
} camera_metadata_data_t;

#define ENTRY_ALIGNMENT ((size_t) 4)
typedef struct camera_metadata_buffer_entry {
    uint32_t tag;
    uint32_t count;
    union {
        uint32_t offset;
        uint8_t  value[4];
    } data;
    uint8_t  type;
    uint8_t  reserved[3];
} camera_metadata_buffer_entry_t;

/**
 * A datum of metadata. This corresponds to camera_metadata_entry_t::data
 * with the difference that each element is not a pointer. We need to have a
 * non-pointer type description in order to figure out the largest alignment
 * requirement for data (DATA_ALIGNMENT).
 */
#define DATA_ALIGNMENT ((size_t) 8)
typedef union camera_metadata_data {
    uint8_t u8;
    int32_t i32;
    float   f;
    int64_t i64;
    double  d;
    camera_metadata_rational_t r;
} camera_metadata_data_t;

#define ENTRY_ALIGNMENT ((size_t) 4)
typedef struct camera_metadata_buffer_entry {
    uint32_t tag;								// key corresponds to value
    uint32_t count;
    union {
        uint32_t offset;
        uint8_t  value[4];
	  } data;											// 如果当前key值对应的value占用的字节数<=4时，直接将value存在entry的value中，以节省内存空间；否则，由offset记录地址偏移量，将key对应的value存在偏移地址为data_start + offset的内存中
    uint8_t  type;
    uint8_t  reserved[3];
} camera_metadata_buffer_entry_t;
```

这里是一些API定义和实现

```cpp
ANDROID_API
camera_metadata_t *allocate_camera_metadata(size_t entry_capacity,size_t data_capacity);

ANDROID_API
camera_metadata_t *place_camera_metadata(void *dst, size_t dst_size,size_t data_capacity);

ANDROID_API
void free_camera_metadata(camera_metadata_t *metadata);

ANDROID_API
size_t calculate_camera_metadata_size(size_t entry_count,size_t data_count);

ANDROID_API
camera_metadata_t *copy_camera_metadata(void *dst, size_t dst_size, const camera_metadata_t *src);

ANDROID_API
int add_camera_metadata_entry(camera_metadata_t *dst, uint32_t tag, const void *data, size_t data_count);

```

实现

```cpp
// system/media/camera/src/camera_metadata.c

#define LOG_TAG "camera_metadata"
#include <system/camera_metadata.h>
#include <camera_metadata_hidden.h>

// 获取 entries
static camera_metadata_buffer_entry_t *get_entries( const camera_metadata_t *metadata) {
    return (camera_metadata_buffer_entry_t*) ((uint8_t*)metadata + metadata->entries_start);
}
// 获取 数据
static uint8_t *get_data(const camera_metadata_t *metadata) {
    return (uint8_t*)metadata + metadata->data_start;
}
// 分配一个 camera_metadata 结构体对象
camera_metadata_t *allocate_camera_metadata(size_t entry_capacity,size_t data_capacity) {

    size_t memory_needed = calculate_camera_metadata_size(entry_capacity,data_capacity);
    void *buffer = calloc(1, memory_needed);
    camera_metadata_t *metadata = place_camera_metadata( buffer, memory_needed, entry_capacity, data_capacity);
    return metadata;
}
// 获取 metadata 结构体
camera_metadata_t *place_camera_metadata(void *dst, size_t dst_size,  size_t entry_capacity, size_t data_capacity) {

    size_t memory_needed = calculate_camera_metadata_size(entry_capacity, data_capacity);
    if (memory_needed > dst_size) return NULL;

    camera_metadata_t *metadata = (camera_metadata_t*)dst;
    metadata->version = CURRENT_METADATA_VERSION;
    metadata->flags = 0;
    metadata->entry_count = 0;
    metadata->entry_capacity = entry_capacity;
    metadata->entries_start = ALIGN_TO(sizeof(camera_metadata_t), ENTRY_ALIGNMENT);
    metadata->data_count = 0;
    metadata->data_capacity = data_capacity;
    metadata->size = memory_needed;
    size_t data_unaligned = (uint8_t*)(get_entries(metadata) +  metadata->entry_capacity) - (uint8_t*)metadata;
    metadata->data_start = ALIGN_TO(data_unaligned, DATA_ALIGNMENT);
    metadata->vendor_id = CAMERA_METADATA_INVALID_VENDOR_ID;

    assert(validate_camera_metadata_structure(metadata, NULL) == OK);
    return metadata;
}

void free_camera_metadata(camera_metadata_t *metadata) {
    free(metadata);
}

// 拷贝 metadata 结构体
camera_metadata_t* copy_camera_metadata(void *dst, size_t dst_size,const camera_metadata_t *src) {
    size_t memory_needed = get_camera_metadata_compact_size(src);

    camera_metadata_t *metadata = place_camera_metadata(dst, dst_size, src->entry_count, src->data_count);

    metadata->flags = src->flags;
    metadata->entry_count = src->entry_count;
    metadata->data_count = src->data_count;
    metadata->vendor_id = src->vendor_id;

    memcpy(get_entries(metadata), get_entries(src),  sizeof(camera_metadata_buffer_entry_t[metadata->entry_count]));
    memcpy(get_data(metadata), get_data(src),  sizeof(uint8_t[metadata->data_count]));

    assert(validate_camera_metadata_structure(metadata, NULL) == OK);
    return metadata;
}

int add_camera_metadata_entry(camera_metadata_t *dst, uint32_t tag, const void *data, size_t data_count) {
    int type = get_local_camera_metadata_tag_type(tag, dst);
    return add_camera_metadata_entry_raw(dst, tag, type, data, data_count);
}

int find_camera_metadata_entry(camera_metadata_t *src, uint32_t tag, camera_metadata_entry_t *entry) {
    if (src == NULL) return ERROR;

    uint32_t index;
    if (src->flags & FLAG_SORTED) {
        // Sorted entries, do a binary search
        camera_metadata_buffer_entry_t *search_entry = NULL;
        camera_metadata_buffer_entry_t key;
        key.tag = tag;
        search_entry = bsearch(&key, get_entries(src),  src->entry_count, 
                        sizeof(camera_metadata_buffer_entry_t), compare_entry_tags);
        if (search_entry == NULL) return NOT_FOUND;
        index = search_entry - get_entries(src);
    } else {
        // Not sorted, linear search
        camera_metadata_buffer_entry_t *search_entry = get_entries(src);
        for (index = 0; index < src->entry_count; index++, search_entry++) {
            if (search_entry->tag == tag) {
                break;
            }
        }
        if (index == src->entry_count) return NOT_FOUND;
    }
    return get_camera_metadata_entry(src, index,  entry);
}

int delete_camera_metadata_entry(camera_metadata_t *dst, size_t index) {
    camera_metadata_buffer_entry_t *entry = get_entries(dst) + index;
    size_t data_bytes = calculate_camera_metadata_entry_data_size(entry->type, entry->count);

    if (data_bytes > 0) {
        // Shift data buffer to overwrite deleted data
        uint8_t *start = get_data(dst) + entry->data.offset;
        uint8_t *end = start + data_bytes;
        size_t length = dst->data_count - entry->data.offset - data_bytes;
        memmove(start, end, length);

        // Update all entry indices to account for shift
        camera_metadata_buffer_entry_t *e = get_entries(dst);
        size_t i;
        for (i = 0; i < dst->entry_count; i++) {
            if (calculate_camera_metadata_entry_data_size( e->type, e->count) > 0 &&
                e->data.offset > entry->data.offset) {
                e->data.offset -= data_bytes;
            }
            ++e;
        }
        dst->data_count -= data_bytes;
    }
    // Shift entry array
    memmove(entry, entry + 1, sizeof(camera_metadata_buffer_entry_t) *(dst->entry_count - index - 1) );
    dst->entry_count -= 1;

    assert(validate_camera_metadata_structure(dst, NULL) == OK);
    return OK;
}

int update_camera_metadata_entry(camera_metadata_t *dst,size_t index, const void *data,size_t data_count,
        camera_metadata_entry_t *updated_entry) {

    camera_metadata_buffer_entry_t *entry = get_entries(dst) + index;

    size_t data_bytes =calculate_camera_metadata_entry_data_size(entry->type, data_count);
    size_t data_payload_bytes =data_count * camera_metadata_type_size[entry->type];

    size_t entry_bytes = calculate_camera_metadata_entry_data_size(entry->type, entry->count);
    if (data_bytes != entry_bytes) {
        // May need to shift/add to data array
        if (dst->data_capacity < dst->data_count + data_bytes - entry_bytes) {
            // No room
            return ERROR;
        }
        if (entry_bytes != 0) {
            // Remove old data
            uint8_t *start = get_data(dst) + entry->data.offset;
            uint8_t *end = start + entry_bytes;
            size_t length = dst->data_count - entry->data.offset - entry_bytes;
            memmove(start, end, length);
            dst->data_count -= entry_bytes;

            // Update all entry indices to account for shift
            camera_metadata_buffer_entry_t *e = get_entries(dst);
            size_t i;
            for (i = 0; i < dst->entry_count; i++) {
                if (calculate_camera_metadata_entry_data_size( e->type, e->count) > 0 && e->data.offset > entry->data.offset) {
                    e->data.offset -= entry_bytes;
                }
                ++e;
            }
        }
        if (data_bytes != 0) {
            // Append new data
            entry->data.offset = dst->data_count;
            memcpy(get_data(dst) + entry->data.offset, data, data_payload_bytes);
            dst->data_count += data_bytes;
        }
    } else if (data_bytes != 0) {
        // data size unchanged, reuse same data location
        memcpy(get_data(dst) + entry->data.offset, data, data_payload_bytes);
    }

    if (data_bytes == 0) {
        // Data fits into entry
        memcpy(entry->data.value, data, data_payload_bytes);
    }

    entry->count = data_count;

    if (updated_entry != NULL) {
        get_camera_metadata_entry(dst,  index,  updated_entry);
    }

    assert(validate_camera_metadata_structure(dst, NULL) == OK);
    return OK;
}

```

#### VendorTag Ops 实现

通过 Vendor Ops ，用户可以自已定义 metadata 及 对应的操作方法 ops。

通过 set_camera_metadata_vendor_ops() 及 set_camera_metadata_vendor_cache_ops() 方法 自定义对应的 ops。

---

当要使用 `CameraMetadata`，主要步骤如下：

1. 初始化 `mMetadata` 对象
2. 获取 TAG 为 `CAMERA3_TEMPLATE_PREVIEW` 的 `Metadata`
3. 调用 `mMetadata->update` 更新 `Metadata` 参数
4. 调用 `setStreamingRequest`下发参数

```cpp
// frameworks/av/services/camera/libcameraservice/CameraFlashlight.cpp

status_t CameraDeviceClientFlashControl::submitTorchEnabledRequest() {
    status_t res;

    if (mMetadata == NULL) {
        // 1. 初始化 mMetadata 对像
        mMetadata = new CameraMetadata();
        // 2. 获取 TAG 为 CAMERA3_TEMPLATE_PREVIEW 的 Metadata。
        res = mDevice->createDefaultRequest(  CAMERA3_TEMPLATE_PREVIEW, mMetadata);
    }
    // 3. 调用 mMetadata->update 更新 Metadata 参数
    uint8_t torchOn = ANDROID_FLASH_MODE_TORCH;
    mMetadata->update(ANDROID_FLASH_MODE, &torchOn, 1);
    mMetadata->update(ANDROID_REQUEST_OUTPUT_STREAMS, &mStreamId, 1);

    uint8_t aeMode = ANDROID_CONTROL_AE_MODE_ON;
    mMetadata->update(ANDROID_CONTROL_AE_MODE, &aeMode, 1);

    int32_t requestId = 0;
    mMetadata->update(ANDROID_REQUEST_ID, &requestId, 1);

    if (mStreaming) {
        // 4. 调用setStreamingRequest 下发参数
        res = mDevice->setStreamingRequest(*mMetadata);
        ======================>  
        +   @ frameworks/av/services/camera/libcameraservice/device3/Camera3Device.cpp
        +   List<const CameraMetadata> requests;
        +   requests.push_back(request);
        +   return setStreamin=RequestList(requests, /*lastFrameNumber*/NULL);
        +       =======>
        +       return submitRequestsHelper(requests, /*repeating*/true, lastFrameNumber);
        <======================
    } else {
        res = mDevice->capture(*mMetadata);
    }
    return res;
}
```

---

