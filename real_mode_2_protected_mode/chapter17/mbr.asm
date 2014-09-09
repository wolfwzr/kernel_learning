;mbr程序
;
;mbr程序的加载：
;   bios程序完成自身工作后将根据配置的启动介质顺序去找可启动块
;   （以0x55aa结尾的512个字节），硬盘上的这块区域对应为0面0道1扇区
;   （一个扇区512个字节），通常称做mbr，bios找到后将这512字节加载到
;   内存0x0:0x7c00处，然后执行指令：
;   jmp 0x0:0x7c00
;   至此，CPU控制权转移到了mbr程序里
;   注：bios工作在实模式下
; 
;mbr程序所做的事：
;   一句话说，就是加载内核程序并将控制权转交给内核程序，具体事宜如下：
;   1. 从实模式进入保护模式
;       1.1 为进入保护模式做准备
;           1.1.1 创建GDT并加载到GDTR中
;               1.1.1.1 0#号空描述符
;               1.1.1.2 内核代码段
;               1.1.1.3 内核栈段
;               1.1.1.4 内核数据段
;           1.1.2 打开A20地址线
;           1.1.3 关闭中断
;       1.2 设置PE位，进入保护模式
;       1.3 清流水线并串行化处理器
;   2. 加载内核程序并将CPU控制权转换给内核
;       1.1 加载内核程序到内存
;           1.1 内核程序位于硬盘指定扇区（宏core_start_sector中定义）
;           1.2 内核程序头部中包含了内核程序的字节数、执行入口、段的起始地址及长度
;           1.3 mbr读取指定扇区（即内核程序头部）到预置内存地址
;           1.4 mbr根据内核头部信息读取剩余的内核程序
;       1.2 mbr根据内核头部的段信息为内核段在GDT中添加段描述符
;       1.3 mbr根据内核头部的执行入口信息转入内核执行

;宏定义
kernel_start_sector equ 05              ;内核在硬盘中的起始逻辑扇区号
kernel_base_address equ 0x00040000      ;内核要加载到的内存起始地址

;    _______ __ 0xffffffff (4GB)
;   |       |
;   |       |
;   |       |
;   |       |
;   |       |
;   |       |
;   |       |
;   |       |
;   |       |
;   |       |
;   |       |
;   |       |
;   |_______|__ kernel 0x00040000
;   |       |
;   |       |
;   |       |
;   |       |
;   |       |-- 显存段描述符(base 0x000b8000, len 0x7fff)
;   |       |-- 栈段描述符(base 0x0000:7c00, len 0xffffe 4KB)
;   |       |-- mbr代码段描述符(0x0000:0x7c00, len 0x1ff)
;   |       |-- 0-4GB内存数据段描述符
;   |_______|-- 空描述符 _______ GDT 0x0000:0x7e00 
;   |       |\
;   |       | |
;   |       | |
;   |       | |-- 512 bytes (512 = 0x1ff + 1 = 0x200)
;   |       | |
;   |       | |
;   |_______|/__ mbr 0x0000:0x7c00
;   |       |\
;   |       | |
;   |       | |
;   |       | |
;   |       | |
;   |       | |-- stack
;   |       | |
;   |       | |
;   |       | |
;   |       | |
;   |_______|/__ 0x0


;当前在实模式下，为进入保护模式做准备

SECTION code vstart=0x7c00

mov ax,cs   ;bios执行jmp 0x0:0x7c00后到此，cs值应为0
mov ss,ax
mov sp,0x7c00

;实模式下以 段：偏移 方式访问内存，所以将GDT的物理地址转换成这种形式
xor edx,edx
mov eax,[cs:0x7c00+pgdt+0x2]
mov ebx,16
div ebx             ; div r32   edx:eax / r32 => eax ... edx
mov ds,eax
mov ebx,edx         ; GDT的物理地址被转换成了ds:ebx

;创建段描述符

;segment descriptor
;        <--------------------------------------------------------------^
;        |31      24|23 22  21 20  19       16|15 14  12 11 8|7        0|
;        |----------|-------------------------|--------------|----------^
;4-7byte:|Base 31:24|G  D/B L  AVL Limit 19:16|P  DPL S  Type|Base 23:16|
;        |----------|-------------------------|--------------|----------^
;0-3byte:|            Base 15:0               |        Limit 15:0       |
;        <---------------------------------------------------------------
;
; G    : granularity, 0 - byte, 1 - 4KB
; D/B  : 1 - 32bit operand/address, 0 - 16bit operand/address
; L    : 1 - 64bit code, 0 - 32/16bit code
; AVL  : Reserved, set 0
; P    : 1 - Present in memory, 0 - not Present in memory
; DPL  : descripter privilage level, 00->11
; S    : 0 - system segment, 1 - code or data segment
; Type : 0 E W A for data segment
;           E: extend-down
;           W: Writable
;           A: Accessed
;        1 C R A for code segment
;           C: confirming
;           R: readable
;           A: Accessed

