all: mbr2 kernel disk vb

mbr1:
	nasm -f bin -o mbr.bin -l mbr.lst mbr1.asm

mbr2:
	nasm -f bin -o mbr.bin -l mbr.lst mbr2.asm

kernel:
	nasm -f bin -o kernel.bin -l kernel.lst kernel.asm

disk:
	dd if=mbr.bin of=../disk.vhd bs=512 count=1 conv=notrunc
	dd if=kernel.bin of=../disk.vhd bs=512 seek=10 conv=notrunc

vb:
	VBoxManage startvm os_test

bochs:
	bochs -q
