program_length  dd program_end
entry           dd start
salt_start      dd salt
salt_items      dd (salt_end-salt)/256

salt:
    ReadDiskData        db '@ReadDiskData'
                        times 256-($-ReadDiskData) db 0
    PrintString         db '@PrintString'
                        times 256-($-PrintString) db 0
    TerminateProgram    db '@TerminateProgram'
                        times 256-($-TerminateProgram) db 0
    reserved            times 256*500 db 0      ;保留一个空白区，以演示分页
    ReadDiskData        db  '@ReadDiskData'
                        times 256-($-ReadDiskData) db 0
    PrintDwordAsHex     db  '@PrintDwordAsHexString'
                        times 256-($-PrintDwordAsHex) db 0
salt_end:

message_0        db  0x0d,0x0a,
                 db  '  ............User task is running with '
                 db  'paging enabled!............',0x0d,0x0a,0

space            db  0x20,0x20,0


[bits 32]

start:
    mov ebx,message_0
    call far [PrintString]
    
    xor esi,esi
    mov ecx,88
.b1:
    mov ebx,space
    call far [PrintString]

    mov edx,[esi]
    call far [PrintDwordAsHex]
    add edx,4

    loop .b1

    call far [TerminateProgram]

program_end:

; vim: set syntax=nasm:
