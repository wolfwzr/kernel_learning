SECTION header vstart=0
program_length      dd  program_end
header_lenght       dd  header_end

stack_seg           dd  0   ;回填栈段选择子
stack_len           dd  1   ;用户程序希望分配的栈大小，粒度为4KB

user_data_seg       dd section.user_data.start  ;回填数据段选择子
user_data_seg_len   dd user_data_end

program_entry       dd start
user_code_seg       dd section.user_code.start  ;回填代码段选择子
user_code_seg_len   dd user_code_end

salt_items              dd (salt_end-salt)/256
salt:
    ReadDiskData        db '@ReadDiskData'
                        times 256-($-ReadDiskData) db 0
    PrintString         db '@PrintString'
                        times 256-($-PrintString) db 0
    ReleaseControl      db '@ReleaseControl'
                        times 256-($-ReleaseControl) db 0
salt_end:

header_end:

SECTION user_data vstart=0
prog_msg_1  db 'B', 0
user_data_end:

[bits 32]
SECTION user_code vstart=0

start:
    mov eax,ds                  ;ds被kernel初始为header段选择子
    mov fs,eax
    
    mov ax,[user_data_seg]
    mov ds,ax                   ;现在ds为用户程序数据段选择子
    
.print:
    mov ebx,prog_msg_1
    call far [fs:PrintString]
    call far [fs:ReleaseControl]
    jmp .print

user_code_end:

SECTION tail
program_end:

; vim: set syntax=nasm:
