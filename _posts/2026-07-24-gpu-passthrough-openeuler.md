---
title: "openEuler GPU Passthrough 操作记录"
date: 2026-07-24
categories: [virtualization, passthrough]
tags: ["openEuler", "GPU passthrough", "VFIO", "KVM", "virt-manager"]
---

目前平台:
Guest 系统
`https://mirrors.yacloud.net/openeuler/openEuler-22.03-LTS-SP4/ISO/aarch64/openEuler-22.03-LTS-SP4-aarch64-dvd.iso`
```shell
[qy@localhost build]$ cat /etc/os-release
NAME="openEuler"
VERSION="22.03 (LTS-SP4)"
ID="openEuler"
VERSION_ID="22.03"
PRETTY_NAME="openEuler 22.03 (LTS-SP4)"
ANSI_COLOR="0;31"

[qy@localhost build]$ uname -a
Linux localhost.localdomain 5.10.0-273.0.0.176.oe2203sp4.aarch64 #1 SMP Wed Jul 16 15:24:56 CST 2025 aarch64 aarch64 aarch64 GNU/Linux
[qy@localhost build]$
```
## 操作流程
客户机中安装spice/vnc、libvirt、virt-manager、qemu、qemu-kvm相关软件
virt-manager安装虚拟机时使用安装前自定义配置，添加vnc/spice，显卡virto，keyboard，数位板。用来保证鼠标键盘等正常使用。（暂时不要添加PCI设备）
然后在虚拟机中执行下列命令。其中ukui是个桌面，对于无桌面环境系统可能需要
```shell
sudo dnf install -y meson ninja-build pkgconfig gcc-c++ git gdm mesa-demos vim spice-server spice-vdagent tigervnc-server virt-viewer tigervnc libpciaccess systemd-libs libdrm libglvnd  glibc glibc-devel gnome-shell gdm gnome-terminal nautilus dkms elfutils-libelf-devel kernel-devel kernel-headers ukui
sudo dnf install -y glmarks # 可能需要源码编译
sudo dnf install -y xorg-x11-drv-fbdev xorg-x11-drv-vesa xorg-x11-drv-modesetting xorg-x11-server-Xorg
```

1. 查看默认启动目标：
   ```shell
    systemctl get-default
   ```
    输出如为 graphical.target，表示已配置图形目标；否则安装桌面环境并运行以下命令设置：
   ```shell
    sudo systemctl set-default graphical.target
   ```
   
2. 连接虚拟机桌面

    在客户端上：
    📍 使用 VNC 客户端：

    在远程机器上运行：
    ```shell
    vncviewer IP地址:1
    ```
    或使用 TigerVNC、RealVNC、Remmina 等客户端。
    📍 使用 SPICE 客户端：
    virt-viewer    连接虚拟机：
    ```shell
    remote-viewer spice://<虚拟机IP>:5901
    ```
    
3. 虚拟机安装显卡驱动

4. 开启IOMMU
    * bios开启IOMMU
    * ls -la /dev/kvm #存在设备表示支持硬件虚拟化
    * 关闭SeLinux
    * 对于host 欧拉系统，需要打一个补丁（该 GPU 直通场景需要适配 openEuler 5.10 系列内核）
        ```shell
        rpm -qa --last | grep kernel # 查看所有内核包安装时间
        ```
        查看系统自动保留的多个旧内核版，根据时间也可查看内核安装是否安装成功
        ```shell
        ls /boot/vmlinuz-*    -la # 核心镜像
        ls /boot/initramfs-*  -la # 初始化镜像
        ls /lib/modules/      -la # 模块目录
        ```
        手动额外备份当前内核，其中版本号根据当前内核改变（uname -a）
        ```shell
        sudo cp /boot/vmlinuz-5.10.0-270.0.0.173.oe2203sp4.aarch64 /boot/vmlinuz-270-backup
        sudo cp /boot/initramfs-5.10.0-270.0.0.173.oe2203sp4.aarch64.img /boot/initramfs-270-backup.img
        sudo cp /boot/System.map-5.10.0-270.0.0.173.oe2203sp4.aarch64 /boot/System.map-270-backup
        sudo cp -r /lib/modules/5.10.0-270.0.0.173.oe2203sp4.aarch64 /lib/modules/270-backup
        ```
        
    * 内核参数中启动IOMMU(具体根据cpu来)
        ```shell
        vim /etc/default/grub
        ```
        然后更新内核启动参数，重启

    通过dmesg | grep -i smmu和dmesg | grep -i iommu验证
    ```shell
    [zl@localhost ~]$ dmesg | grep -i iommu
    [    0.337318] iommu: Default domain type: Translated
    [zl@localhost ~]$ dmesg | grep -i smmu
    [    0.000000] Kernel command line: BOOT_IMAGE=/vmlinuz-5.10.0-269.0.0.172.oe2203sp4.aarch64 root=/dev/mapper/openeuler-root ro rd.lvm.lv=openeuler/root rd.lvm.lv=openeuler/swap video=VGA-1:640x480-32@60me cgroup_disable=files apparmor=0 crashkernel=1024M,high smmu.bypassdev=0x1000:0x17 smmu.bypassdev=0x1000:0x15 arm64.nopauth rhgb quiet console=tty0
    ```
    
1. 查看桌面和推流服务（如使用spice）
    ```shell
    systemctl status lightdm.service # 查看桌面状态
    systemctl status spice-streaming-agent.service # 查看推流状态（命令根据安装的显卡驱动可能有变化）
    ```
    
2.  获取设备所在组id使用
    ```shell
    [root]$ for d in /sys/kernel/iommu_groups/*/devices/*; do n=${d#*/iommu_groups/*}; n=${n%%/*}; printf 'IOMMU Group %s ' "$n"; lspci -nns "${d##*/}"; done; #通过这个脚本可以获取设备所在组id:

    03:00.0 VGA compatible controller [0300]: GPU device [<vendor-id>:<device-id>] (rev 01)
    ```
    这个命令在host中与virt-manager识别到的一致03:00.0，在guest中会有变化
    或使用
    ```shell
    lspci | grep GPU_VENDOR
    ```
    更新脚本可能有问题，无法自动生成conf，可手动修改脚本为显卡ID。否则需要手动修改10-mwv207.conf
    
    ```
    cat /usr/local/bin/replace-jmgpu-xorg.sh
    ```

