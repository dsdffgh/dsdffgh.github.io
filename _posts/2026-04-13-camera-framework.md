---
title: "Camera Framework"
date: 2026-04-13
categories: [android, camera]
tags: ["Android", "Camera", "Camera Framework", "Camera2"]
---
谷歌提出Camera Api v2接口的同时，将其具体实现放入了Camera Framework中来完成，Framework内部负责解析来自App的请求，并且通过AIDL跨进程接口下发到Camera Service中进行处理，并且等待结果的回传。接下来我们首先以Camera Api v2接口为主简单讲解下其逻辑含义，然后详细梳理下Camera Framework对于它的实现，最后以一个简单App Demo为例，来介绍下如何使用该接口来控制整个相机体系。

