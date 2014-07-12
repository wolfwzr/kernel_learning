;本程序测试项：
;   1. $、$$、label的含义
;   2. section.xxx.start的含义
;
;结果：
;   1. $$表示vstart
;   2. $表示vstart+当前指令的段内偏移
;   3. label表示vstart+当前label的段内偏移
;   4. section.xxx.start表示当前段在文件中的偏移
;
;注：
;   可以调整vstart的值来测试，不申明section时，vstart默认为当前段在文件中的偏移
;

section code vstart=0x7c00 
mov ax,label
mov ax,0x1+label
mov ax,$
mov ax,$$
mov ax,$-$$
mov ax,section.code.start

label:
    db 0xa