*截图已移除：原图包含厂商名或设备 ID。*

    手动编辑/usr/share/X11/xorg.conf.d/10-mwv207.conf，将设备组id转化为busid，从HEX转为OCT，写入以下内容，关键是Section后Device。
    
    ```bash
    Section "Device"
        Identifier "JMgpu"
        Driver "mwv207"
        BusID "3:0:0"
    EndSection
    ```
    
7. 虚拟机关机，在virt-manager中添加pci设备，可以自动识别到host的显卡

2. 添加显卡后查看服务状态，并运行齿轮
    ```shell
    lspci | grep GPU_VENDOR
    cat /usr/share/X11/xorg.conf.d/10-mwv207.conf
    sudo rm -rf /tmp/.X0-lock /tmp/.X11-unix/X0
    sudo systemctl daemon-reexec
    sudo systemctl daemon-reload
    sudo systemctl restart lightdm.service
    sudo systemctl status lightdm.service
    ```
    
3. 桌面服务没问题后查看显卡状态(桌面可能不显示，该现象与当前图形驱动栈有关，可能需要切换到配套驱动)
    ```shell
    sudo dmesg | grep jmgpu
    ```

*截图已移除：原图包含厂商名或设备 ID。*

    ```shell
    cat  /proc/gpuinfo_0
    ```

*截图已移除：原图包含厂商名或设备 ID。*

    ```shell
    export DISPLAY=:0
    vblank_mode=0 glxgears # 查看分数(运行齿轮)
    ```
    ```shell
    glmark2 # 查看分数
    ```

*截图已移除：原图包含厂商名或设备 ID。*

    ```shell
    cat /var/log/Xorg.0.log | grep EE
    ```
    
    ```shell
    [qy@localhost ~]$ modinfo  jmgpu
    filename:       /lib/modules/5.10.0-273.0.0.176.oe2203sp4.aarch64/updates/dkms/jmgpu.ko.xz
    version:        1.5.1
    import_ns:      VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver
    license:        Dual MIT/GPL
    description:    GPU Graphics Driver
    license:        GPL
    description:    GPU HD Driver
    srcversion:     159B29A0782797F1F0DFDC4
    alias:          pci:v000010EEd00008019sv*sd*bc*sc*i*
    alias:          pci:v000010EEd00008018sv*sd*bc*sc*i*
    alias:          pci:v0000<vendor-id>d0000<device-id-alt>sv*sd*bc*sc*i*
    alias:          pci:v0000<vendor-id>d0000<device-id>sv*sd*bc*sc*i*
    alias:          pci:v0000<vendor-id>d000<device-id-alt>sv*sd*bc*sc*i*
    alias:          pci:v0000<vendor-id>d000<device-id-alt>sv*sd*bc*sc*i*
    alias:          pci:v0000<vendor-id>d000<device-id-alt>sv*sd*bc*sc*i*
    alias:          pci:v0000<vendor-id>d000<device-id-alt>sv*sd*bc*sc*i*
    alias:          pci:v0000<vendor-id>d000<device-id-alt>sv*sd*bc*sc*i*
    alias:          pci:v0000<vendor-id>d000<device-id-alt>sv*sd*bc*sc*i*
    alias:          pci:v0000<vendor-id>d000<device-id-alt>sv*sd*bc*sc*i*
    alias:          pci:v0000<vendor-id>d000<device-id-alt>sv*sd*bc*sc*i*
    alias:          pci:v0000<vendor-id>d000<device-id-alt>sv*sd*bc*sc*i*
    alias:          pci:v0000<vendor-id>d000<device-id-alt>sv*sd*bc*sc*i*
    alias:          pci:v0000<vendor-id>d000<device-id-alt>sv*sd*bc*sc*i*
    depends:
    name:           jmgpu
    vermagic:       5.10.0-273.0.0.176.oe2203sp4.aarch64 SMP mod_unload modversions aarch64
    parm:           force_virt_type:Force to apply virtualization method, 0 for auto-detect (int)
    parm:           virt_mode:virt mode to show the env, 0 for PHYSICAL, 1 for PT, 2 for MDEV (int)
    parm:           disable4K60:Disable 4K@60Hz if set to 1 (uint)
    parm:           vga_load_detect:Enable vga load detect if set to 1 (uint)
    parm:           hdmi_disable533250:Disable hdmi 533250 mode if set to 1 (uint)
    parm:           hdmi_enable_prefer_mode_4K30:Disable hdmi prefer 4K30 mode if set to 0 (uint)
    parm:           index:Index value for GPU HDMI Audio controller. (int)
    parm:           id:ID string for GPU HDMI Audio controller. (charp)
    parm:           enable_audio:int
    parm:           hpd_poll_delay:hotplug poll delay in ms, default 2000ms (int)
    parm:           skip_thaw:skip the display device during the thaw if set to 1, skip by default (int)
    parm:           compute_only:not register kms if set to 1, register by default (int)
    parm:           simple_map:uint
    parm:           map_shift:uint
    parm:           cfg_file:use /lib/firmware/'cfg_file' if available, default to 'mwv207config.bin' if file not found. (charp)
    parm:           vram_space_limit:set limit for vram space, default 0, no limit (ulong)
    parm:           enable_share_to_ft:Enable sharing pixmap to FT, default<0>, enable with<1>. (int)
    parm:           major:major device number for jmgpu device (uint)
    parm:           fastClear:Disable fast clear if set it to 0, enabled by default (int)
    parm:           compression:Disable compression if set it to 0, enabled by default (int)
    parm:           powerManagement:Disable auto power saving if set it to 0, enabled by default (int)
    parm:           userClusterMasks:Array of user defined per-core cluster enable mask (array of uint)
    parm:           smallBatch:Enable/disable GPU small batch feature, disable by default (int)
    parm:           isrPoll:Bits isr polling for per-core, default 0'1b means disable, 1'1b means auto enable isr polling mode (uint)
    parm:           stuckDump:Level of stuck dump content. (uint)
    parm:           recovery:Recover GPU from stuck (1: Enable, 0: Disable) (uint)
    parm:           j2dmode:command mode of j2d, 0 - cmdport, 1 - waitlink (int)
    parm:           fb_no_cursor:hide cursor when in fb mode, 0 - show(default), 1 - hide  (int)
    parm:           dvfs_enable:core dvfs select,0x0 - close dvfs, 0x1 - 2d dvfs open (int)
    parm:           dvfs_period:dvfs period time(ms) (int)
    parm:           enable_wc:enable write-combine if possible, default 1 (int)
    parm:           order_vram_access:keep cpu access to vram aligned, default 0 (int)
    [qy@localhost ~]$
    ```
    
10. 对于显示器,可能需要强制传入参数

    ```shell
    [root@localhost 1.5.1]# cat /etc/modprobe.d/jmgpu.conf
    options jmgpu force_virt_type=0
    [root@localhost 1.5.1]#
    ```

11. 运行齿轮结果正常渲染，可以正常显示jepg图片及H.256格式视频

*截图已移除：原图包含厂商名或设备 ID。*

    视频格式根据ffmpeg测试可知为H.256

    ```
    $ cat VID20250718213403_info.txt
    ffprobe version 8.0-full_build-www.gyan.dev Copyright (c) 2007-2025 the FFmpeg developers
      built with gcc 15.2.0 (Rev8, Built by MSYS2 project)
      configuration: --enable-gpl --enable-version3 --enable-static --disable-w32threads --disable-autodetect --enable-fontconfig --enable-iconv --enable-gnutls --enable-lcms2 --enable-libxml2 --enable-gmp --enable-bzlib --enable-lzma --enable-libsnappy --enable-zlib --enable-librist --enable-libsrt --enable-libssh --enable-libzmq --enable-avisynth --enable-libbluray --enable-libcaca --enable-libdvdnav --enable-libdvdread --enable-sdl2 --enable-libaribb24 --enable-libaribcaption --enable-libdav1d --enable-libdavs2 --enable-libopenjpeg --enable-libquirc --enable-libuavs3d --enable-libxevd --enable-libzvbi --enable-liboapv --enable-libqrencode --enable-librav1e --enable-libsvtav1 --enable-libvvenc --enable-libwebp --enable-libx264 --enable-libx265 --enable-libxavs2 --enable-libxeve --enable-libxvid --enable-libaom --enable-libjxl --enable-libvpx --enable-mediafoundation --enable-libass --enable-frei0r --enable-libfreetype --enable-libfribidi --enable-libharfbuzz --enable-liblensfun --enable-libvidstab --enable-libvmaf --enable-libzimg --enable-amf --enable-cuda-llvm --enable-cuvid --enable-dxva2 --enable-d3d11va --enable-d3d12va --enable-ffnvcodec --enable-libvpl --enable-nvdec --enable-nvenc --enable-vaapi --enable-libshaderc --enable-vulkan --enable-libplacebo --enable-opencl --enable-libcdio --enable-openal --enable-libgme --enable-libmodplug --enable-libopenmpt --enable-libopencore-amrwb --enable-libmp3lame --enable-libshine --enable-libtheora --enable-libtwolame --enable-libvo-amrwbenc --enable-libcodec2 --enable-libilbc --enable-libgsm --enable-liblc3 --enable-libopencore-amrnb --enable-libopus --enable-libspeex --enable-libvorbis --enable-ladspa --enable-libbs2b --enable-libflite --enable-libmysofa --enable-librubberband --enable-libsoxr --enable-chromaprint --enable-whisper
      libavutil      60.  8.100 / 60.  8.100
      libavcodec     62. 11.100 / 62. 11.100
      libavformat    62.  3.100 / 62.  3.100
      libavdevice    62.  1.100 / 62.  1.100
      libavfilter    11.  4.100 / 11.  4.100
      libswscale      9.  1.100 /  9.  1.100
      libswresample   6.  1.100 /  6.  1.100
    Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'C:\Users\qiyan\Downloads\tmp\VID20250718213403_.mp4':
      Metadata:
        major_brand     : isom
        minor_version   : 512
        compatible_brands: isomiso2mp41
        encoder         : Lavf62.3.100
      Duration: 00:00:19.76, start: 0.000000, bitrate: 3311 kb/s
      Stream #0:0[0x1](eng): Video: hevc (Main) (hev1 / 0x31766568), yuv420p(tv, bt709, progressive), 1920x1080, 3172 kb/s, 29.92 fps, 29.92 tbr, 11488 tbn (default)
        Metadata:
          handler_name    : VideoHandle
          vendor_id       : [0][0][0][0]
          encoder         : Lavc62.11.100 libx265
      Stream #0:1[0x2](eng): Audio: aac (LC) (mp4a / 0x6134706D), 48000 Hz, stereo, fltp, 128 kb/s (default)
        Metadata:
          handler_name    : SoundHandle
          vendor_id       : [0][0][0][0]
    
    ```

*截图已移除：原图包含厂商名或设备 ID。*

# 附录

## 编译qemu4.1.0可能用到的
```shell

../configure \
  --target-list=aarch64-softmmu,arm-softmmu \
  --enable-kvm \
  --enable-spice \
  --enable-gtk \
  --enable-curses \
  --enable-vnc \
  --prefix=/opt/qemu-4.1.0

```
## virt-manager相关命令
```shell
# virsh list --all
# ./kvm0.sh start       # 启动虚拟机
# ./kvm0.sh console     # 连接串口终端
# ./kvm0.sh shutdown    # 正常关机
# ./kvm0.sh destroy     # 强制关机
# ./kvm0.sh status      # 查看状态
# ./kvm0.sh undefine    # 删除虚拟机定义
#!/bin/bash

case "$1" in
  start)
    virsh start kvm0
    ;;
  console)
    virsh console kvm0
    ;;
  shutdown)
    virsh shutdown kvm0
    ;;
  destroy)
    virsh destroy kvm0
    ;;
  status)
    virsh list --all | grep kvm0
    ;;
  undefine)
    virsh undefine kvm0
    ;;
  *)
    echo "Usage: $0 {start|console|shutdown|destroy|status|undefine}"
    ;;
esac

```

## 编译glmark2
```abap
git clone https://gitclone.com/github.com/glmark2/glmark2.git
cd glmark2 && mkdir -p build && meson setup build -Dflavors=x11-gl
cd build
ninja
sudo ninja install
```

## OpenEuler host补丁应用流程（包括内核本体变动）：

1. 打 patch：

   ```bash
   patch -p1 < ../xxx.patch
   ```

2. 编译整个内核：

   ```bash
   make -j$(nproc)
   ```
   如果想只编译模块   `make -j$(nproc) modules`
    安装模块：

    ```bash
    sudo make modules_install
    sudo depmod -a
    ```

