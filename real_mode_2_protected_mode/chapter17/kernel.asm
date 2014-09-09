;kernel.asm
;
;内核程序
;
;主要做的事：
;   1. 提供若干可供用户程序调用的例程
;   2. 加载及重定位用户程序并执行用户程序
;   3. 执行完用户程序后控制权回到内核
;
;要点技巧：
;   1. salt
;

;宏定义{{{
mem_0_4_gb_seg_sel      equ 0x08    ;0-4G内存数据段选择子
video_ram_seg_sel       equ 0x10    ;显存段选择子
kernel_stack_seg_sel    equ 0x20    ;内核栈段选择子
kernel_sysroute_seg_sel equ 0x28    ;内核系统例程段选择子
kernel_data_seg_sel     equ 0x30    ;内核数据段选择子
kernel_code_seg_sel     equ 0x38    ;内核代码段选择子

user_prog_start_sector  equ 40      ;用户程序起始逻辑扇区号

kernel_pde_phy_addr     equ 0x20000 ;内核页目录表物理地址
kernel_pte_phy_addr     equ 0x21000 ;内核0-1MB内存对应页表物理地址
;}}}

;内核头部格式{{{
kernel_len      dd  kernel_end
kenerl_section  dd  section.sys_routine.start 
                dd  section.kernel_data.start
                dd  section.kernel_code.start
kernel_entry    dd  start
                dw  kernel_code_seg_sel
;}}}

[bits 32]

;系统例程段{{{
SECTION sys_routine vstart=0

;putstr函数;{{{
;功能：
;   打印一个字符串，以0为结束符
;参数：
;   ds:ebx = 要打印的字符串地址
;输出：
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
    retf
;}}}
;putchar函数;{{{
;
;功能：
;   打印单个字符
;参数： 
;   cl = 要打印的字符
;输出：
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
    mov ax,video_ram_seg_sel    ;显存段 
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

    mov ax,video_ram_seg_sel    ;显存段
    mov ds,ax
    mov es,ax
    cld
    mov edi,0
    mov esi,160     ;一行80个字符*2字节每字符
    mov ecx,1920    ;2000-80
    rep movsw       ;每行字符往上移一行

    ;以黑底白字的空格符填充最后一行
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
;}}}
;read_one_disk_sector函数;{{{
;
;功能：
;   从硬盘读取一个扇区（512字节）
;参数：
;   eax = 逻辑扇区号
;   ds:ebx = 目标缓冲区地址
;输出：
;   ebx += 512

;如果读写硬盘;{{{
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
;}}}
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

    retf
;}}}
;make_seg_descriptor函数;{{{
;
;功能：
;   构造段描述符
;参数：
;   eax = 段线性基地址（32位）
;   ebx = 段界限（20位）
;   ecx = 属性（各属性位都在原始位置，没用到的位为0）
;输出：
;   edx:eax 完整的段描述符
make_seg_descriptor:
    mov edx,eax
    rol eax,16      ;Set Base 15:0
    mov ax,bx       ;Set Limit 15:0

    and edx,0xffff0000
    rol edx,8
    bswap edx       ;Set Base 31:24 and Base 23:16

    and ebx,0x000f0000
    or  edx,ebx     ;Set Limit 19:16

    or  edx,ecx     ;Set Prop.

    retf
;}}}
;make_call_gate_descriptor函数;{{{
;
;功能：
;   构造段描述符
;参数：
;   ax  = 目标代码段选择子
;   ebx = 段内偏移值
;   cx  = 属性（各属性位都在原始位置，没用到的位为0）
;输出：
;   edx:eax 完整的段描述符
make_call_gate_descriptor:
    push ebx
    push ecx

    shl eax,16          ;设置段选择子
    mov ax,bx           ;设置段偏移15:0
    mov bx,0
    and edx,ebx         ;设置段偏移31:16
    mov dx,cx           ;设置属性

    pop ecx
    pop ebx
    retf
;}}}
;install_gdt_descriptor函数;{{{
;
;功能：
;   安装段描述符到GDT并返回段选择子
;参数：
;   edx:eax = 完整的段描述符
;输出：
;   cx = 段选择子
install_gdt_descriptor:
    push ebx
    push ds
    push es

    mov ebx,kernel_data_seg_sel
    mov ds,ebx

    mov ebx,mem_0_4_gb_seg_sel
    mov es,ebx

    sgdt [pgdt]

    ;写入段描述符
    push ecx
    movzx ecx,word [pgdt]       
    inc cx
    add ecx,[pgdt+0x02]
    mov [es:ecx],eax
    mov [es:ecx+0x04],edx
    pop ecx

    ;更新GDT界限
    add word [pgdt],8           
    lgdt [pgdt]

    ;构造段选择子
    push dx
    push ax
    mov ax,[pgdt]               
    xor dx,dx
    mov cx,8
    div cx
    mov cx,ax
    shl cx,3                    ;左移三位将索引移到正确位置
                                ;同时腾出了TI,RPL三位(填充0)
    pop ax
    pop dx

    pop es
    pop ds
    pop ebx

    retf
;}}}
;allocate_memory函数;{{{
;
;功能：
;   分配指定大小的内存区域
;参数：
;   ecx = 希望分配的字节数
;输出：
;   ecx = 分配的内存起始线性地址
allocate_memory:
    push eax
    push ebx
    push ds

    mov eax,kernel_data_seg_sel
    mov ds,eax

    mov eax,[memory]
    add eax,ecx         ;让下一个地址4字节对齐
    mov ebx,eax
    and ebx,0xfffffffc
    add ebx,4
    test eax,0x3
    cmovnz eax,ebx

    mov ecx,[memory]

    mov [memory],eax

    pop ds
    pop ebx
    pop eax

    retf
;}}}
;put_hex_dword函数;{{{
;
;功能：
;   在当前光标位置以字符形式（0xABCD）打印一个双字，并推进光标位置
;参数：
;   edx = 要打印的双字
;输出：
;   无
put_hex_dword:
    push eax
    push ebx
    push ecx
    push edx
    push ds
    
    mov eax,kernel_data_seg_sel
    mov ds,eax

    mov cl,'0'
    call putchar
    mov cl,'x'
    call putchar

    mov ecx,8
    mov ebx,hex_table
.print_4bits:
    rol edx,4
    mov al,dl
    and al,0xf
    xlatb
    push cx
    mov cl,al
    call putchar
    pop cx
    loop .print_4bits

    pop ds
    pop edx
    pop ecx
    pop ebx
    pop eax

    retf
;}}}
;alloc_a_4KB_page_mem函数;{{{
;
;功能：
;   通过查找内存位表找到一个未使用的页，转换成页的物理地址返回
;参数：
;   无
;输出：
;   eax = 分配好的页物理地址
alloc_a_4KB_page_mem:
    push ebx
    push ds

    mov eax,kernel_data_seg_sel
    mov ds,eax

    mov eax,page_bit_map
    mov ebx,0
.check_next_bit:
    bts [page_bit_map],ebx
    jnc .get_a_page

    inc ebx
    cmp ebx,page_map_len*8
    jl .check_next_bit

    mov ebx,out_of_mem_msg
    call kernel_sysroute_seg_sel:putstr

    hlt

.get_a_page:
    mov eax,ebx
    shl eax,12
    or eax,0x7

    pop ds
    pop ebx

    ret
;}}}
;alloc_inst_a_page函数;{{{
;
;功能：
;   为线性地址创建或填写PDE,PTE和Page
;参数：
;   ebx = 页的线性地址
;输出：
;   无
alloc_inst_a_page:
    push eax
    push ebx
    push ecx
    push ds

    mov eax,mem_0_4_gb_seg_sel
    mov ds,eax

    ;检查页目录项
    mov ecx,ebx
    shr ecx,22
    shl ecx,2
    or ecx,0xfffff000

    mov eax,[ecx]
    test eax,1
    jnz .pte

    call alloc_a_4KB_page_mem   ;分配一张页表
    mov [ecx],eax

    ;检查页表项
.pte:
    mov eax,0xffc00000

    mov ecx,ebx
    shr ecx,22
    shl ecx,12
    or eax,ecx
    
    mov ecx,ebx
    shl ecx,10
    shr ecx,22
    shl ecx,2
    or eax,ecx

    mov ecx,eax

    mov eax,[ecx]
    test eax,1
    jnz .page

    call alloc_a_4KB_page_mem   ;分配一页
    mov [ecx],eax

.page:

    pop ds
    pop ecx
    pop ebx
    pop eax

    retf
;}}}
;copy_kernel_page_directory函数{{{
;
;功能：
;   根据页位图找出一新页，复制内核当前页目录到该新页中，并返回该页物理地址
;输入：
;   无
;输出：
;   eax - 新页的物理地址
copy_kernel_page_directory:
    push esi
    push edi
    push ecx
    push ds
    push es

    mov eax,mem_0_4_gb_seg_sel
    mov ds,eax
    mov es,eax

    call alloc_a_4KB_page_mem
    mov [0xfffffff8],eax

    cld
    mov esi,0xfffff000
    mov edi,0xffffe000
    mov ecx,1024
    repe movsd

    pop es
    pop ds
    pop ecx
    pop edi
    pop esi

    retf
    ;}}}

sys_routine_end:
;}}}

