section code vstart=0x7c00 
mov ax,label
mov ax,0x1+label
mov ax,$
mov ax,$$
mov ax,$-$$
mov ax,section.code.start

label:
    db 0xa
