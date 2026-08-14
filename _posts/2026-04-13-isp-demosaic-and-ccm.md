---
title: "ISP Demosaic and CCM"
date: 2026-04-13
categories: [android, camera]
tags: ["Android", "Camera", "ISP", "Demosaic", "CCM"]
---
我们平时所看到的彩色图像**每个像素由三个分量组成**，分别为红(R)绿(G)蓝(B)。

而CMOS传感器，其输出的数据格式为**每个像素点只有一个颜色分量**，称为Bayer数据。

这就需要我们对其进行进一步处理以恢复出缺失的两个分量，这一过程就叫做DDemosaicemosaic。

![](https://static.deepinout.com/ask-deepinout/2022/02/isp-demosaic-flow.jpg)

图像传感器对光谱的响应，在 RGB 各分量上与人眼对光谱的响应通常是有偏差的。

通常通过一个色彩校正矩阵**校正光谱响应的交叉效应和响应强度**，**使前端捕获的图片与人眼视觉在色彩上保持一致**。

CCM矩阵如下：

$$
\begin{pmatrix}
    1 & 0 & 0\\\\
    0 & 1 & 0\\\\
    0 & 0 & 1\\\\
\end{pmatrix}
$$

$$
\begin{pmatrix}
    R'\\\\
    G'\\\\
    B'\\\\
\end{pmatrix}
$$

![image.png](/assets/images/android-camera/isp-demosaic-and-ccm/image.png)

[摄像头ISP系统原理（上） - 吴建明wujianming - 博客园](https://www.cnblogs.com/wujianming-110117/p/12924949.html)

建议做CCM矩阵时选取不同的色温生成不同的CCM矩阵，然后根据实际色温值插值得到当前色温的CCM矩阵。