;内核数据段{{{
SECTION kernel_data vstart=0

;install_gdt_descriptor函數需要內存临时保存GDT
pgdt    dw  0
        dd  0
;allocate_memory函数用来存储下一个分配地址
memory  dd  0x100000
;put_hex_dword函数用的十六进制表
hex_table   db  '0123456789abcdef'

return_str  db 0x0a, 0x0d, 0

cpu_brnd0   db 'CPU INFO: ', 0
cpu_brand   times   64  db 0
msg_1       db 'Now is in kernel, prepare to enable page', 0
msg_3       db 'User Program Loaded.', 0
msg_2       db 'Back from user program', 0
test_call_gate_msg  db 'k-salt is convert to call gate, and works fine.', 0

return_msg1 db 0x0a, 0x0d, 'Back from user program 1, re-enter...', 0x0a, 0x0d, 0
return_msg2 db 0x0a, 0x0d, 'Back from user program 2, re-enter...', 0x0a, 0x0d, 0

msg_4       db 0x0a, 0x0d, 'recall user program', 0x0a, 0x0d, 0

terminate_msg1  db 0x0a, 0x0d, 'from call or exception', 0x0a, 0x0d, 0
terminate_msg2  db 0x0a, 0x0d, 'from jmp', 0x0a, 0x0d, 0

hlt_msg     db 0x0a, 0x0d, 'Kernel has nothing to do, hlt.', 0

tcb_chain   dd 0

user_header_buffer  times 512 db 0

;salt表{{{
salt:

salt_1      db '@PrintString'
            times (256-($-salt_1))  db 0
            dd putstr
            dw kernel_sysroute_seg_sel

salt_2      db '@ReadDiskData'
            times (256-($-salt_2))  db 0
            dd read_one_disk_sector
            dw kernel_sysroute_seg_sel

salt_3      db '@PrintDwordAsHexString'
            times (256-($-salt_3))  db 0
            dd put_hex_dword
            dw kernel_sysroute_seg_sel

salt_4      db '@TerminateProgram'
            times (256-($-salt_4))  db 0
            dd terminate_current_task
            dw kernel_code_seg_sel
salt_end:
salt_item_len   equ salt_end-salt_4
salt_items      equ ($-salt)/salt_item_len
;}}}

prgman_tss  dd 0
            dw 0

;8*8*8*4KB=64*8*4KB=512*4KB=2MB
page_bit_map    db  0xff,0xff,0xff,0xff,0xff,0x55,0x55,0xff
                db  0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff
                db  0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff
                db  0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff
                db  0x55,0x55,0x55,0x55,0x55,0x55,0x55,0x55
                db  0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
                db  0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
                db  0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
page_map_len    equ $-page_bit_map

kernel_next_laddr dd 0x80100000

out_of_mem_msg  db 'Out of memory, hlt', 0

kernel_data_end:
;}}}

