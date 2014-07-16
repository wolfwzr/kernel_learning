all: mbr2 kernel user disk vb

mbr1:
	nasm -f bin -o mbr.bin -l mbr.lst mbr1.asm

mbr2:
	nasm -f bin -o mbr.bin -l mbr.lst mbr2.asm

kernel:
	nasm -f bin -o kernel.bin -l kernel.lst kernel.asm

user:
	nasm -f bin -o user.bin -l user.lst user.asm

disk:
	dd if=mbr.bin of=../disk.vhd bs=512 count=1 conv=notrunc
	dd if=kernel.bin of=../disk.vhd bs=512 seek=5 conv=notrunc
	dd if=user.bin of=../disk.vhd bs=512 seek=40 conv=notrunc
	dd if=data.txt of=../disk.vhd bs=512 seek=50 conv=notrunc

vb:
	VBoxManage startvm os_test

bochs:
	bochs -q
