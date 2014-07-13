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
kernel_start_sector equ 50              ;内核在硬盘中的起始逻辑扇区号
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

    ;mov eax,cs     ;ax or eax?
    ;mov ds,eax     ;会引发异常处理，为什么？
                    ;懂了，因为eax是一个代码段(cs)的选择子，不能用作数据段选择子    
                    ;使用0-4G内存数据段来访问
    mov eax,0x08    ;0-4G内存段
    mov ds,eax
    mov ebx,0x7c00+hello_str
    call putstr
    hlt

;putstr函数，打印一个字符串，以0为结束符
;参数：
;   ds:ebx 要打印的字符串地址
;返回值：
;   无
putstr:
    pushad

.nextchar:
    mov cl,[ebx]
    cmp cl,0
    jz .exit
    call putchar
    inc ebx
    jmp .nextchar

.exit:
    popad
    ret

;putchar函数，打印单个字符
;参数： 
;   cl - 要打印的字符
;返回值：
;   无
putchar:
    pushad

    ;获取当前光标位置
    ;光标位置是一个16位的数值，需要分别获取其高8位与低8位
    ;获取光标位置的高8位
    ;   向显卡的索引寄存器0x3d4端口写入0x0e，从索引寄存器的0x3d5端口读8位数据，
    ;获取光标位置的低8位
    ;   向显卡的索引寄存器0x3d4端口写入0x0f，从索引寄存器的0x3d5端口读8位数据，
    mov dx,0x3d4
    mov al,0x0e
    out dx,al
    mov dx,0x3d5
    in  al,dx
    mov ah,al

    mov dx,0x3d4
    mov al,0x0f
    out dx,al
    mov dx,0x3d5
    in  al,dx       ;当前光标位置已保存到ax中
    mov bx,ax       ;ax将用于接下来的div运算

    ;打印字符cl，要特殊处理\r:0x0d,\n:0x0a

    ;处理\r（0x0d，回车，将光标位置移到当前行第一列）
    ;处理：
    ;   将光标位置 / 80 得到当前光标行号（每行80列）
    ;   当前光标行 * 80 为当前行首列位置，将该位置设为当前光标位置
    cmp cl,0x0d
    jnz .line_feed
    xor dx,dx
    mov bl,80
    div bl          ;div r/m16   dx:ax / r/m16 => ax ... dx
    mul bl          ;mul r/m16   ax * r/m16 => dx:ax
    mov bx,ax
    jmp .roll_screen

    ;处理\n（0x0a，换行，将光标位置移到当前列下一行）
    ;处理：
    ;   将光标位置 + 80 （每行80列）
.line_feed:
    cmp cl,0x0a
    jnz .normal_char
    add bx,80
    jmp .roll_screen

    ;打印普通字符并将光标移向下一个位置
    ;将光标位置*2得到当前光标的显存地址，往该地址写字符即可显示
    ;每个字符占两个字节，第一个字节用于存储字符ascii码，第二个字节用于控制字符属性
    ;|--------------------------------|
    ;|15               7 6 5 4 3 2 1 0|
    ;|--------------------------------|
    ;|    ascii 15:8   k r g b i r g b|
    ;                  \     / \     /
    ;                     bg      fg
    ;
    ; k : 0 - blink, 1 - no-blink

.normal_char:
    push es
    mov ax, 10000B  ;显存段 
    mov es,ax
    shl bx,1
    mov [es:bx],cl
    mov byte [es:bx+1],00000010B    ;00000010B - 黑底绿字
    shr bx,1
    pop es

    add bx,1        ;光标推后一个位置

    ;滚屏，每行字符往上移一行并清空最后一行
.roll_screen:
    cmp bx,2000     ;80*25=2000, 表示光标超出屏幕，需要滚屏
    jl  .set_cursor
    push ds
    push es
    mov ax,10000B   ;显存段
    mov ds,ax
    mov es,ax
    cld
    mov edi,0
    mov esi,80      ;80
    mov ecx,1920    ;2000-80
    rep movsw       ;每行字符往上移一行

    ;以黑底白字的空格符填充最后一行
    mov bx,3840     ;1920*2
    mov cx,80
.clr_char:
    mov word [es:edi],0x0720
    add edi,2
    loop .clr_char
    mov bx,1920

    pop es
    pop ds

    ;设置bx为下一光标位置
.set_cursor:
    mov dx,0x3d4
    mov al,0x0e
    out dx,al
    mov dx,0x3d5
    mov al,bh
    out dx,al

    mov dx,0x3d4
    mov al,0x0f
    out dx,al
    mov dx,0x3d5
    mov al,bl
    out dx,al

    popad
    ret

;-----------------------------------------------------------------
hello_str: 
    db  0x0a, 0x0d
    db  '---------------', 0x0a, 0x0d
    db  'hello, I am in 32bit protected mode', 0x0a, 0x0d
    db  '---------------', 0x0a, 0x0d
    db  0x0

pgdt    dw  0               ;GDT的界限
        dd  0x7e00          ;GDT的物理地址

times 510-($-$$)    db 0
                    db 0x55,0xaa

; vim: set syntax=nasm:                   
