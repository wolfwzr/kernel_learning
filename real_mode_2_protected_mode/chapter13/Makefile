all: mbr2 disk

mbr1:
	nasm -f bin -o mbr.bin mbr1.asm

mbr2:
	nasm -f bin -o mbr.bin mbr2.asm

disk:
	dd if=mbr.bin of=../disk.vhd bs=512 count=1 conv=notrunc