;跳过#0空描述符，只需留下内存空间即可

;0-4G内存访问描述符
mov dword [ebx+0x08],0x0000ffff  ;Base:0x0, Limit:0xfffff
mov dword [ebx+0x0c],0x00cf9200  ;G=1,D=1,L=0,DPL=0,S=1,type=0010

;显存段描述符
mov dword [ebx+0x10],0x80007fff  ;Base:0x000b8000, Limit: 0x07fff (0x8000=8*4K=32K)
mov dword [ebx+0x14],0x0040920b  ;G=0,D=1,L=0,DPL=0,S=1,type=0010

;mbr进入保护模式后代码段的描述符
mov dword [ebx+0x18],0x7c0001ff  ;Base:0x00007c00, Limit: 0x001ff (512=0x200)
mov dword [ebx+0x1c],0x00409800  ;G=0,D=1,L=0,DPL=0,S=1,type=1000

;mbr进入保护模式后栈段的描述符
mov dword [ebx+0x20],0x7c007c00  ;Base: 0x00007c00, Limit:0x07c00(not 0xffffe?)
mov dword [ebx+0x24],0x00409600  ;G=0,B=1,L=0,DPL=0,S=1,type=0110, expand-down

;设置GDT的界限
mov word [cs:0x7c00+pgdt],39     ;(5*8-1)

;加载GDT
lgdt [cs:0x7c00+pgdt]

;打开A20地址线
;方法：将0x92端口（属于ICH控制器，8位宽）的bit1置1
in al,0x92
or al,00000010B
out 0x92,al

;屏蔽可屏蔽的中断
cli

;方法：将CR0寄存器的bit0(PE位)置为1
mov eax,cr0
or eax,0x1
mov cr0,eax

;已经进入了保护模式

;隐式设置cs并清空流水线

;Segment Selector
;   <------------------------------
;   |15                 3  2  1  0|
;   |-----------------------------|
;   |Index 15:3         |  TI RPL |
;   <------------------------------
; Index  : index in GDT/LDT
; TI     : 0 - GDT, 1 - LDT
; RPL    : Request Privilege Level

jmp 0x0018:flush    ;代码段位于GDT的第3个段(1 1000)

[bits 32]
flush:
    mov eax,0x20    ;保护模式下的栈段
    mov ss,eax
    xor esp,esp

    mov eax,0x08    ;0-4G内存段
    mov ds,eax

    mov eax,kernel_start_sector     ;读取内核程序头一个扇区
    mov edi,kernel_base_address
    mov ebx,edi
    call read_one_disk_sector

    ;内核程序头部结构：
    ;   内核程序字节数 32bit
    ;   内核例程段偏移 32bit
    ;   内核数据段偏移 32bit
    ;   内核代码段偏移 32bit
    ;   内核执行入口点之段内偏移 32bit
    ;   内核执行入口点之段选择子 16bit
     
    mov eax,[edi]   ;获取内核程序字节数
    mov edx,0
    mov ecx,512
    div ecx         ;将字节数转换为所占的扇区数
    or edx,edx      ;有余数则需再读一个扇区
    jz .continue
    inc eax
.continue:
    dec eax         ;减去已读的一个扇区

    or eax,eax      ;eax=0?
    jz .setup

    mov ecx,eax     ;读取剩余扇区
    mov eax,kernel_start_sector+1
.read_disk:
    call read_one_disk_sector
    inc eax
    loop .read_disk

.setup:
    mov esi,[0x7c00+pgdt+0x02]  ;gdt基地址 

    mov eax,[edi+0x04]          ;内核例程段
    mov ebx,[edi+0x08]          ;段尾-段首-1=段界限
    sub ebx,eax
    dec ebx
    add eax,edi
    mov ecx,0x00409800          ;属性
    call make_seg_descriptor
    mov [esi+0x28],eax
    mov [esi+0x2c],edx

    mov eax,[edi+0x08]          ;内核数据段
    mov ebx,[edi+0x0c]
    sub ebx,eax
    dec ebx
    add eax,edi
    mov ecx,0x00409200
    call make_seg_descriptor
    mov [esi+0x30],eax
    mov [esi+0x34],edx

    mov eax,[edi+0x0c]          ;内核代码段
    mov ebx,[edi+0x00]          ;程序总长度
    sub ebx,eax
    dec ebx
    add eax,edi
    mov ecx,0x00409800
    call make_seg_descriptor
    mov [esi+0x38],eax
    mov [esi+0x3c],edx

    add word [0x7c00+pgdt],24       ;更新GDT界限(3*8)
    lgdt [0x7c00+pgdt]

    jmp far [edi+0x10]          ;执行内核入口点

