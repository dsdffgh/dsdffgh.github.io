---
title: "Camera Preview"
date: 2026-04-13
categories: [android, camera]
tags: ["Android", "Camera", "Camera Preview", "Camera2"]
---
### Preview the overall flow 预览整体流程

![image.png](/assets/images/android-camera/camera-preview/image.png)

1. App在MainActivity 中使用一些预览控件，它们都包含一个surface作为取相机数据的容器。在openCamera之前：
    1. 首先需要获取系统的 `CameraManager`实例，通过`getSystemService(Context.CAMERA_SERVICE)`方法获取。
    2. 选择相机设备：使用  `CameraManager` 的  `getCameraIdList()`方法获取可用的相机设备列表，选择需要的相机设备的 ID
2. 对于MainActivity 在onCreat的时候，调用API通知Framework Native Service-- CameraServer去 connect HAL ，打开硬件sensor
    - 相关函数、方法
        
        ```java
        CameraManager.openCamera(String cameraId,  CameraDevice.StateCallback callback, @Nullable Handler handler)
        /*
        接口打开相机设备。
        @ String  cameraId：相机设备编号
        @ CameraDevice.StateCallback  callback：相机设备打开状态监听(判断相机打开是否成功)的回调对象(调用openCamera()时必须传入该回调对象，才能打开相机设备)
        @ Handler handler：指定执行回调方法的线程(可以是主线程，也可以后台线程)。
        */
        	--> ...
        		--> private CameraDevice openCameraDeviceUserAsync(String cameraId,
                    CameraDevice.StateCallback callback, Executor executor, final int uid)
                    throws CameraAccessException
        ```
        
        **对于 `CameraDevice.StateCallback` 须实现方法：**
        
        - `onOpened`：相机设备打开完成时调用的方法（相机设备已就绪，可以调用 `CameraDevice.createCaptureSession()`来创建 `CameraCaptureSession`对象）。
        - `onClosed`：关闭相机设备时调用。
        - `onDisconnected`：相机设备不可再调用时调用（该回调内可调用 `CameraDevice.close`方法关闭相机设备）。
        - `onError`：相机设备不可再调用时调用（该回调内可调用 `CameraDevice.close`方法关闭相机设备）。
        
        **对于 `openCameraDeviceUserAsync` 方法，主要做了下面几件事：**
        
        - 获取当前cameraId指定相机的设备信息。（获取ICameraService代理，调用其getCameraInfo方法获取当前设备的属性）
        - 利用获取相机的设备信息创建CameraDeviceImpl实例。（并将来自App的CameraDevice.StateCallback接口存入该实例中）
        - 调用远程CameraService获取当前相机的远程服务。（再将CameraDeviceImpl中的内部类CameraDeviceCallback作为参数通过ICameraService的connectDevice方法传入Camera Service去打开并获取一个ICameraDeviceUser代理）
        - 将获取的远程服务设置到CameraDeviceImpl实例中（并将该代理存入CameraDeviceImpl中进行管理。）
        - 返回CameraDeviceImpl实例
    - 流程概览图
        
        ![image.png](/assets/images/android-camera/camera-preview/image-1.png)
        
3. OpenCamera成功的话，回调从CameraServer 通知到APP，在onOpened() 中调用preview的操作，在此时创建会话CameraCaptureSession 。创建过程中调用configStream(p)--参数中包含Surface的引用，也就是说，cameraServer包装了来自App的sureface容器为stream，再通过HIDL传给HAL，再由HAL继续configStream
    - 相关函数、方法
        
        
        ```java
        CameraDevice.StateCallback.onOpened()// 回调方法，
        	--> CameraDevice.createCaptureSession(SessionConfiguration config)
        	/* @ SessionConfiguration  config： 会话配置参数（聚合类参数，包含创建CameraCaptureSession的所有参数）
        		在打开相机设备之后便需要去创建一个相机会话，用于传输图像请求，其最终实现是调用该方法来进行实现的，
        		而该方法会去调用到Camera Framework中的createCaptureSessionInternal方法，该方法主要做了两件事：
        		首先调用configureStreamsChecked方法来配置数据流。
        		其次实例化了一个CameraCaptureImpl对象，并通过传入CameraCaptureSession.StateCallback回调类将该对象发送至至App中。	
        			--> 而在configureStreamsChecked方法中会去调用ICameraDeviceUser代理的一系列方法进行数据流配置，
        					其中调用cancelRequest方法停掉当前的的预览流程，调用deleteStream方法删除之前的数据流，调用createStream创建新的数据流，
        					最后调用endConfigure来进行数据流的配置工作，针对性的配置便在最后这个endConfigure方法中。
        	*/
        	--> CameraCaptureSession.setRepeatingRequest(CaptureRequest request,  CameraCaptureSession.CaptureCallback callback,Handler handler)
        		/*
        		 @ CaptureRequest request：无限期重复的CaptureRequest。
        		    向Camera底层送一个CaptureRequest，底层不停重复送这一个CaptureRequest，不能为null
        		 @ CameraCaptureSession.CaptureCallback callback:  CaptureRequest处理状态监听的回调。
        		    当一个CaptureRequest发送给相机设备，使用这个监听器跟踪该CaptureRequest的处理进度，CaptureRequest完成处理时会通知该回调对象。
        		    该回调对象的所有方法都有默认的空实现，也可根据需求重写相应方法。
        
        		 @ Handler handler：
        		    CaptureRequest回调方法执行的线程。如果为null，表示使用当前线程的looper
        		 */
        			 --> submitCaptureRequest
        			 // Framework 层的方法。将此次Request下发到CameraService中。
        ```
        
        - **`SessionConfiguration` 需配置参数：**
            1. `session type`：会话类型。
            常用普通预览使用 `SessionConfiguration.SESSION_REGULAR`，高速预览使用 `SessionConfiguration.SESSION_HIGH_SPEED`
            2. `List<OutputConfiguration> outputs：CameraCaptureSession`的输出配置列表。
            根据不同的场景选择需要的surface，创建 `OutputConfiguration`列表，以拍照模式为例，选择相机预览、拍照所需的surface作为相机图像数据最终输出对象，创建 `OutputConfiguration`列表参数。
            3. `Executor executor`：指定回调执行的线程。
            通常，建议不要在主（UI）线程上执行相机操作。
            4. `CameraCaptureSession.StateCallback cb`：监听 `CameraCaptureSession`创建状态的回调对象。
             `onConfigured`和 `onConfigureFailed`两个抽象方法必须重写。
            5. `CaptureRequest`参数： `SessionConfiguration`类对象实例化后，调用该类 `setSessionParameters`接口，设置创建 `CameraCaptureSession`时所需要的 `CaptureRequest`参数。根据场景，利用 `CaptureRequest.Builder`创建所需的 `CaptureRequest`参数，例如，预览时，创建 `CameraDevice.TEMPLATE_PREVIEW`类型的 `CaptureRequest`，并将预览用的surface添加到该 `CaptureRequest`，作为预览输出目标; 拍照时，创建 `CameraDevice.TEMPLATE_STILL_CAPTURE`类型`CaptureRequest`，并将拍照用的surface添加到该 `CaptureRequest`，作为拍照输出目标
        - `CameraCaptureSession`
            
            https://developer.android.google.cn/reference/android/hardware/camera2/CameraCaptureSession
            
            | **Nested classes** |  |
            | --- | --- |
            | `class` | [`CameraCaptureSession.CaptureCallback`](https://developer.android.google.cn/reference/android/hardware/camera2/CameraCaptureSession.CaptureCallback)
            
            A callback object for tracking the progress of a [`CaptureRequest`](https://developer.android.google.cn/reference/android/hardware/camera2/CaptureRequest) submitted to the camera device. |
            | `class` | [`CameraCaptureSession.StateCallback`](https://developer.android.google.cn/reference/android/hardware/camera2/CameraCaptureSession.StateCallback)
            A callback object for receiving updates about the state of a camera capture session. |
            - **而对于 `CameraCaptureSession.StateCallback`回调对象需实现方法：**
                1. `onConfigured`：会话配置完成， `CameraCaptureSession`创建成功（在该回调方法中可获取到 `CameraCaptureSession`实例，然后调用 `CameraCaptureSession.setRepeatingRequest`方法发送重复 `CaptureRequest`，开启预览）。
                2. `onConfigureFailed`： `CameraCaptureSession`创建失败时调用，可能配置的Surface size不支持，或者Surface数量配置太多。
                3. `onActive`：在 `onConfigured`后执行，即开始真的处理 `CaptureRequest`。
                4. `onReady`：当 `CameraCaptureSession`没有 `CaptureRequest`可处理时调用。
                5. `onCaptureQueueEmpty`：相机设备的输入CaptureRequest队列为空时回调。
                6. `onClosed`： `CameraCaptureSession`关闭时调用。
                
                以上 `onConfigured` 和  `onConfigureFailed`两个抽象方法必须实现，其余的可以空实现
                
                ![image.png](/assets/images/android-camera/camera-preview/image-2.png)
                
            
            配置好的一次会话，用于从Camera获取图像，或者reprocess图像。
            
            可能需要几百毫秒才能完成Session的创建，HAL通常在这个阶段完成如下事情
            
            - 创建Pipeline
            - 申请Buffer
            
            当创建新的Session时，旧有Session会被关掉，对应有onClosed回调
            
4. configStream成功后，CameraServer回调通知App，然后App调setRepeatingRequest 给 CameraServer 。CameraServer初始化时便起来了一个死循环线程等待来接收Request。
    - 相关函数、方法
        - **configureStreamsChecked**
            
            在configureStreamsChecked方法中会去调用ICameraDeviceUser代理的一系列方法进行数据流配置，其中调用cancelRequest方法停掉当前的的预览流程，调用deleteStream方法删除之前的数据流，调用createStream创建新的数据流，最后调用endConfigure来进行数据流的配置工作，针对性的配置便在最后这个endConfigure方法中。
            
        - **CameraCaptureSession.CaptureCallback回调对象需实现方法**
            1. `onCaptureStarted`：当相机设备开始处理CaptureRequest，捕捉输出图时调用。
            2. `onCaptureProgressed`：相机设备部分模块完成CaptureRequest处理，有Partial Result上报时调用。
            3. `onCaptureCompleted`：CaptureRequest完全处理完成，处理结果可用，有  `TotalCaptureResult`上报时调用。
            4. `onCaptureBufferLost`：CaptureRequest处理后的Buffer没有被送到目标Surface时调用（通常原因是底层处理这路Stream发生错误或因Flush而主动丢帧）。
            5. `onCaptureFailed`：整个CaptureRequest处理失败，未生成TotalCaptureResult时调用。
            6. `onCaptureSequenceAborted`：整个序列的CaptureRequest放弃继续处理时调用（通常是由于调用了 `stopRepeating` 或 `abortCaptures`）。
            7. `onCaptureSequenceCompleted`：整个序列的CaptureRequest处理完后调用，sequence id等于调用发送捕捉请求的方法(ex. capture)的返回值。
5. CameraServer 将 request交给HAL得到处理结果后，取出处理结果中的Buffer填到App给的容器中。 
    1. `SetRepeatingRequest` 为了预览,则交给Preview的Surface容器
    2. `Capture Request` 则将收到的Buffer交给ImageReader的Surface容器
    
    之后由BufferQueue机制回调对应Surface控件的callback
    
6. 结束，关闭相机。
    1. 关闭CameraCaptureSession
        - CameraCaptureSession对象调用abortCaptures()接口，通知停止向相机设备发送CaptureRequest，并通知相机设备放弃还未处理完成的CaptureRequest。
        - CameraCaptureSession对象调用close()接口，关闭CameraCaptureSession。
    2. 关闭相机设备
        
        CameraDevice对象调用close()接口，关闭相机设备。
        
    3. 释放资源
        1. 关闭捕捉会话后，cameraCaptureSession对象置null。
        2. 关闭相机设备后，cameraDevice对象置null。
        3. 创建捕捉会话时使用的surface对象，置为null。

![image.png](/assets/images/android-camera/camera-preview/image-3.png)

Camera Service 主程序，是随着系统启动而运行，主要目的是向外暴露AIDL接口给Framework进行调用，同时通过调用Camera Provider的HIDL接口，建立与Provider的通信，并且在内部维护从Framework以及Provider获取到的资源，并且按照一定的框架结构保持整个Service在稳定高效的状态下运行。

---

#### **整体函数调用流程是这样**

![image.png](/assets/images/android-camera/camera-preview/image-4.png)

### 预览详细流程

#### App

[Camera 入门第一篇 - 程序员Android的博客 - 博客园](https://www.cnblogs.com/programandriod/p/13868580.html)

#### Service

https://deepinout.com/android-camera/android-camera-service-intro.html

由于在Camera Service启动初始化的时候已经获取了相应相机设备的属性配置，并存储在DeviceInfo3中，所以该方法就是从对应的 DeviceInfo3中取出属性返回即可。参见2.4前面链接 

- 在connectDevice完毕，App获取到一个设备之后，为了采集图像，执行CameraDevice的createCaptureSession操作，到达Framework，再通过ICameraDeviceUser代理进行了一系列操作，分别包含了cancelRequest/beginConfigure/deleteStream/createStream以及endConfigure方法来进行**数据流的配置。**
    - `cancelRequest`方法，在该方法中会去通知Camera3Device将RequestThread中的Request队列清空，停止Request的继续下发。
    - `beginConfigure`方法是空实现
    - `deleteStream` / `createStream`分别是用于删除之前的数据流以及为新的操作创建数据流，紧接着调用位于整个调用流程的末尾– `endConfigure`
    - `endConfigure`方法，该方法对应着CameraDeviceClient的endConfigure方法，其逻辑比较简单，在该方法中会调用Camera3Device的configureStreams的方法，而该方法又会去通过ICameraDeviceSession的configureStreams_3_4的方法最终将需求传递给Provider。

**数据流的配置完成后**，并且App也获取了Framework中的CameraCaptureSession对象，之后便可**下发图像请求**了。在下发之前需要**先创建**。而App通过createCaptureRequest实现，该方法在Framework中实现，内部会再去调用Camera Service中的AIDL接口createDefaultRequest，在其内部又会去调用Camera3Device的createDefaultRequest方法，最后通过 `ICameraDeviceSession`代理的 `constructDefaultRequestSettings`方法将需求下发到Provider端去创建一个默认的Request配置，一旦操作完成，Provider会将配置上传至Service，进而给到App中。

```java
createCaptureRequest // 在Framework中实现
// 调用该方法，最终会调用到 Camera Service 中 ICameraDeviceUser 的 createDefaultRequest 方法来创建一个默认配置的CameraMetadataNative
// 然后实例化一个CaptureRequest.Builder对象，并将刚才获取的CameraMetadataNative传入其中，之后返回该CaptureRequest.Builder对象，在App中，直接通过调用该Buidler对象的build方法，获取一个CaptureRequest对象
	--> createDefaultRequest // Camera Service中的AIDL接口
		--> Camera3Device::createDefaultRequest
			--> constructDefaultRequestSettings
```

**下发请求：**创建request完成后，调用CameraCaptureSession的setRepeatingRequest方法下发Request到Camera Service中，在这个过程中会调用Camera3Device的setStreamingRequestList方法，将需求发送到Camera3Device中，到RequestThread中的RequestQueue中，并唤醒RequestThread线程，会从RequestQueue中取出Request，通过之前获取的ICameraDeviceSession代理的processCaptureRequest_3_4方法将需求发送至Provider中(buffer从framework传入hal），一旦发送成功，便立即返回，在App端便等待这结果的回传。

下发的过程中伴随着buffer的传递，参看https://deepinout.com/android-camera/how-does-the-cameraservice-buffer-interact-with-hal.html

**setRepeatingRequest做了以下几件事**

App调用该方法开始预览流程，通过层层调用最终会调用到Framework中的 `submitCaptureRequest`方法，该方法主要做了两件事：

- 首先调用CameraService层CameraDeviceUser的 `submitRequestList`方法，将此次Request下发到CameraService中。
- 其次将App通过参数传入的 `CameraCaptureSession.CaptureCallback`对象存到CameraDeviceImpI对象中。

#### HAL

https://source.android.google.cn/docs/core/camera/camera3

The API models the camera subsystem as a pipeline that converts incoming requests for frame captures into frames, on a 1:1 basis. The requests encapsulate all configuration information about the capture and processing of a frame. This includes resolution and pixel format; manual sensor, lens and flash control; 3A operating modes; RAW->YUV processing control; statistics generation; and so on.

In simple terms, the application framework requests a frame from the camera subsystem, and the camera subsystem returns results to an output stream. In addition, metadata that contains information such as color spaces and lens shading is generated for each set of results. You can think of camera version 3 as a pipeline to camera version 1's one-way stream. It converts each capture request into one image captured by the sensor, which is processed into:

- A result object with metadata about the capture.
- One to N buffers of image data, each into its own destination surface.

The set of possible output surfaces is preconfigured:

- Each surface is a destination for a stream of image buffers of a fixed resolution.
- Only a small number of surfaces can be configured as outputs at once (~3).

**以高通为例：**两部分组成

- 运行在系统中的主程序通过提供了标准的HIDL接口保持了与Camera Service的跨进程通讯
- 为了进一步扩展其功能，通过dlopen方式加载了一系列So库，而其中就包括了实现了Camera HAL3接口的So库。

![image.png](/assets/images/android-camera/camera-preview/image-5.png)

而HAL3接口主要定义了主要用于实现图像控制的功能，其实现主要交由平台厂商或者开发者来完成，所以Camera HAL3 So库的实现各式各样，例如在高通平台上需要分析的CamX-CHI框架

1. 初始化：相机打开后，
    
    ```java
    openCarema()  // App调用
    	--> CameraService::connectDevice
    		--> ICameraDevice::open() // HIDL接口，通知Provider
    ```
    
    在Provider内部又通过调用之前获取的 `camera_module_t`中 `open`方法来获取一个Camera 设备，对应于HAL中的 `camera3_device_t`结构体，紧接着，在Provider中会继续调用获取到的 `camera3_device_t`的 `initialize`方法进行初始化动作。
    
2. configstream
    
    App在获取并打开相机设备之后，会调用CameraDevice.createCaptureSession来获取CameraDeviceSession，并且通过Camera api v2标准接口，通知Camera Service，调用其CameraDeviceClient.endConfigure方法，在该方法内部又会去通过HIDL接口ICameraDeviceSession::configureStreams_3_4通知Provider开始处理此次配置需求，在Provider内部，会去通过在调用open流程中获取的camera3_device_t结构体的configure_streams方法来将数据流的配置传入CamX-CHI中，之后由CamX-CHI完成对数据流的配置工作
    
3. 处理请求：Provider收到请求之后，会调用camera3_device_t结构体的process_capture_request开始了HAL针对此次Request的处理
4. 上传结果：在用户开启了相机应用，相机框架收到某次Request请求之后会开始对其进行处理，一旦有图像数据产生便会通过层层回调最终返回到应用层进行显示：
    
    Session内部完成图像数据的处理，将结果发送至Usecase中
    Usecase接收到来自Session的数据，并将其上传至Provider
    

Hal从kernel—这里是sensor模块，拿到数据，并填充到buf中。在经过mCallbackOps描述的`Camera3Device`类的`process_capture_result`把buf从hal层传回framework。此时buf内含有sensor模块的图像数据。

Sensor模块会从一个基本的pattern中根据raw、rgb、rgbA以及yuv420等格式填充图像，它其实还有一些人为创造的noise。

当framework拿到 hal 层的result时，并不表示此时的buf可用，还要看是否有sensor的timeStamp（当然在EmulatedCamera中是肯定有的）。如果sensor timestamp还没有到，这里需要

- 把包含有buf的result放到pendingOutputBuffer结构中。
- 把对应的还有metadata放到pendingMetadata中。

如果拿到了timeStamp并且此时也不是partial result，或者说是最后一个partial result就可以把result的buf（含数据）还给stream，并且把request（含配置）发送给等待的consumer了。

<aside>
💡 **Consumer的queue又有如何操作?**

</aside>

当hal层传过来buf时，我们把buf return给关心的单元，进而经Surface类的queueBuffer实现，这里我们要搞清楚：**把buffer queue到什么上?**

当前queuebuffer会把buffer queue到GraphicBufferProducer的mActiveBuffer上，并广播通知感兴趣者有新buffer到来。

<aside>
💡 **buffer对应的request去向。这个request里含有本次请求的信息，比如camera Metadata。**

</aside>

一般会从mResultQueue的头部get一个Result，并且result的metadata中也有对应的frame number，这样也可以和之前的buffer对应起来。

---

对于通用HAL，参看https://source.android.google.cn/docs/core/camera/camera3_requests_hal?hl=zh-cn

![image.png](/assets/images/android-camera/camera-preview/image-6.png)

![image.png](/assets/images/android-camera/camera-preview/image-7.png)

**HAL operation summary**

- Asynchronous requests for captures come from the framework.
- HAL device must process requests in order. And for each request, produce output result metadata, and one or more output image buffers.
- First-in, first-out for requests and results, and for streams referenced by subsequent requests.
- Timestamps must be identical for all outputs from a given request, so that the framework can match them together if needed.
- All capture configuration and state (except for the 3A routines) is encapsulated in the requests and results.

### 拍照流程

实现拍照的流程的前半部分与预览基本相同，不同之处：

1. 在创建session之前，会先初始化ImagrReader，用于捕获可用的图片，从而调用ImageSaver保存图片
2.  其次是除了预览的previewSurface，又创建了一个ImageReader获取的Surface
3. 拍照前设置自动对焦在照片后取消自动对焦，因为这会导致相机不断触发对焦的操作，拍摄成功后回到相机的预览模式，https://deepinout.com/android-camera2-api/android-camera2-api-auto-focus-part2.html

### 附录

相关实现说明和其它介绍参看

https://deepinout.com/android-camera/android-camera-app-fw-intro.html

[‣](https://app.notion.com/p/fffbafcb1e7f80d9b0d6e640ee7ed5bf?pvs=21) 

关于请求API

https://source.android.google.cn/docs/core/camera/camera3_requests_methods?hl=zh-cn

关于回调

https://deepinout.com/android-camera/a-callback-mechanism-for-camera-api2.html

关于Buffer

https://deepinout.com/android-camera/how-does-a-camera-kernel-populate-a-buffer.html

关于API2

https://deepinout.com/android-camera2-api/android-camera2-api-overview.html

关于Binder机制

https://www.kancloud.cn/aslai/interview-guide/1126391

Android跨进程通信：图文详解 Binder机制 原理 https://zhuanlan.zhihu.com/p/133638518

[理解Android Binder机制(1/3)：驱动篇](https://app.notion.com/p/Android-Binder-1-3-01a9da8ef9b14641a8134e30dfe0180b?pvs=21)