4. 安装内核本体：

   ```bash
   sudo make install
   ```

5. 更新 grub 并重启：

   ```bash
   sudo grub2-mkconfig -o /boot/grub2/grub.cfg # 其实应该会自动更新
   sudo reboot
   ```

重启后确认内核是否是你新编译的版本

```bash
uname -a
```

你应该看到：

```
Linux localhost 5.10.0-270.0.0.173.oe2203sp4.aarch64+custom #1 SMP ...
```

如果你看到的是旧的内核版本，就说明没成功启动新的内核。


总结

| 操作                | 是否完成 |
| ----------------- | ---- |
| 打了 patch          | ✅    |
| 编译模块并安装           | ✅    |
| **编译并安装 vmlinuz** | ❌    |
| grub 更新并重启        | ❌    |
| 重启后查看 `uname -a`  | ❌    |

---
## 遇到的错误

1. 错误1

*截图已移除：原图包含厂商名或设备 ID。*

安装驱动的时候遇到内核头文件缺失的问题，因此lightdm服务启动失败
当前内核

```shell
[qy@localhost build]$ uname -r
5.10.0-273.0.0.176.oe2203sp4.aarch64
[qy@localhost build]$
```
但是系统中没有安装这个版本的内核开发头文件（kernel-devel）
```shell
ls /usr/src/kernels/
```
因此 dkms 无法构建模块。虽然 symlink /lib/modules/5.10.0-216.../build 存在，但它指向的是一个不存在的目录，所以出错。
执行

```shell
sudo dnf install -y "kernel-devel-$(uname -r)"
```
可以确定一下这个目录
```shell
ls -l /lib/modules/$(uname -r)/build
```

确保内核头文件存在后重新安装驱动或
```shell
sudo dkms add -m mwv207 -v 1.4.0
sudo dkms build -m mwv207 -v 1.4.0
sudo dkms install -m mwv207 -v 1.4.0
```
然后重启lightdm服务，成功。可以测试显卡跑分。

2. 错误2

   脚本执行失败

   通过 `ll` 命令明明看到了 `passthrough.sh` 文件就在那里，并且已经成功赋予了执行权限（`-rwxrwxr-x`），但运行的时候系统偏偏说“No such file or directory（没有那个文件或目录）”。

   可能是因为**找不到脚本第一行指定的解释器**。首行以及换行符格式如下：

   ```
   #!/bin/bash\r\n
   ```

   注意隐藏在行尾的 `\r\n`。这说明这个脚本很可能是在 Windows 系统中创建或编辑过的，使用的是 DOS/Windows 的换行符格式（CRLF）。而 Linux 系统严格要求使用 Unix 格式的换行符（LF）。

   当 Linux 尝试读取这个文件时，它连同回车符 `\r` 一起读了进去，导致它实际上是在尝试寻找并运行一个名叫 `bash\r` 的程序。由于 `/bin/` 目录下只有 `bash` 而没有 `bash\r`，所以系统报错提示找不到文件。

   ### 解决方法

   解决这个问题非常简单，只需要将文件转换回 Unix 的换行格式即可。你可以使用以下任意一种方法：

   **方法一：使用 `sed` 命令（无需安装，最快捷）**

   直接在终端执行这行命令，它会自动将文件里多余的 `\r` 字符删除：

   Bash

   ```
   sed -i 's/\r$//' passthrough.sh
   ```

   **方法二：使用 `dos2unix` 工具**

   如果你系统里装了这个工具，直接运行：

   Bash

   ```
   dos2unix passthrough.sh
   ```

   *(如果没装，可以通过 `sudo apt install dos2unix` 安装)*

   **方法三：使用 `vim` 转换**

   1. 用 vim 打开它：`vim passthrough.sh`
   2. 在英文模式下输入冒号进入命令模式，输入：`:set ff=unix` 并回车。
   3. 保存并退出：`:wq`

   ------

   执行完转换后，再次运行 `sudo ./passthrough.sh` 就可以正常启动了。

3. 错误3

   如果运行直接崩溃，可能内存不足，需减小脚本中的内存分配

   ```bash
   free -h
   ```

4. 错误4

   BdsDxe: failed to load Boot0001 "UEFI QEMU QEMU HARDDISK " from PciRoot(0x0)/Pci(0x1,0x2)/Pci(0x0,0x0)/Scsi(0x0,0x0): Not Found

   Start PXE over IPv4

   

----

## host启动虚拟机-gpu直通 aarch64

> sudo ./passthrough.sh
>
> 这是原始脚本，变量名实际没有用到，下面附上了优化脚本
>
> 所有直通脚本，都是建立在VM_IMAGE已经安装好对应系统的基础上，从硬盘启动，如没有安装系统镜像则需优先纯净安装再直通设备。暂时删除qemu启动参数中涉及PCI_ID的那行，然后使用
>
>   -cdrom /home/zl/passthrough/lubuntu-20.04.5-desktop-amd64.iso
>
> 先进行安装完毕并能正常启动后，再把 PCIe 设备挂上去。

```shell
#!/bin/bash

# =================================================================
# 配置区域
# =================================================================
PCI_ID="0000:01:00.0"       # 显卡的 PCI 地址
VENDOR_ID="<vendor-id>"            # GPU 厂商 Vendor ID
DEVICE_ID="<device-id>"            # GPU 厂商 Device ID
VM_IMAGE="/data/libvirt-images/openeuler22.03-3-1-clone-1.qcow2"
EFI_FLASH="/usr/share/edk2/aarch64/QEMU_EFI-pflash.raw"
VARS_FLASH="/var/lib/libvirt/qemu/nvram/gpuPass-ok_VARS.fd"
VNC_PORT="127.0.0.1:2"

# =================================================================
# 辅助函数
# =================================================================
log() { echo -e "\e[1;32m[INFO]\e[0m $1"; }
error() { echo -e "\e[1;31m[ERROR]\e[0m $1"; exit 1; }

# 1. 检查权限
[[ $EUID -ne 0 ]] && error "请使用 sudo 运行此脚本"

# 2. 检查文件是否存在
[[ ! -f "$VM_IMAGE" ]] && error "虚拟机镜像不存在: $VM_IMAGE"
[[ ! -f "$EFI_FLASH" ]] && error "EFI 固件不存在: $EFI_FLASH"

# 3. 准备 VFIO 环境
log "正在配置 VFIO 环境..."
lspci -nnk -s $PCI_ID
modprobe vfio || error "无法加载 vfio 模块"
modprobe vfio_pci || error "无法加载 vfio_pci 模块"
modprobe vfio_iommu_type1 || error "无法加载 vfio_iommu_type1 模块"

# 4. 驱动状态检查与切换
# 提取当前驱动名称，兼容不同版本的 lspci 输出
CURRENT_DRIVER=$(lspci -nnk -s $PCI_ID | grep "Kernel driver in use" | sed 's/.*: //')

if [[ "$CURRENT_DRIVER" == "vfio-pci" ]]; then
    log "设备 $PCI_ID 已处于 vfio-pci 控制下，跳过绑定步骤。"
else
    log "设备当前驱动为 [$CURRENT_DRIVER]，正在强制切换至 vfio-pci..."
    
    # 写入 override
    echo "vfio-pci" > "/sys/bus/pci/devices/$PCI_ID/driver_override"
    
    # 解绑原驱动 (如果存在)
    if [[ -e "/sys/bus/pci/devices/$PCI_ID/driver" ]]; then
        echo "$PCI_ID" > "/sys/bus/pci/devices/$PCI_ID/driver/unbind"
    fi
    
    # 尝试绑定 (drivers_probe 会根据 driver_override 自动选择 vfio-pci)
    echo "$PCI_ID" > /sys/bus/pci/drivers_probe
    
    # 再次验证
    NEW_DRIVER=$(lspci -nnk -s $PCI_ID | grep "Kernel driver in use" | sed 's/.*: //')
    if [[ "$NEW_DRIVER" != "vfio-pci" ]]; then
        error "驱动切换失败！当前驱动为: $NEW_DRIVER"
	lspci -nnk -s $PCI_ID	
    fi
    log "驱动切换成功。"
fi

# 5. 检查 IOMMU Group
if [[ ! -L "/sys/bus/pci/devices/$PCI_ID/iommu_group" ]]; then
    error "设备 $PCI_ID 缺少 IOMMU 分组，请确认 BIOS 中已开启 VT-d/IOMMU"
fi

# --- TAP 网络接口处理逻辑 ---
log "正在初始化 TAP 网络接口 tap0..."

# 检查网桥是否存在，如果不存在则提示（或尝试创建）
if ! ip link show virbr0 >/dev/null 2>&1; then
    log "警告: 未发现 virbr0 网桥，尝试创建默认网桥..."
    sudo brctl addbr virbr0 || true
    sudo ip link set virbr0 up
    sudo ip addr add 192.168.122.1/24 dev virbr0 || true
fi

# 彻底清理旧的 tap0 (如果存在)
if ip link show tap0 >/dev/null 2>&1; then
    log "清理已存在的 tap0 接口..."
    sudo ip link set tap0 down 2>/dev/null
    sudo ip tuntap del dev tap0 mode tap 2>/dev/null
fi

# 创建新的 tap0
sudo ip tuntap add dev tap0 mode tap || error "无法创建 tap0 接口"
sudo ip link set tap0 master virbr0 || error "无法将 tap0 挂载到 virbr0"
sudo ip link set tap0 up || error "无法启动 tap0"

log "TAP 接口配置完成，已挂载至 virbr0"

# 6. 设置资源限制
ulimit -l unlimited
log "已设置内存锁定限制为 unlimited"

# 7. 启动 QEMU
log "正在启动 QEMU 虚拟机..."
qemu-system-aarch64 \
  -name gpuPass-clean-nodefaults \
  -machine virt-6.2,accel=kvm,gic-version=3 \
  -cpu host \
  -m 10G \
  -smp 16,sockets=16,cores=1,threads=1 \
  -overcommit mem-lock=off \
  \
  -no-user-config \
  -nodefaults \
  \
  -drive file=/usr/share/edk2/aarch64/QEMU_EFI-pflash.raw,if=pflash,format=raw,readonly=on \
  -drive file=/var/lib/libvirt/qemu/nvram/gpuPass-ok_VARS.fd,if=pflash,format=raw \
  \
  -device pcie-root-port,port=0x8,chassis=1,id=pci.1,bus=pcie.0,multifunction=on,addr=0x1 \
  -device pcie-root-port,port=0x9,chassis=2,id=pci.2,bus=pcie.0,addr=0x1.0x1 \
  -device pcie-root-port,port=0xa,chassis=3,id=pci.3,bus=pcie.0,addr=0x1.0x2 \
  -device pcie-root-port,port=0xb,chassis=4,id=pci.4,bus=pcie.0,addr=0x1.0x3 \
  -device pcie-root-port,port=0xc,chassis=5,id=pci.5,bus=pcie.0,addr=0x1.0x4 \
  -device pcie-root-port,port=0xd,chassis=6,id=pci.6,bus=pcie.0,addr=0x1.0x5 \
  \
  -netdev tap,id=net0,ifname=tap0,script=no,downscript=no \
  -device virtio-net-pci,netdev=net0,bus=pci.1,addr=0x0 \
  \
  -device qemu-xhci,p2=15,p3=15,id=usb,bus=pci.2,addr=0x0 \
  -device usb-kbd,id=input0,bus=usb.0,port=1 \
  -device usb-tablet,id=input1,bus=usb.0,port=2 \
  \
  -device virtio-scsi-pci,id=scsi0,bus=pci.3,addr=0x0 \
  -device scsi-hd,bus=scsi0.0,channel=0,scsi-id=0,lun=0,drive=disk0 \
  -drive file=/data/libvirt-images/openeuler22.03-3-1-clone-1.qcow2,if=none,id=disk0,format=qcow2 \
  \
  -device virtio-serial-pci,id=virtio-serial0,bus=pci.4,addr=0x0 \
  \
  -device virtio-gpu-pci,id=video0,max_outputs=1,bus=pci.5,addr=0x0 \
  -vnc 127.0.0.1:10 \
  \
  -device vfio-pci,host=0000:01:00.0,id=hostdev0,bus=pci.6,addr=0x0 \
  \
  -chardev stdio,id=charserial0 \
  -serial chardev:charserial0 \
  \
  -msg timestamp=on \
  -boot menu=on
```

```abap
613服务器上虚拟机密码 pl,okm123
```

直通gpu：

```bash
-machine virt-6.2,accel=kvm,gic-version=3 \
```

直通npu

```bash
-machine q35,accel=kvm \
```



要看到画面，首先使用

```
vncserver :{x}
# {x}为任意数字，不与宿主机vnc端口和命令行指定端口冲突即可
# vncserver为127.0.0.1或虚拟机ip
```

然后在宿主机vnc viwer连接{guest ip}{x}即可

gpuPass-ok_VARS.fd和QEMU_EFI-pflash.raw是针对 **AArch64 (ARM64)** 架构的虚拟机，这两个文件共同构成了虚拟机的 **固件（Firmware）层**，相当于物理机的 BIOS/UEFI。在大多数主流 Linux 发行版中，这些文件通过安装 **EDK2** 相关的软件包获得。在/usr/share/edk2/aarch64可以看到。或者可以通过libvirt创建。例如ubuntu用 QEMU 模拟/直通给一个 ARM 架构的 openEuler 虚拟机，需要安装 Ubuntu 下的 AArch64 EFI 固件包qemu-efi-aarch64、qemu-efi、ovmf

openeuler22.03-3-1-clone-1.qcow2是硬盘文件。

脚本的第 8 行还定义了 UEFI 变量文件的路径：`VARS_FLASH="/var/lib/libvirt/qemu/nvram/gpuPass-ok_VARS.fd"`。 如果这个脚本是你从别的机器上直接拷贝过来的，那么这个 `VARS_FLASH` 文件在你的当前宿主机上大概率也是不存在的。但是应该有类似的文件。

## 图片视频压缩解压缩

```shell
ffmpeg -i  ./1762911514810.jpeg  -q:v 10 tmp/test_compressed.jpg
ffmpeg -i tmp/test_compressed.jpg -q:v 2 tmp/test_decompressed.jpg
ffmpeg -i tmp/test_compressed.jpg tmp/restored.bmp
ffmpeg -i VID20250718213403_.mp4 -c:v libx265 -crf 28 -c:a aac -b:a 128k tmp/com.mp4
ffmpeg -i tmp/com.mp4 -crf 23 -c:a copy tmp/res.mp4
```

## aarch64直通脚本优化

```bash
#!/bin/bash

# =================================================================
# 配置区域
# =================================================================
PCI_ID="0000:01:00.0"       # 显卡的 PCI 地址
VM_IMAGE="/data/libvirt-images/openeuler22.03-3-1-clone-1.qcow2"
EFI_FLASH="/usr/share/edk2/aarch64/QEMU_EFI-pflash.raw"
VARS_FLASH="/var/lib/libvirt/qemu/nvram/gpuPass-ok_VARS.fd"
VNC_ADDR="127.0.0.1:10"     # VNC 监听地址与端口

# =================================================================
# 辅助函数
# =================================================================
log() { echo -e "\e[1;32m[INFO]\e[0m $1"; }
error() { echo -e "\e[1;31m[ERROR]\e[0m $1"; exit 1; }

# 1. 检查权限
[[ $EUID -ne 0 ]] && error "请使用 sudo 运行此脚本"

# 2. 检查文件是否存在
[[ ! -f "$VM_IMAGE" ]] && error "虚拟机镜像不存在: $VM_IMAGE"
[[ ! -f "$EFI_FLASH" ]] && error "EFI 固件不存在: $EFI_FLASH"
[[ ! -f "$VARS_FLASH" ]] && error "UEFI 变量文件不存在: $VARS_FLASH"

# 3. 准备 VFIO 环境
log "正在配置 VFIO 环境..."
lspci -nnk -s "$PCI_ID"
modprobe vfio || error "无法加载 vfio 模块"
modprobe vfio_pci || error "无法加载 vfio_pci 模块"
modprobe vfio_iommu_type1 || error "无法加载 vfio_iommu_type1 模块"

# 4. 驱动状态检查与切换
# 提取当前驱动名称，兼容不同版本的 lspci 输出
CURRENT_DRIVER=$(lspci -nnk -s "$PCI_ID" | grep "Kernel driver in use" | sed 's/.*: //')

if [[ "$CURRENT_DRIVER" == "vfio-pci" ]]; then
    log "设备 $PCI_ID 已处于 vfio-pci 控制下，跳过绑定步骤。"
else
    log "设备当前驱动为 [$CURRENT_DRIVER]，正在强制切换至 vfio-pci..."
    
    # 写入 override
    echo "vfio-pci" > "/sys/bus/pci/devices/$PCI_ID/driver_override"
    
    # 解绑原驱动 (如果存在)
    if [[ -e "/sys/bus/pci/devices/$PCI_ID/driver" ]]; then
        echo "$PCI_ID" > "/sys/bus/pci/devices/$PCI_ID/driver/unbind"
    fi
    
    # 尝试绑定 (drivers_probe 会根据 driver_override 自动选择 vfio-pci)
    echo "$PCI_ID" > /sys/bus/pci/drivers_probe
    
    # 再次验证
    NEW_DRIVER=$(lspci -nnk -s "$PCI_ID" | grep "Kernel driver in use" | sed 's/.*: //')
    if [[ "$NEW_DRIVER" != "vfio-pci" ]]; then
        error "驱动切换失败！当前驱动为: $NEW_DRIVER"
        lspci -nnk -s "$PCI_ID"	
    fi
    log "驱动切换成功。"
fi

# 5. 检查 IOMMU Group
if [[ ! -L "/sys/bus/pci/devices/$PCI_ID/iommu_group" ]]; then
    error "设备 $PCI_ID 缺少 IOMMU 分组，请确认 BIOS 中已开启 VT-d/IOMMU"
fi

# --- TAP 网络接口处理逻辑 ---
log "正在初始化 TAP 网络接口 tap0..."

# 检查网桥是否存在，如果不存在则提示（或尝试创建）
if ! ip link show virbr0 >/dev/null 2>&1; then
    log "警告: 未发现 virbr0 网桥，尝试创建默认网桥..."
    brctl addbr virbr0 || true
    ip link set virbr0 up
    ip addr add 192.168.122.1/24 dev virbr0 || true
fi

# 彻底清理旧的 tap0 (如果存在)
if ip link show tap0 >/dev/null 2>&1; then
    log "清理已存在的 tap0 接口..."
    ip link set tap0 down 2>/dev/null
    ip tuntap del dev tap0 mode tap 2>/dev/null
fi

# 创建新的 tap0
ip tuntap add dev tap0 mode tap || error "无法创建 tap0 接口"
ip link set tap0 master virbr0 || error "无法将 tap0 挂载到 virbr0"
ip link set tap0 up || error "无法启动 tap0"

log "TAP 接口配置完成，已挂载至 virbr0"

# 6. 设置资源限制
ulimit -l unlimited
log "已设置内存锁定限制为 unlimited"

# 7. 启动 QEMU
log "正在启动 QEMU 虚拟机..."
qemu-system-aarch64 \
  -name gpuPass-clean-nodefaults \
  -machine virt-6.2,accel=kvm,gic-version=3 \
  -cpu host \
  -m 10G \
  -smp 16,sockets=16,cores=1,threads=1 \
  -overcommit mem-lock=off \
  \
  -no-user-config \
  -nodefaults \
  \
  -drive file="${EFI_FLASH}",if=pflash,format=raw,readonly=on \
  -drive file="${VARS_FLASH}",if=pflash,format=raw \
  \
  -device pcie-root-port,port=0x8,chassis=1,id=pci.1,bus=pcie.0,multifunction=on,addr=0x1 \
  -device pcie-root-port,port=0x9,chassis=2,id=pci.2,bus=pcie.0,addr=0x1.0x1 \
  -device pcie-root-port,port=0xa,chassis=3,id=pci.3,bus=pcie.0,addr=0x1.0x2 \
  -device pcie-root-port,port=0xb,chassis=4,id=pci.4,bus=pcie.0,addr=0x1.0x3 \
  -device pcie-root-port,port=0xc,chassis=5,id=pci.5,bus=pcie.0,addr=0x1.0x4 \
  -device pcie-root-port,port=0xd,chassis=6,id=pci.6,bus=pcie.0,addr=0x1.0x5 \
  \
  -netdev tap,id=net0,ifname=tap0,script=no,downscript=no \
  -device virtio-net-pci,netdev=net0,bus=pci.1,addr=0x0 \
  \
  -device qemu-xhci,p2=15,p3=15,id=usb,bus=pci.2,addr=0x0 \
  -device usb-kbd,id=input0,bus=usb.0,port=1 \
  -device usb-tablet,id=input1,bus=usb.0,port=2 \
  \
  -device virtio-scsi-pci,id=scsi0,bus=pci.3,addr=0x0 \
  -device scsi-hd,bus=scsi0.0,channel=0,scsi-id=0,lun=0,drive=disk0 \
  -drive file="${VM_IMAGE}",if=none,id=disk0,format=qcow2 \
  \
  -device virtio-serial-pci,id=virtio-serial0,bus=pci.4,addr=0x0 \
  \
  -device virtio-gpu-pci,id=video0,max_outputs=1,bus=pci.5,addr=0x0 \
  -vnc "${VNC_ADDR}" \
  \
  -device vfio-pci,host="${PCI_ID}",id=hostdev0,bus=pci.6,addr=0x0 \
  \
  -chardev stdio,id=charserial0 \
  -serial chardev:charserial0 \
  \
  -msg timestamp=on \
  -boot menu=on
```

## X86直通脚本

```bash
#!/bin/bash

# =================================================================
# 配置区域
# =================================================================
PCI_ID="0000:01:00.0"       # 显卡的 PCI 地址
VM_IMAGE="/var/lib/libvirt/images/lubuntu_disk.qcow2"
VNC_PORT="127.0.0.1:2"      # VNC 监听地址 (对应端口 5902)

# =================================================================
# 辅助函数
# =================================================================
log() { echo -e "\e[1;32m[INFO]\e[0m $1"; }
error() { echo -e "\e[1;31m[ERROR]\e[0m $1"; exit 1; }

# 1. 检查权限
[[ $EUID -ne 0 ]] && error "请使用 sudo 运行此脚本"

# 2. 检查文件是否存在 (移除了对 EFI 固件的检查)
[[ ! -f "$VM_IMAGE" ]] && error "虚拟机镜像不存在: $VM_IMAGE"

# 3. 准备 VFIO 环境
log "正在配置 VFIO 环境..."
modprobe vfio || error "无法加载 vfio 模块"
modprobe vfio_pci || error "无法加载 vfio_pci 模块"
modprobe vfio_iommu_type1 || error "无法加载 vfio_iommu_type1 模块"

# 4. 驱动状态检查与切换
CURRENT_DRIVER=$(lspci -nnk -s "$PCI_ID" | grep "Kernel driver in use" | sed 's/.*: //')

if [[ "$CURRENT_DRIVER" == "vfio-pci" ]]; then
    log "设备 $PCI_ID 已处于 vfio-pci 控制下，跳过绑定步骤。"
else
    log "设备当前驱动为 [$CURRENT_DRIVER]，正在强制切换至 vfio-pci..."
    echo "vfio-pci" > "/sys/bus/pci/devices/$PCI_ID/driver_override"
    if [[ -e "/sys/bus/pci/devices/$PCI_ID/driver" ]]; then
        echo "$PCI_ID" > "/sys/bus/pci/devices/$PCI_ID/driver/unbind"
    fi
    echo "$PCI_ID" > /sys/bus/pci/drivers_probe
    NEW_DRIVER=$(lspci -nnk -s "$PCI_ID" | grep "Kernel driver in use" | sed 's/.*: //')
    if [[ "$NEW_DRIVER" != "vfio-pci" ]]; then
        error "驱动切换失败！当前驱动为: $NEW_DRIVER"
    fi
    log "驱动切换成功。"
fi

# 5. 检查 IOMMU Group
if [[ ! -L "/sys/bus/pci/devices/$PCI_ID/iommu_group" ]]; then
    error "设备 $PCI_ID 缺少 IOMMU 分组，请确认 BIOS 中已开启 VT-d/IOMMU"
fi

# --- TAP 网络接口处理逻辑 ---
log "正在初始化 TAP 网络接口 tap0..."
if ! ip link show virbr0 >/dev/null 2>&1; then
    log "警告: 未发现 virbr0 网桥，尝试创建默认网桥..."
    brctl addbr virbr0 || true
    ip link set virbr0 up
    ip addr add 192.168.122.1/24 dev virbr0 || true
fi

if ip link show tap0 >/dev/null 2>&1; then
    log "清理已存在的 tap0 接口..."
    ip link set tap0 down 2>/dev/null
    ip tuntap del dev tap0 mode tap 2>/dev/null
fi

ip tuntap add dev tap0 mode tap || error "无法创建 tap0 接口"
ip link set tap0 master virbr0 || error "无法将 tap0 挂载到 virbr0"
ip link set tap0 up || error "无法启动 tap0"

# 为宿主机添加板卡相同网段 (NPU需要。如果你的物理网卡不是 enp4s0，请在此修改)
ip addr add 192.168.6.100/24 dev enp4s0 2>/dev/null || true
log "TAP 接口配置完成，已挂载至 virbr0"

# 6. 设置资源限制
ulimit -l unlimited
log "已设置内存锁定限制为 unlimited"

# 7. 启动 QEMU (移除了 pflash，直接从 qcow2 启动)
log "正在使用传统 BIOS 模式启动 QEMU 虚拟机..."
qemu-system-x86_64 \
  -name lubuntu-passthrough \
  -machine q35,accel=kvm \
  -cpu host \
  -m 4G \
  -smp 4 \
  -overcommit mem-lock=off \
  -no-user-config \
  -nodefaults \
  \
  -device pcie-root-port,port=0x8,chassis=1,id=pci.1,bus=pcie.0,multifunction=on,addr=0x2 \
  -device pcie-root-port,port=0x9,chassis=2,id=pci.2,bus=pcie.0,addr=0x2.0x1 \
  -device pcie-root-port,port=0xa,chassis=3,id=pci.3,bus=pcie.0,addr=0x2.0x2 \
  -device pcie-root-port,port=0xb,chassis=4,id=pci.4,bus=pcie.0,addr=0x2.0x3 \
  \
  -netdev tap,id=net0,ifname=tap0,script=no,downscript=no \
  -device virtio-net-pci,netdev=net0,bus=pci.1,addr=0x0 \
  \
  -device qemu-xhci,p2=15,p3=15,id=usb,bus=pci.2,addr=0x0 \
  -device usb-tablet,id=input0,bus=usb.0,port=1 \
  -device usb-kbd,id=input1,bus=usb.0,port=2 \
  \
  -drive file="${VM_IMAGE}",format=qcow2,if=virtio,id=disk0 \
  -boot c,menu=on \
  \
  -device virtio-vga,id=video0,max_outputs=1,bus=pcie.0,addr=0x1 \
  -vnc "${VNC_PORT}" \
  \
  -device vfio-pci,host="${PCI_ID}",id=hostdev0,bus=pci.3,addr=0x0 \
  \
  -chardev stdio,id=charserial0 \
  -serial chardev:charserial0 \
  -msg timestamp=on

log "虚拟机已关闭。"

```

