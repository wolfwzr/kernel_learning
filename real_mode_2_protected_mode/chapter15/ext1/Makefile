DISK="../../disk.vhd"

all: mbr kernel user disk vb

mbr:
	nasm -f bin -o mbr.bin -l mbr.lst mbr.asm

kernel:
	nasm -f bin -o kernel.bin -l kernel.lst kernel.asm

user:
	nasm -f bin -o user1.bin -l user1.lst user1.asm
	nasm -f bin -o user2.bin -l user2.lst user2.asm

disk:
	dd if=mbr.bin of=$(DISK) bs=512 count=1 conv=notrunc
	dd if=kernel.bin of=$(DISK) bs=512 seek=5 conv=notrunc
	dd if=user1.bin of=$(DISK) bs=512 seek=40 conv=notrunc
	dd if=user2.bin of=$(DISK) bs=512 seek=50 conv=notrunc

vb:
	VBoxManage startvm os_test

bochs:
	cd .. && bochs -q
