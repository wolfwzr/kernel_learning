program_length  dd program_end
entry           dd start
salt_start      dd salt
salt_items      dd (salt_end-salt)/256

salt:
    PrintString         db '@PrintString'
                        times 256-($-PrintString) db 0
    TerminateProgram    db '@TerminateProgram'
                        times 256-($-TerminateProgram) db 0
    ;--------------------------------------
    ;保留一个空白区，以演示分页
    reserved            times 256*10 db 0          
    ;--------------------------------------
    ReadDiskData        db '@ReadDiskData'
                        times 256-($-ReadDiskData) db 0
    PrintDwordAsHex     db  '@PrintDwordAsHexString'
                        times 256-($-PrintDwordAsHex) db 0
salt_end:

message_0       db  0x0d,0x0a,
                db  '  ............User task is running with '
                db  'paging enabled!............',0x0d,0x0a,0

space           db  0x20,0x20,0
return_str      db  0x0a,0x0d,0


[bits 32]

xor esi,esi

start:
    mov ebx,message_0
    call far [PrintString]
    
    mov ecx,24
.b1:
    xor edx,edx
    mov eax,esi
    mov ebx,24
    div ebx
    cmp edx,0
    jnz .b2

    mov ebx,return_str
    call far [PrintString]

.b2:
    mov edx,[esi]
    call far [PrintDwordAsHex]

    mov ebx,space
    call far [PrintString]

    add esi,4
    loop .b1

    call far [TerminateProgram]

    jmp start

program_end:

; vim: set syntax=nasm autoread:
