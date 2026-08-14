---
title: "Camera 算法"
date: 2026-04-13
categories: [android, camera]
tags: ["Android", "Camera", "ISP", "HDR", "Denoise"]
---
- 单帧算法：美颜、广角畸变矫正、附加表情、单摄背景虚化等等
- 多帧算法：MFNR（多帧降噪）、HDR（高动态范围）
- 双摄算法：双摄景深或双摄背景虚化，需获取两个摄像头的图像并且一般要求主摄副摄同步，分别获取图像处理，输出一帧主摄

---

## 关于 RAW

## HDR

In photography, the term Dynamic Range refers to the contrast between the brightest and darkest tones of an image, measured in f-stops. As a rule of thumb, a photo with under 4 stops of dynamic range is considered low contrast or Low Dynamic Range, whereas a photo with 8 or more stops is considered high contrast or High Dynamic Range (HDR). 

![Dynamic range. The spectrum of luminance conditions in real world.](/assets/images/android-camera/camera-algorithms/screenshot-2024-08-27-15-33-37.png)

Dynamic range. The spectrum of luminance conditions in real world.

由于动态范围的数值太大，因此动态范围的单位一般用比值的对数来表示，称为档（stops），可以表示为：

$$
\text { stops }=\log _2 \frac{\text { the whitest whites }}{\text { the blackest blacks }}
$$

![Screenshot from 2024-08-29 13-42-57.png](/assets/images/android-camera/camera-algorithms/screenshot-2024-08-29-13-42-57.png)

高动态范围成像，目的是再现比标准数字成像或摄影技术更大的动态光度范围。虽然人眼可以适应各种光照条件，但大多数成像设备每通道使用8位，因此我们仅限于256级。当我们拍摄真实世界的场景时，明亮的区域可能曝光过度，而黑暗的区域可能曝光不足，所以我们不能用一次曝光来捕捉所有的细节。HDR图像处理每个通道使用8位以上的图像（通常为32位浮点值），允许更宽的动态范围。

HDR （High Dynamic Range）和色调映射（tone mapping）是用来解决动态范围问题的技术。

### 单帧hdr

点击链接查看和 Kimi 智能助手的对话 [https://kimi.moonshot.cn/share/crjpnciul729efsaonfg](https://kimi.moonshot.cn/share/crjpnciul729efsaonfg)

[浅析HDR拍照构想（3）夭寿啦！单帧也能搞HDR？ - 哔哩哔哩](https://app.notion.com/p/HDR-3-HDR-103bafcb1e7f81e194bde5802527d392?pvs=21) 

https://deepinout.com/hdr/understand-the-various-types-of-hdr.html

### **多帧异曝光HDR**

这种方法基于包围曝光（Exposure Bracketing），即拍摄一系列曝光不同的照片，每张照片的曝光值之间相差一定的曝光值，将这些照片合成为 HDR 图片，这样暗部和亮部都会包含较丰富的细节。

在 HDR 拍摄中，通常使用三张曝光不同的照片来合成最终的高动态范围图像：一张正常曝光、一张过曝和一张欠曝。具体来说，这三张照片的生成方式如下：

1. **正常曝光照片**

正常曝光照片是根据相机的自动曝光（AE）算法来确定的。相机会根据场景的测光信息，自动选择合适的快门速度、光圈大小和 ISO 设置，以生成一张整体亮度合适的照片。这张照片通常是用户在普通拍摄情况下得到的结果。

1. **欠曝光照片**

欠曝光照片通过降低相机的曝光量来生成。具体方法是缩短快门速度、缩小光圈或降低 ISO。欠曝光的目的在于保留亮部细节，例如避免天空或其他高亮度区域过曝。

1. **过曝照片**

过曝照片的生成与欠曝光相反，目的是使相机捕捉到更多的暗部细节。通过增加曝光量，使图像整体变亮，突出暗部区域。

生成方式：

- **增加曝光补偿值**：将曝光值提高1到2档（EV），让传感器接收到更多光线，从而使图像整体变亮。
- **降低快门速度**：相机降低快门速度，使得传感器接收光线的时间变长，从而使图像整体变亮。
- **增大光圈**：通过增大光圈大小（减小 f 值），让更多光线进入传感器。
- **提高 ISO**：增加感光度（ISO 值），提高传感器对光线的敏感度，使图像更亮。

**缺点**是拍摄时间较长，特别是过曝的照片，拍摄期间如果有运动的物体或者使用手持相机拍摄，容易出现多张照片无法对齐的现象。

https://zhuanlan.zhihu.com/p/99758095

https://zhuanlan.zhihu.com/p/150734784

![](https://img2023.cnblogs.com/blog/1099671/202306/1099671-20230616015827356-1436555841.png)

### **多帧同曝光 HDR: HDR+**

google对他们技术的介绍是这样的：一种图像处理流水线，它能够捕获、校准和合并一系列连拍来降低图像噪音并增加动态范围。

核心思路为捕获曝光不足的帧，对齐和合并这些帧以产生高比特深度的单个中间图像，并对该图像进行色调映射以产生高分辨率照片。

![](https://img2023.cnblogs.com/blog/1099671/202306/1099671-20230616015848006-1399579871.png)

没有采用多张不同曝光值的照片进行合成，它用的是多张相同曝光值的照片，并且快门速度和曝光量选择偏暗，就是说速度选择高，曝光量低。更快的快门速度带来更低的抖动模糊，而更低的曝光量能有效抑制过曝，也就是照片中的高光溢出，并且更低的iso带来更少的噪点。但是这两个选择都会带来一个问题，暗处曝光不足。

- 相同曝光的多张图片能让对齐过程更加健壮，并且设置较低的曝光参数来避免高光部分过曝。
- 从bayer raw frame而非由手机上的isp输出的demosaicked RGB frame开始处理，raw image的图像有更深的位宽并且可以自定义色调映射和空间去噪。
- 以FFT为基础的校准算法和一种2D/3D混合的维纳滤波器(Wiener filter)。

在选择曝光时间的时候，google刻意选择会欠曝的时间。另外，同样基于“克制”的出发点，算法选取一帧作为参考帧，同时选出其他可选帧中确信能与参考帧匹配的部分，再与参考帧进行合成。这种保守的合成也许会让最终结果中的一部分的噪声更多，但是这种现象很少见。

在校准合成之后，会先生成一帧中间帧，它有更高的动态范围，与输入帧相比噪点更低。这样一来，仅仅通过舍弃low-order bits就能得到高质量（albeit underexposed)图像。但是既然目标是得到自然的图像（即使是在高对比度的场景下），我们谨慎地牺牲了全局对比度而保存了局部对比度，并没有简单的增强阴影部分。这个过程叫做“HDR色调映射”（并不是什么新东西）

- **怎么解决暗处曝光不足？**
  
    HDR+ 的确是通过拍摄多张相同曝光值的照片来合成一张高质量的图像，并且为了避免高光部分过曝，通常会选择较高的快门速度和较低的曝光量。这样虽然可以保留亮部细节，但确实会导致暗部区域曝光不足的问题。HDR+ 通过以下几种方式来解决这一问题：
    
    ### 1. **多帧合成增强暗部细节**
    
    HDR+ 拍摄多帧图像，这些图像在捕捉时可能曝光较低，但通过多帧叠加合成的方式，可以有效提升暗部的信号强度。具体来说，在多张图像中，虽然每一张单独来看暗部可能曝光不足，但在多帧叠加后，噪声会被平均化，而信号（即真实的图像细节）会被累加，从而提升暗部的亮度和细节。
    
    **原理：**
    
    - 多帧叠加使得图像中同一位置的像素值相互累加，逐步提升暗部的亮度。
    - 通过智能算法区分图像中的噪声和有效信号，降低噪声同时提升细节，使得暗部细节更加清晰。
    
    ### 2. **局部对比度增强（Local Tone Mapping）**
    
    在图像合成的过程中，HDR+ 使用局部对比度增强技术来调整不同区域的亮度和对比度，尤其是暗部区域。通过局部调整，将暗部区域的亮度提升至合适的水平，同时保持亮部区域的细节不丢失。
    
    **原理：**
    
    - 分析图像的局部区域，对不同亮度级别的区域分别处理。
    - 在暗部区域应用更高的增益（增亮效果），同时控制亮部区域的增益，避免过曝。
    
    ### 3. **计算摄影和机器学习**
    
    HDR+ 在图像处理过程中结合了计算摄影技术和机器学习模型。这些模型能够智能分析场景中的光线条件，并根据内容选择最佳的处理方式。对于暗部区域，HDR+ 可能会利用训练模型来预测并恢复这些区域的细节，从而避免出现完全曝光不足的情况。
    
    **原理：**
    
    - 通过预训练模型，智能分析图像中的亮部和暗部区域，并对暗部进行定向增强。
    - 使用场景识别技术，根据不同场景调整处理参数，使暗部和亮部的曝光均衡。
    
    ### 4. **动态范围扩展**
    
    HDR+ 的算法不仅仅依赖于亮度的叠加，还使用了扩展动态范围的技术，即在合成过程中，进一步提升图像的动态范围，使得暗部细节可以在不失真的情况下得到提升。
    
    **原理：**
    
    - 在图像合成过程中，根据场景的光线情况，动态调整图像的亮度范围。
    - 通过扩展图像的动态范围，保持亮部和暗部的细节，使得整个图像的亮度分布更加自然。
    
    ### 5. **暗部降噪和细节恢复**
    
    HDR+ 在提升暗部细节的过程中，同时使用了降噪算法。降噪算法能够有效减少暗部区域的噪声，使得暗部的细节更加清晰可见。通过这种方式，虽然曝光较低，但仍能得到较为纯净的暗部图像。
    
    **原理：**
    
    - 在暗部区域应用自适应降噪算法，降低由于低曝光带来的噪声。
    - 在降噪的同时，利用细节增强算法恢复暗部区域的图像细节。
    
    ### 总结
    
    虽然 HDR+ 采用了较低的曝光以保留亮部细节，但通过多帧合成、局部对比度增强、计算摄影、动态范围扩展和降噪等技术，HDR+ 能够有效提升暗部的细节和亮度，避免出现暗部曝光不足的问题。通过这些技术，HDR+ 能够在保持亮部细节的同时，呈现出更好的暗部表现，生成更高质量的图像。
    

流水线如下：首先从stream of raw frame中获得burst of raw frames，这个过车涉及到曝光以及曝光参数控制，然后在全分辨率下进行校准和融合，之后是白平衡，去马赛克，去噪，接着是局部色调映射，然后去雾，全局色调映射，最后是锐化，色调和饱和度的调节。

### 色调映射

Even though we have recovered the relative brightness information using multiple images, we now have the challenge of saving this information as a 24-bit image for display purposes.

尽管我们已经使用多个图像恢复了相对亮度信息，但我们现在面临的挑战是将此信息保存为24位图像以供显示。

The process of converting a High Dynamic Range (HDR) image to an 8-bit per channel image while preserving as much detail as possible is called **Tone mapping.**

色调映射可以分为全局色调映射和局部色调映射：

- 全局色调映射
    - 对图像中的所有像素使用同样的映射函数
    - 相同的输入像素值会被确定地映射到一个相同的输出像素值
    - 可以用查表法加速，适合摄像机类的实时视频应用
- 局部色调映射
    - 对空间位置不同的像素采用不同的映射函数
    - 对于同一个输入像素值，由于其空间位置不同或者其周围像素值不同，映射的输出像素值也不同

https://blog.csdn.net/qq_37363005/article/details/103593541

---

夜景模式综合了多帧合成和AI的技术，手机在你开启夜景模式并按下快门后，会自动判定当前的环境，并以不同的曝光数值同时拍下多张照片。随后AI会对图像的质量进行选帧，去除模糊、过曝或者死黑的区域并合成为一张照片。紧接着手机也会对图像进行一系列降噪、锐化、调整曝光等操作，以提高成片的质量。

https://zhuanlan.zhihu.com/p/386158280

## 降噪

“噪声”就是在信号采集过程中引入的一种普遍失真。降低噪声强度可以使图像主观效果更好。另外，在图像、视频压缩时也不必浪费码率在编码噪声上。

噪声的来源有多种，其中最主要的部分来自光子散粒噪声。上图描述的是从感光元器件收集到光子，一直到生成数字图像的过程。首先感光元器件把光子转换成电子，电子形成电压，电压放大后量化，最终形成数字图像。光子散粒噪声在感光元器件接收光子时就发生了。

因此，我们可以通过提高单位像素面积内接受到的光子个数来降低人眼感知到的噪声强度。不论是硬件降噪或是软件降噪，很多降噪方法都利用到了这个原理。

---

降噪算法可以在不同的图像处理阶段和数据格式中实现，包括RAW域、RGB域和YUV域。每种域的降噪算法都有其特定的优势和应用场景。以下是在这三个主要图像域中实现降噪算法的一些详细信息：

#### 1. **RAW域降噪**

**原理与优势：**

- **RAW域**：这是图像捕捉链中最早的阶段，图像数据还未经过白平衡、色彩校正或其他图像处理步骤。RAW数据直接来自图像传感器，通常以线性响应记录光的强度。
- **优势**：在RAW域进行降噪的主要优势是可以访问到图像数据的最初和最完整形态，此时数据未被压缩或转换，保留了最多的信息。这使得降噪算法能够更有效地区分噪声和有用信号，尤其是在处理传感器噪声（如散粒噪声和读取噪声）时。

**应用**：

- 高ISO拍摄时，RAW域降噪尤为重要，因为这时噪声最为明显。
- 专业级相机和高端智能手机中常用，以提高图像质量。

#### 2. **RGB域降噪**

**原理与优势：**

- **RGB域**：此时图像已经转换为RGB格式，通常是在RAW转换过程中进行白平衡和色彩校正后的结果。
- **优势**：在RGB域降噪便于应用基于色彩信息的降噪技术，因为此时图像的色彩和亮度信息已经被处理和调整，算法可以利用这些信息来进一步改进降噪效果。

**应用**：

- 通常在图像处理管线中稍后阶段进行，适用于已经进行了初步处理的图像数据。
- 适合处理那些在色彩转换和校正后更明显的色彩噪声。

#### 3. **YUV域降噪**

**原理与优势：**

- **YUV域**：在这一域中，图像被分为亮度分量（Y）和色度分量（U和V）。这种格式常用于视频传输和压缩。
- **优势**：由于色彩信息（U和V）与亮度信息（Y）分离，可以针对不同的分量应用不同强度的降噪，通常亮度分量包含更多的细节信息，而色度分量则可以接受更强的降噪处理。

**应用**：

- 常用于视频和图像压缩前的处理，以优化压缩效率和视觉质量。
- 由于其在压缩前处理的特性，广泛用于流媒体和广播行业。

#### 总结

不同的降噪算法适用于不同的图像处理阶段和数据格式。RAW域降噪能够处理最原始的图像数据，适合高质量图像处理；RGB域降噪便于利用色彩信息进行细致的降噪处理；而YUV域降噪则优化了亮度和色彩分量的处理，特别适合视频和压缩应用。选择哪种降噪技术取决于具体的应用需求、图像质量要求和处理资源。

---

![image.png](/assets/images/android-camera/camera-algorithms/image.png)

**数码相机成像时的噪声模型与标定**https://zhuanlan.zhihu.com/p/397873289

### 单帧降噪

单帧降噪算法可以做很多种不同的分类，比如线性/非线性、空域/频域，频域又包括小波变换域、傅里叶变换域或其他变换域。

往往需要在速度和效果之间权衡

Non-Local Means顾名思义，这是一种非局部平均算法。何为局部平均滤波算法呢？那是在一个目标像素周围区域平滑取均值的方法，所以非局部均值滤波就意味着它使用图像中的所有像素，这些像素根据某种相似度进行加权平均。滤波后图像清晰度高，而且不丢失细节。

出发点应该是借鉴了越多幅图像加权的效果越好的现象，那么在同一幅图像中对具有相同性质的区域进行分类并加权平均得到去噪后的图片，应该降噪效果也会越好。该算法使用自然图像中普遍存在的冗余信息来去噪声。与双线性滤波、中值滤波等利用图像局部信息来滤波不同，它利用了整幅图像进行去噪。即以图像块为单位在图像中寻找相似区域，再对这些区域取平均，较好地滤除图像中的高斯噪声。

![image.png](/assets/images/android-camera/camera-algorithms/image-1.png)

https://www.cnblogs.com/yymn/articles/12724671.html

https://zhuanlan.zhihu.com/p/667051784

https://www.cnblogs.com/luo-peng/p/4785922.html

### 多帧降噪

多帧降噪的主要步骤有两个：对齐和融合。

如果对四张图像做对齐融合，则相当于每个像素多采集到了四倍数量的光子，换算成信噪比有6分贝的提升，这对于图像质量来说是一个非常可观的数字。

1. **NLmeans：**nlmeans引申到多帧场景，多帧场景中，在不同帧的类似像素点位置，总是能够找到类似的像素点，因此，通过这些像素点的加权平均，我们也可以得到较为干净的图像。
   
    这样的操作可以避免运动估计处理，运动估计不仅费时，而且如果存在误差，对于结果则会适得其反。而查找类似像素点的方式并不会严格要求图像对齐。
    
2. **HDR+的多帧降噪实现在Raw域**，由于Raw域的图像没有经过后续非线性图像处理模块的影响，所以可以在Raw域中对图像中的噪声进行比较精确地建模，有了噪声建模的结果之后就可以对噪声强度做估计并运用到多帧降噪算法中去。
   
    https://zhuanlan.zhihu.com/p/336002385
    
    https://zhuanlan.zhihu.com/p/589233275
    
3. **Removing Multi-frame Gaussian Noise by Combining Patch-based Filters with Optical Flow 基于块滤波器和光流法的多帧高斯噪声去除，**Patch-based approaches such as 3D block matching (BM3D) and non-local Bayes (NLB) are widely accepted filters for removing Gaussian noise from single-frame images. https://arxiv.org/abs/2001.08058
   
    点击链接查看和 Kimi 智能助手的对话 [https://kimi.moonshot.cn/share/cr83a39hd0na5b4nsvh0](https://kimi.moonshot.cn/share/cr83a39hd0na5b4nsvh0)
    
    光流法https://blog.csdn.net/qq_41368247/article/details/82562165
    

在降噪处理后，图像可能会出现过度平滑的现象，因此需要对图像的细节进行增强，使图像看起来更加清晰和锐利。

## 背景虚化 blurred background

图像深度信息获取 → 图像背景虚化

https://cloud.tencent.com/developer/article/1871367

### 光学原理 optical principle

The optical principle of achieving a blurred background in portrait photography primarily revolves around the concept of **depth of field**(DoF). This is influenced by several key factors:

1. **Aperture Setting**: A **wider** aperture (lower f-number) allows more light to enter the lens and creates a **shallower** depth of field, which results in a more pronounced background blur. However, even a narrower aperture can achieve a similar effect if combined with other techniques.
2. **Focal Length of the Lens**: Longer focal lengths tend to compress the background and enhance the blur effect. For example, using a 150mm lens will produce a softer background compared to a 35mm lens at the same aperture and distance
3. **Distance Between Subject and Background**: Increasing the distance between the subject and the background will enhance the blur effect. The greater this distance, the more pronounced the separation between the subject and the background becomes
4. **Distance Between Camera and Subject**: Getting closer to the subject while keeping the background at a distance also contributes to a shallower depth of field, enhancing the blur

These factors work together to create the desirable "bokeh" effect, which is the aesthetic quality of the blur in the out-of-focus areas of an image.

事实上，从物体上一点发出的光线通过透镜后，最终在像平面上会变成一个二维投影，如果镜头是圆形的，那么这个投影就是圆形的。我们通常称这个投影为模糊环（Circle of Confusion)。当恰好对焦时，模糊环的直径为0，那么我们看到的就是一个点。而当像平面不动，物点逐渐偏离可以恰好对焦的平面时，我们就会观察到像点逐渐变成了一个圆（或者其他镜头形状的投影）。注意这里由于人眼视力和感知的因素，当模糊环直径还没有超过某个阈值时，我们还认为投影是一个点，即成像还是清晰的，只有超过这个阈值时，成像才会变得模糊。这个阈值，我们称之为允许的最大模糊环，即Permissible Circle of Confusion。

当对被摄主体平面调焦时，因为容许弥散圆的存在，在一定离焦范围内，成像仍然清晰，这个范围称为焦深。调整成像面和镜头距离，使成像面处于焦深内，物体可以清晰成像的过程，称为对焦。

类似地，对被摄物体而言，位于调焦物平面前后的能相对清晰成像的景物间纵深距离称为景深。

#### 如何获取场景中任意一点和镜头之间的距离？

事实上，当采用两个相机时，空间中的P、Q两点，以及两个相机和对应的投影点之间的几何关系就会满足所谓的“对极几何约束”：

![image.png](/assets/images/android-camera/camera-algorithms/image-2.png)

这样，求取空间点和相机之间距离的关键就变成了求取其投影点视差了。而整个图像上所有点的视差构成了一幅图像，这个图像叫做视差图。而通过校正后的一对图像获取到视差图的过程，叫做立体匹配。

一个单目景深（深度学习）的项目https://github.com/foamliu/Deep-Image-Matting

### 数字处理技术 - 模糊算法

https://github.com/QianMo/Game-Programmer-Study-Notes/blob/master/Content/高品质后处理：十种图像模糊算法的总结与实现/README.md

#### 高斯模糊

https://en.wikipedia.org/wiki/Gaussian_blur

https://mp.weixin.qq.com/s/D53C1KtY2slLBX28Ggmx2g

高斯模糊（Gaussian Blur）是一种常见的图像处理算法，用于平滑图像、减少噪声和实现模糊效果。它通过使用高斯函数对图像进行卷积来实现模糊效果。在背景虚化中，高斯模糊被应用于背景区域，使其失去细节，从而突出前景主体。以下是高斯模糊的数学原理。

![](https://upload.wikimedia.org/wikipedia/commons/thumb/6/62/Cappadocia_Gaussian_Blur.svg/250px-Cappadocia_Gaussian_Blur.svg.png)

**高斯函数**

高斯模糊的核心是高斯函数，它是一种正态分布函数，用于定义模糊的权重分布。二维高斯函数的表达式为：

$$
G(x, y) = \frac{1}{2\pi\sigma^2} \exp\left(-\frac{x^2 + y^2}{2\sigma^2}\right)
$$

其中：

- \(x\) 和 \(y\) 是像素点的坐标距离（相对于模糊中心）。
- \(\sigma\) 是高斯分布的标准差，控制模糊的程度。值越大，模糊程度越强。

**高斯卷积核**

高斯模糊通过对图像应用一个称为高斯卷积核的滤波器来实现。高斯卷积核是根据上述高斯函数生成的一个矩阵，其中每个元素代表该位置的权重。

例如，3x3 的高斯卷积核可能如下：

$$
\begin{bmatrix}
0.0625 & 0.125 & 0.0625 \\
0.125 & 0.25 & 0.125 \\
0.0625 & 0.125 & 0.0625
\end{bmatrix}
$$

**卷积操作**

高斯模糊通过将卷积核应用到图像上进行卷积操作来实现模糊。具体来说，每个像素的值由其邻域内像素值的加权平均值决定，权重由高斯卷积核给出：

$$
I'(x, y) = \sum_{i=-k}^{k} \sum_{j=-k}^{j} I(x+i, y+j) \cdot G(i, j)
$$

其中：

- \(I(x, y)\) 是原始图像的像素值。
- \(I'(x, y)\) 是模糊后的图像的像素值。
- \(G(i, j)\) 是高斯卷积核中的权重。

#### 效果

通过这种卷积操作，图像的边缘和细节被平滑，导致图像变得模糊。模糊的程度取决于高斯卷积核的大小和 \(\sigma\) 的值。

#### 半场香槟

整个图像渲染得到人像模式下背景虚化的图像的过程是

**标定 → 立体校正 → 立体匹配 → COC计算 → 图像渲染**

矫正和匹配前面都说过了。标定就是为矫正做准备，把对应点转换到同一行的过程，需要很多参数，包括

1. 两个相机的空间几何关系：两个相机的三维旋转角度，以及两个相机的空间平移。
2. 为符合图像没有畸变的要求：需要两个相机的焦距、图像中心、畸变参数等用于去畸变，以及将两个相机转换到同一个坐标系中。

#### 图像渲染

即便是有了准确的COC图，在图像渲染部分还会遇到很多困难。比如：

- 速度，如何在很短的时间(高端手机几十毫秒)内完成现在动辄上千万像素的图像
- 美观性，如何尽量逼近真实单反所拍摄的图像

![](https://ask.qcloudimg.com/http-save/yehe-7204525/a067f63bc1aa2901c5e162b2306c6701.png)

为了提升美观性，通常是通过CoC的尺寸生成足够逼真的模糊核，然后对图像进行卷积操作来得到。最基础的做法是用纯圆形的模糊核：

## 美颜

http://www.dwenzhao.cn/profession/imgia/imgperson.html

https://tensors.space/2019/06/美颜算法/

人脸和肤色检测 → 平滑与磨皮 → 祛斑、美白 → 瘦脸 → 五官

人像美颜技术的核心就是以图像保边滤波算法为基础的磨皮算法。其中保边滤波：表面滤波、双边滤波、导向滤波等。

https://zh.wikipedia.org/zh-cn/雙邊濾波器

双边滤波bilateral filter是一种非线性滤波器，和传统的影像平滑化算法不同，双边滤波器除了使用像素之间几何上的靠近程度之外，还多考虑了[像素](https://zh.wikipedia.org/wiki/%E5%83%8F%E7%B4%A0)之间的[光度](https://zh.wikipedia.org/wiki/%E5%85%89%E5%BA%A6)/[色彩](https://zh.wikipedia.org/wiki/%E8%89%B2%E5%BD%A9)差异，使得双边滤波器能够有效的将影像上的[噪声](https://zh.wikipedia.org/wiki/%E9%9B%9C%E8%A8%8A)去除，同时保存影像上的边缘资讯。实现了对非平坦区域的细节保留。
https://www.cnblogs.com/pingwen/p/12539722.html

值域是不同像素值的相似度，空域是像素之间的距离。

## 附录

### H.265和H.264的区别

- **压缩效率与码率（存储与带宽）**：这是两者最直观的区别。H.265 的压缩算法进行了深度优化，在保持与 H.264 完全相同画质的前提下，H.265 编码的视频文件体积和所需的网络带宽通常能减少 **40%~50%** 左右。
- **编码单元大小（宏块划分）**：H.264 中的每个宏块（Macroblock）大小固定为 16x16 像素；而 H.265 引入了更灵活的编码树单元（CTU），尺寸可以从 8x8 动态自适应扩展到最大 64x64 像素。这使得 H.265 在处理大面积单一背景（用大块）和复杂细节（用小块）时更加高效。
- **帧内预测方向**：H.265 的帧内预测模式支持高达 **33 种方向**，而 H.264 仅支持 8 种方向。这意味着 H.265 提供了更精细的运动补偿处理和矢量预测方法。
- **算力消耗与复杂度**：H.265 极高的压缩率本质上是靠“算力换空间”得来的。它的算法复杂度远高于 H.264，在没有专属硬件加速的情况下，H.265 软编码消耗的计算资源大约是 H.264 的 3 倍，软解码大约是 1.5 倍。
- **兼容性与应用场景**：H.264 发布时间早，生态极其成熟，几乎所有老旧设备和全平台都支持其编解码；H.265 则是目前 4K/8K 超高清视频、高清直播的主流首选。虽然现代芯片（如你的 AI 板卡）普遍带有 H.265 硬编解码模块，但在部分低端旧机型、特定 Web 端或小程序中，H.265 的兼容性仍不如 H.264。

总的来说，如果你对系统的网络带宽和存储空间要求极高，且硬件算力充足，首选 H.265；如果你需要系统兼顾最广泛的设备兼容性，H.264 依然是最稳妥的选择。