;内核代码段{{{
SECTION kernel_code vstart=0

;fill_descriptor_in_ldt函数{{{
;
;作用：
;    将描述符添加到ldt表
;参数：
;    edx:eax = 描述符
;    ebx = TCB线性基地址
;输出：
;    cx = 选择子
fill_descriptor_in_ldt:
    push eax
    push edx
    push ds

    push ecx

    mov ecx,mem_0_4_gb_seg_sel
    mov ds,ecx

    push eax
    mov ecx,[ebx+0x0c]          ;获取LDT基地址     
    movzx eax,word [ebx+0x0a]   ;获取LDT界限
    inc ax
    add ecx,eax
    pop eax

    mov [ecx],eax               ;填写描述符
    mov [ecx+0x04],edx
    add word [ebx+0x0a],8       ;更新LDT界限值

    movzx eax,word [ebx+0x0a]
    xor edx,edx
    mov ecx,8
    div ecx

    pop ecx
    
    shl ax,3
    or ax,0x7                   ;LDT,RPL=3
    mov cx,ax

    pop ds
    pop edx
    pop eax

    ret
;}}}
;append_to_tcb_link函数{{{
;
;作用：
;    将TCB添加到TCB链中
;参数：
;    ecx = TCB线性基地址
;输出：
;    无
append_to_tcb_link:
    push eax
    push ds
    push es
    
    mov eax,kernel_data_seg_sel
    mov ds,eax

    mov eax,mem_0_4_gb_seg_sel
    mov es,eax

    mov eax,[tcb_chain]
    mov [es:ecx],eax
    mov [tcb_chain],ecx

    pop es
    pop ds
    pop eax

    ret
;}}}
;load_relocate_user_program函数{{{
;
;作用：
;   从硬盘加载用户程序到内存，为其添加段选择子并重定位salt
;参数：
;   push = 用户程序起始逻辑扇区号
;   push = TCB线性基地址
;输出：
;   无
load_relocate_user_program:
    pushad
    push ds
    push es

    mov eax,kernel_data_seg_sel
    mov ds, eax

    mov eax,mem_0_4_gb_seg_sel
    mov es,eax

    mov ebp,esp
    mov edi,[ebp+11*4]          ;取TCB线性基地址

    push edi                    ;局部变量，用于保存用户程序基地址

    ;清空内核线性地址0x0-0x7fffffff{{{
    mov ecx,512                 ;512个PDE
    mov eax,0xfffff000
.clear_next_pde:
    mov dword [es:eax],0
    add eax,4
    loop .clear_next_pde
    ;}}}

    ;{{{ 加载用户程序到内存

    ;加载用户程序的第一扇区
    mov esi,[ebp+12*4]          ;取用户程序起始扇区号
                                ;12 = push tcb基地址(1) + pushad(8)
                                ;   + push ds(1) + push es(1) + push cs(1)
    mov eax,esi
    mov ebx,user_header_buffer
    call kernel_sysroute_seg_sel:read_one_disk_sector

    ;从用户程序头部获取用户程序字节数
    mov eax,[user_header_buffer]
    mov ebx,eax
    and ebx,0xfffffe00
    add ebx,512
    test eax,0x1ff
    cmovnz eax,ebx

    mov ecx,[es:edi+0x06]       ;从TCB中获取下一个可用线性基地址
    mov [ebp-0x4],ecx           ;将用户程序基地址设置到局部变量中

    ;为用户程序分配内存
    push eax
    mov ebx,eax
    and ebx,0xfffff000
    add ebx,4096
    test eax,0xfff
    cmovnz eax,ebx

    mov ecx,eax
    shr ecx,12
.alloc_page:
    mov ebx,[es:edi+0x06]       ;从TCB中获取下一个可用线性基地址    
    add dword [es:edi+0x06],4096
    call kernel_sysroute_seg_sel:alloc_inst_a_page
    loop .alloc_page
    pop eax

    ;加载整个用户程序
    mov edx,mem_0_4_gb_seg_sel
    mov ds,edx

    mov ecx,eax
    shr ecx,9                   ;2^9=512
    mov eax,esi                 ;逻辑扇区号
    mov ebx,[ebp-0x4]           ;获取用户程序基地址
.read_sector:
    call kernel_sysroute_seg_sel:read_one_disk_sector
    inc eax
    loop .read_sector
    ;}}}
    
    mov eax,mem_0_4_gb_seg_sel
    mov ds,eax

    mov eax,kernel_data_seg_sel
    mov es, eax

    ;创建TSS{{{
    mov ebx,[es:kernel_next_laddr]
    mov esi,ebx                     ;设置esi为TSS基地址
    add dword [es:kernel_next_laddr],4096
    call kernel_sysroute_seg_sel:alloc_inst_a_page

    mov eax,esi
    mov ebx,104-1
    mov ecx,0x00408900              ;TSS, DPL=0
    call kernel_sysroute_seg_sel:make_seg_descriptor
    call kernel_sysroute_seg_sel:install_gdt_descriptor

    mov word [edi+0x12],104         ;填写TSS界限值到TCB
    mov [edi+0x14],esi              ;填写TSS线性基地址到TCB
    mov [edi+0x18],cx               ;填写TSS选择子到TCB

    mov dword [esi+60],0            ;填写ebp到TSS
    mov dword [esi+64],0            ;填写esi到TSS
    mov dword [esi+68],0            ;填写edi到TSS
    mov word  [esi+0],0             ;填写上一个TSS链接
    mov word  [esi+102],104         ;填写IOMap到TSS
    mov word  [esi+100],0           ;T=0

    pushfd
    pop edx
    mov [esi+36],edx                ;拷贝自身eflags到TSS
    ;}}}

    ;创建LDT{{{
    mov ebx,[edi+0x06]              ;从TCB中获取下一个可用线性基地址
    add dword [edi+0x06],4096
    call kernel_sysroute_seg_sel:alloc_inst_a_page

    mov [edi+0x0c],ebx              ;填写LDT基地址到TCB
    mov word [edi+0x0a],0xffff      ;填写LDT当前已用界限到TCB
                                    ;下次往LDT安装新描述符时, 0xffff+1正好为0

    mov eax,ebx
    mov ebx,160                     ;8*20 LDT内最多20条描述符
    dec ebx
    mov ecx,0x0040e200
    call kernel_sysroute_seg_sel:make_seg_descriptor
    call kernel_sysroute_seg_sel:install_gdt_descriptor

    mov [edi+0x10],cx               ;填写LDT选择子到TCB
    mov [esi+96],cx                 ;填写LDT选择子到TSS
    ;}}}

    ;{{{ 处理用户数据段
    mov eax,0
    mov ebx,0xffffe
    mov ecx,0x00c0f200              ;G=1,DPL=3
    call kernel_sysroute_seg_sel:make_seg_descriptor
    mov ebx,edi
    call fill_descriptor_in_ldt
    mov [esi+84],cx                 ;填写ds到TSS
    mov [esi+72],cx                 ;填写es到TSS
    mov [esi+88],cx                 ;填写fs到TSS
    mov [esi+92],cx                 ;填写gs到TSS
    ;}}}
    
    ;{{{ 处理用户代码段
    mov eax,0
    mov ebx,0xffffe
    mov ecx,0x00c0f800          ;G=1,DPL=3
    call kernel_sysroute_seg_sel:make_seg_descriptor
    mov ebx,edi
    call fill_descriptor_in_ldt
    mov [esi+76],cx             ;填写cs到TSS
    mov ebx,[ebp-0x4]           ;获取用户程序基地址
    mov eax,[ebx+0x4]           ;从用户程序头部获取代码入口偏移
    mov [esi+32],eax            ;填写eip到TSS
    ;}}}

    ;处理用户栈段{{{
    mov ebx,[esi+0x06]
    add dword [esi+0x06],4096
    call kernel_sysroute_seg_sel:alloc_inst_a_page

    mov eax,0
    mov ebx,0xffffe             ;4GB
    mov ecx,0x00c0f200          ;4KB粒度，DPL=3, expand-up
    call kernel_sysroute_seg_sel:make_seg_descriptor
    mov ebx,edi
    call fill_descriptor_in_ldt
    
    mov [esi+80],cx          ;填写ss到TSS中
    mov eax,[edi+0x06]
    mov [esi+56],eax         ;填写esp到TSS中
    ;}}}

    ;重定位user-salt{{{
    push esi
    push edi

    mov ebx,[ebp-0x04]          ;获取用户程序基地址
    mov esi,[ebx+0x08]          ;从用户程序头部获取user-salt起始地址
    mov ecx,[ebx+0x0c]          ;从用户程序头部获取user-salt数量

    cld

.next_user_salt_item:
    push esi
    push ecx
    mov edi,salt

    mov eax,esi
    mov ebx,edi
.next_kernel_salt_item:
    mov esi,eax
    mov edi,ebx
    cmp edi,salt_end
    jge .continue_next_user_salt_item   ;超出kernel-salt表
                                        ;继续处理下一个user-salt项

    add ebx,256+6
    mov ecx,64                  ;256/4=64
    repe cmpsd
    jnz .next_kernel_salt_item

    mov eax,[es:edi]
    mov bx,[es:edi+0x04]
    mov [esi-256],eax
    or bx,0x3                   ;使RPL=3
    mov [esi-252],bx

.continue_next_user_salt_item:
    pop ecx
    pop esi
    add esi,256
    loop .next_user_salt_item

    pop edi
    pop esi
    ;}}}

    ;创建0特权级栈{{{
    mov ebx,[edi+0x06]
    add dword [edi+0x06],4096
    call kernel_sysroute_seg_sel:alloc_inst_a_page

    mov eax,0
    mov ebx,0xffffe
    mov ecx,0x00c09200
    call kernel_sysroute_seg_sel:make_seg_descriptor
    mov ebx,edi
    call fill_descriptor_in_ldt

    and cx,0xfffc               ;设置RPL=00
    mov [esi+8],cx              ;填写ss0到TSS
    mov ebx,[edi+0x06]
    mov [esi+4],ebx             ;填写esp0到TSS
    ;}}}

    ;创建1特权级栈{{{
    mov ebx,[edi+0x06]
    add dword [edi+0x06],4096
    call kernel_sysroute_seg_sel:alloc_inst_a_page

    mov eax,0
    mov ebx,0xffffe
    mov ecx,0x00c0b200          ;DPL=01
    call kernel_sysroute_seg_sel:make_seg_descriptor
    mov ebx,edi
    call fill_descriptor_in_ldt

    and cx,0xfffc
    or cx,1                     ;RPL=01
    mov [esi+16],cx             ;填写ss1到TSS
    mov ebx,[edi+0x06]
    mov [esi+12],ebx            ;填写esp1到TSS
    ;}}}

    ;{{{ 创建2特权级栈
    mov ebx,[edi+0x06]
    add dword [edi+0x06],4096
    call kernel_sysroute_seg_sel:alloc_inst_a_page

    mov eax,0
    mov ebx,0xffffe
    mov ecx,0x00c0d200
    call kernel_sysroute_seg_sel:make_seg_descriptor
    mov ebx,edi
    call fill_descriptor_in_ldt

    and cx,0xfffc
    or cx,0x2
    mov [esi+24],cx             ;填写ss2到TSS
    mov ebx,[edi+0x06]
    mov [esi+20],ebx            ;填写esp2到TSS
    ;}}} 

    ;复制内核页目录给用户程序{{{
    mov ebx,[edi+0x06]
    add dword [edi+0x06],4096
    call kernel_sysroute_seg_sel:alloc_inst_a_page
    call kernel_sysroute_seg_sel:copy_kernel_page_directory
    mov [esi+28],eax            ;填写CR3到TSS
    ;}}}

    pop eax                     ;弹出局部变量，用户程序基地址

    pop es
    pop ds
    popad

    ret
    ;}}}
;terminate_current_task{{{
terminate_current_task:
    push ebx
    push ds

    mov ebx,kernel_data_seg_sel
    mov ds,ebx

    pushfd              ;将eflags压栈
    pop ebx             ;将eflags出栈到ebx中

    ;根据eflags的NT位（bit14）来决定用iret还是jmp来进行任务切换
    test ebx,0x4000
    jz .jmp

    mov ebx,terminate_msg1
    call kernel_sysroute_seg_sel:putstr
    iretd
    jmp .ret

.jmp:
    mov ebx,terminate_msg2
    call kernel_sysroute_seg_sel:putstr
    jmp far [prgman_tss]

.ret:
    pop ds
    pop ebx

    retf
    ;}}}
;start{{{
start:
    mov eax,kernel_data_seg_sel
    mov ds,eax

    mov eax,kernel_stack_seg_sel
    mov ss,eax
    xor esp,esp

    ;显示CPU信息;{{{
    mov ebx,return_str
    call kernel_sysroute_seg_sel:putstr

    mov ebx,cpu_brnd0
    call kernel_sysroute_seg_sel:putstr

    ;使用cpuid获取cpu信息
    mov eax,0x80000002
    cpuid
    mov [cpu_brand+0x00], eax
    mov [cpu_brand+0x04], ebx
    mov [cpu_brand+0x08], ecx
    mov [cpu_brand+0x0c], edx

    mov eax,0x80000003
    cpuid
    mov [cpu_brand+0x10], eax
    mov [cpu_brand+0x14], ebx
    mov [cpu_brand+0x18], ecx
    mov [cpu_brand+0x1c], edx

    mov eax,0x80000004
    cpuid
    mov [cpu_brand+0x20], eax
    mov [cpu_brand+0x24], ebx
    mov [cpu_brand+0x28], ecx
    mov [cpu_brand+0x2c], edx

    mov ebx,cpu_brand
    call kernel_sysroute_seg_sel:putstr
    ;}}}

    ;显示msg_1;{{{
    mov ebx,return_str
    call kernel_sysroute_seg_sel:putstr
    call kernel_sysroute_seg_sel:putstr
    mov ebx,msg_1
    call kernel_sysroute_seg_sel:putstr
    ;}}}

    ;开启分页机制{{{
    mov eax,mem_0_4_gb_seg_sel
    mov es,eax

    ;PTE
    mov eax,kernel_pde_phy_addr
    mov ebx,kernel_pte_phy_addr
    or ebx,0x3                  ;r/w=1,p=1
    mov [es:eax],ebx

    ;PDE高半部分地址(线性地址0x80000000-0xffffffff)划为内核使用
    mov [es:eax+512*4],ebx

    ;将PDE最高目录项指向PDE自己
    mov edx,eax
    or edx,0x3
    mov [es:eax+4092],edx

    ;PDE
    mov cr3,edx

    ;分配0-1MB到PTE
    mov ecx,256                 ;1MB = 4KB * 256
    mov eax,kernel_pte_phy_addr
    mov ebx,0
.next_page:
    mov edx,ebx
    or edx,0x3                  ;r/w=1,p=1
    mov [es:eax],edx
    add ebx,4096
    add eax,4
    loop .next_page

    ;设置该页表其它表项(1MB-4MB)为无效
    mov ecx,256*3
.next_null_page:
    mov dword [es:eax],0
    add eax,4
    loop .next_null_page

    ;开启分页机制
    mov eax,cr0
    or eax,0x80000000           ;cr0最高位置1
    mov cr0,eax
    ;}}}

    ;将GDT中的段描述符基地改为0x80000000以上地址{{{
    sgdt [pgdt]
    mov ebx,[pgdt+0x2]

    or dword [es:ebx+0x10+4],0x80000000
    or dword [es:ebx+0x18+4],0x80000000
    or dword [es:ebx+0x20+4],0x80000000
    or dword [es:ebx+0x28+4],0x80000000
    or dword [es:ebx+0x30+4],0x80000000
    or dword [es:ebx+0x38+4],0x80000000

    or dword [pgdt+0x2],0x80000000  ;GDT基地址改为0x80000000以上
    lgdt [pgdt]                     ;更新GDT
    ;}}}

    ;刷新当前使用的段{{{
    jmp kernel_code_seg_sel:flush   ;刷新cs

flush:
    mov eax,kernel_data_seg_sel     ;刷新ds
    mov ds,eax

    mov eax,mem_0_4_gb_seg_sel      ;刷新es
    mov es,eax

    mov eax,kernel_stack_seg_sel    ;刷新ss
    mov ss,eax
    ;}}}

    ;将k-salt中的段选择子改为调用门{{{
    mov ecx,salt_items
    mov edx,salt
.next_kernel_salt_item:
    push ecx
    mov ax,[edx+260]                ;selector
    mov ebx,[edx+256]               ;offset
    mov cx,0xec00                   ;111_0_1100_000_00000B
    push edx
    call kernel_sysroute_seg_sel:make_call_gate_descriptor
    call kernel_sysroute_seg_sel:install_gdt_descriptor
    pop edx
    mov [edx+260],cx                ;回填调用门选择子
    add edx,salt_item_len
    pop ecx
    loop .next_kernel_salt_item

    ;对门进行测试
    mov ebx,test_call_gate_msg
    call far [salt_1+256]
    ;}}}

    mov eax,mem_0_4_gb_seg_sel
    mov ds,eax

    mov eax,kernel_data_seg_sel
    mov es,eax

    ;创建内核TSS，称为程序管理任务{{{
    mov ebx,[es:kernel_next_laddr];
    add dword [es:kernel_next_laddr],4096
    call kernel_sysroute_seg_sel:alloc_inst_a_page

    ;填写TSS部分字段
    mov ecx,ebx
    mov word [ecx],0        ;上一个任务链接置为0
    mov word [ecx+96],0     ;LDT置为0
    mov word [ecx+100],0    ;T位置为0
    mov word [ecx+102],104  ;设置IO位图

    mov eax,cr3
    mov [ecx+28],eax        ;设置PDBR

    ;在GDT中注册TSS
    mov eax,ecx
    mov ebx,104-1
    mov ecx,0x00408900
    call kernel_sysroute_seg_sel:make_seg_descriptor
    call kernel_sysroute_seg_sel:install_gdt_descriptor

    ;将TSS选择子填入内核数据段prgman_tss内存处
    mov word [es:prgman_tss+0x4],cx

    ;加载TSS
    ltr cx
    ;}}}

    ;第一个用户程序{{{
    ;使用call发起任务切换

    mov eax,kernel_data_seg_sel
    mov ds,eax

    mov eax,mem_0_4_gb_seg_sel
    mov es,eax

    ;分配TCB内存
    mov ebx,[kernel_next_laddr]
    add dword [kernel_next_laddr],4096
    call kernel_sysroute_seg_sel:alloc_inst_a_page
    mov ecx,ebx
    call append_to_tcb_link
    mov dword [es:ebx+0x06],0               ;设置任务下一个可用线性地址为0

    ;加载用户程序
                                            ;用栈传参
    push dword user_prog_start_sector       ;用户程序硬盘起始扇区号
    push ecx                                ;TCB线性基地址
    call load_relocate_user_program

    ;使用TSS切换到用户程序
    call far [es:ecx+0x14]

    ;从用户程序返回，打印消息
    mov ebx,return_msg1
    call kernel_sysroute_seg_sel:putstr

    ;再次切换到用户程序
    call far [es:ecx+0x14]

    ;从用户程序返回，打印消息
    mov ebx,return_msg1
    call kernel_sysroute_seg_sel:putstr

    ;}}}

    ;第二个用户程序{{{
    ;使用call发起任务切换

    mov eax,kernel_data_seg_sel
    mov ds,eax

    mov eax,mem_0_4_gb_seg_sel
    mov es,eax

    ;分配TCB内存
    mov ebx,[kernel_next_laddr]
    add dword [kernel_next_laddr],4096
    call kernel_sysroute_seg_sel:alloc_inst_a_page
    mov ecx,ebx
    call append_to_tcb_link
    mov dword [es:ebx+0x06],0               ;设置任务下一个可用线性地址为0

    ;加载用户程序
                                            ;用栈传参
    push dword user_prog_start_sector       ;用户程序硬盘起始扇区号
    push ecx                                ;TCB线性基地址
    call load_relocate_user_program

    ;使用TSS切换到用户程序
    jmp far [es:ecx+0x14]

    ;从用户程序返回，打印消息
    mov ebx,return_msg2
    call kernel_sysroute_seg_sel:putstr

    ;再次切换到用户程序
    jmp far [es:ecx+0x14]

    ;从用户程序返回，打印消息
    mov ebx,return_msg2
    call kernel_sysroute_seg_sel:putstr

    ;}}}

    mov ebx,hlt_msg
    call kernel_sysroute_seg_sel:putstr

    hlt
    ;}}}

kernel_code_end:
;}}}

;{{{ kernel_tail段
SECTION kernel_tail
kernel_end:
;}}}

; vim: set syntax=nasm autoread:
