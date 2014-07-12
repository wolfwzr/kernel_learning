;本程序测试项：
;   对于下面这条指令：
;       mov bx,[ax+1]
;   当ax在编译时可确定值时，是指会将指令优化为：
;       mov bx,[imm]
;
;注：
;   [ax+1]和[2]都是直接CPU支持的寻址方式
;
;结果：
;   00000000  66B801000000      mov eax,0x1
;   00000006  678B5801          mov bx,[eax+0x1]
;   0000000A  8B1E0200          mov bx,[0x2]
;   0000000E  8B1E0200          mov bx,[0x2]
;   说明汇编器没有将[eax+1]直接优化成[2],但会将[1+1]优化成[2]
;   问: CPU支持[1+1]的寻址方式吗？

number_one equ 1

mov eax,1
mov bx,[eax+1]           ;观察这三条指令的机器是否一样
mov bx,[number_one+1]
mov bx,[2]
