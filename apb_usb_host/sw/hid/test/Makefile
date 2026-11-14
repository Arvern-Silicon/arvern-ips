# Host unit tests of the HID decoder and the driver's report path: make (runs them)
CC      ?= cc
SW       = ../..
CFLAGS   = -std=c11 -Wall -Wextra -Werror -g -fsanitize=address,undefined \
           -I$(SW)/include -I$(SW)/hid
SRCS     = test_hid.c $(SW)/hid/apb_usb_host_hid.c $(SW)/src/apb_usb_host.c

run: build/test_hid
	./build/test_hid

build/test_hid: $(SRCS) $(SW)/include/*.h $(SW)/hid/*.h Makefile
	mkdir -p build
	$(CC) $(CFLAGS) $(SRCS) -o $@

clean:
	rm -rf build

.PHONY: run clean