## -cdrom可能的问题参考

```
  -chardev stdio,id=charserial0 \
  -serial chardev:charserial0 \
  \
  -msg timestamp=on \
  -cdrom /home/zl/passthrough/lubuntu-20.04.5-desktop-amd64.iso \
  -boot d,menu=on
```

**一个潜在问题：** 如之前加了 `-nodefaults` 参数，QEMU 会关闭所有的默认设备，包括 IDE 控制器。有时候简单的 `-cdrom` 在有 `-nodefaults` 的情况下会挂载失败。此时可尝试

```bash
  -device ide-cd,drive=cdrom0,bootindex=1 \
  -drive file=/home/zl/passthrough/lubuntu-20.04.5-desktop-amd64.iso,media=cdrom,if=none,id=cdrom0 \
  -boot menu=on \
  -msg timestamp=on
```

或

```bash
  -drive file="${VM_IMAGE}",format=qcow2,if=virtio,id=disk0 \
  -cdrom /home/zl/passthrough/lubuntu-20.04.5-desktop-amd64.iso \
  -boot d
```

## openEuler 内核补丁分析

补丁文件：[`0001-KVM-arm64-Allow-the-VM-to-select-DEVICE_-and-NORMAL_(1).patch`](/assets/data/gpu-passthrough-openeuler/0001-KVM-arm64-Allow-the-VM-to-select-DEVICE_-and-NORMAL_1.patch)

这个补丁面向 arm64 KVM 的 Stage-2 页表映射。默认情况下，KVM 在处理 VFIO PCI 设备的 MMIO 区域时，会把 device memory 映射成 `DEVICE_nGnRE`。这类属性适合普通设备寄存器访问，但某些 GPU 直通场景可能需要把部分非缓存内存按 `NORMAL_NC` 处理，否则 guest 侧驱动访问 BAR、framebuffer 或相关 MMIO 区域时可能出现功能异常。

补丁做了四件关键修改。第一，在 `arch/arm64/include/asm/kvm_pgtable.h` 中新增 `KVM_PGTABLE_PROT_NORMAL_NC`，让 KVM Stage-2 映射层能够表达 Normal Non-Cacheable 类型。第二，在 `arch/arm64/include/asm/memory.h` 中增加 `MT_S2_NORMAL_NC` 和 `MT_S2_FWB_NORMAL_NC`，补齐 arm64 Stage-2 内存属性编码。第三，在 `arch/arm64/kvm/hyp/pgtable.c` 中调整 `stage2_map_set_prot_attr()`，让 Stage-2 页表能在 `DEVICE_nGnRE`、`NORMAL_NC` 和普通 `NORMAL` 之间选择，并拒绝 `DEVICE` 与 `NORMAL_NC` 同时出现，也拒绝这两类映射带执行权限。第四，在 `drivers/vfio/pci/vfio_pci.c` 中给 VFIO PCI mmap 出来的 VMA 加上 `VM_ALLOW_ANY_UNCACHED`，再由 `arch/arm64/kvm/mmu.c` 在处理 fault 时读取这个标志：如果该 VMA 来自允许 uncached 类型的 VFIO 区域，则把原本的 device 映射改成 `KVM_PGTABLE_PROT_NORMAL_NC`。

对这次 GPU passthrough 来说，补丁的意义是让 guest 可以在 arm64 KVM 下使用更适合该设备访问模式的 Stage-2 内存属性。它不是通用性能优化，也不是 VFIO 基础配置替代项；IOMMU、VFIO 绑定、libvirt/QEMU 设备直通、guest 驱动和 Xorg 配置仍然都需要正确配置。这个补丁属于内核侧兼容性改动，建议只应用在已经验证需要 `NORMAL_NC` 映射的 openEuler 内核版本上，并保留原内核和 initramfs 备份，便于启动失败时回退。