;从硬盘读取一个扇区（512字节）
;参数：
;   eax = 逻辑扇区号
;   ds:ebx = 目标缓冲区地址
;输出：
;   ebx += 512

;硬盘的读写单位是一个扇区
;主硬盘控制器被分配到了八个端口：0x1f0 - 0x0f7
;用LBA28方式读写硬盘:
;   1. 往0x1f2端口(8bit)写入要读取的扇区数目
;   2. 将28位起始LBA扇区号写入0x1f3,0x1f4,0x1f5,0x1f6端口(均为8big)
;           ---------------------------------------------------------------------    
;           31 30 29 28 27      23              16              7               0
;           ---------------------------------------------------------------------    
;           |       0x1f6       |     0x1f5     |     0x1f4     |     0x1f3     | 
;           ---------------------------------------------------------------------    
;            1  |  1 |   \                                                     /
;               |    |    `````````````````````````````````````````````````````
;               |    |                           LBA28
;       0: CHS _|    |_ 0: 主硬盘(master)
;       1: LBA          1: 从硬盘(slave)
;   3. 往0x1f7端口(8bit)写入0x20，请求硬盘读
;   4. 等待硬盘准备好读写, 0x1f7既是命令端口也是状态端口，此时为状态端口，含义如下：
;       -----------------------------
;       7   6   5   4   3   2   1   0
;       -----------------------------
;       |               |           |           
;       |_ 0: 硬盘闲    |           |_ 0: 前一个命令执行成功
;          1: 硬盘忙    |              1: 前一个命令执行失败，具体原因查看0x1f1
;                       |_ 0: 硬盘未准备好与主机交换数据
;                          1: 硬盘已准备好与主机交换数据
;       当bit7为0且bit3为1时，表示可以进行读硬盘了
;   5. 从0x1f0端口(16bit)读取数据

read_one_disk_sector:
    push eax
    push ecx
    push dx
    
    mov ecx,eax

    mov dx,0x1f2    ;1. 读取1个扇区
    mov al,1
    out dx,al

    inc dx          ;2.1 0x1f3 <= eax 7:0
    mov eax,ecx
    out dx,al

    inc dx          ;2.2 0x1f4 <= eax 15:8
    shr eax,8
    out dx,al

    inc dx          ;2.3 0x1f5 <= eax 23:16
    shr eax,8
    out dx,al

    inc dx          ;2.4 0x1f6 <= eax 27:24
    shr eax,8
    and al,0x0f
    or  al,0xe0     ;主硬盘+LBA方式
    out dx,al

    inc dx          ;3. 发送硬盘读命令
    mov al,0x20 
    out dx,al

.wait:              ;4. 等待硬盘准备好可读
    in  al,dx
    and al,0x88
    cmp al,0x08
    jnz .wait
    
    mov ecx,256     ;5. 读取硬盘
    mov dx,0x1f0
.rw:
    in  ax,dx 
    mov [ebx],ax
    add ebx,2
    loop .rw

    pop dx
    pop ecx
    pop eax

    ret

;构造段描述符
;参数：
;   eax = 段线性基地址（32位）
;   ebx = 段界限（20位）
;   ecx = 属性（各属性位都在原始位置，没用到的位为0）
;输出：
;   edx:eax 完整的段描述符
make_seg_descriptor:
    push ebx

    mov edx,eax
    rol eax,16      ;Set Base 15:0
    mov ax,bx       ;Set Limit 15:0

    and edx,0xffff0000
    rol edx,8
    bswap edx       ;Set Base 31:24 and Base 23:16

    and ebx,0x000f0000
    or  edx,ebx     ;Set Limit 19:16

    or  edx,ecx     ;Set Prop.

    pop ebx

    ret

pgdt    dw  0               ;GDT的界限
        dd  0x7e00          ;GDT的物理地址

times 510-($-$$)    db 0
                    db 0x55,0xaa

; vim: set syntax=nasm:
