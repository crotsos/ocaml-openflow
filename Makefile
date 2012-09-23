.PHONY: all clean distclean setup build doc install test 
all: build

NAME=openflow
J=4

LWT ?= $(shell if ocamlfind query lwt.ssl >/dev/null 2>&1; then echo --enable-lwt; fi)
MIRAGE ?= $(shell if ocamlfind query mirage-net >/dev/null 2>&1; then echo --enable-mirage; fi)

-include Makefile.config

clean: setup.data setup.bin
	./setup.bin -clean $(OFLAGS)
	rm -f setup.data setup.log setup.bin

distclean: setup.data setup.bin
	./setup.bin -distclean $(OFLAGS)
	rm -f setup.data setup.log setup.bin

setup: setup.data setup.bin

build: setup.data setup.bin $(wildcard lib/*.ml)
	./setup.bin -build -j $(J) $(OFLAGS)

doc: setup.data setup.bin
	./setup.bin -doc -j $(J) $(OFLAGS)

install: 
	ocamlfind remove $(NAME)
	./setup.bin -install $(OFLAGS)

test: build
	./setup.bin -test

##

setup.bin: setup.ml
	ocamlopt.opt -o $@ $< || ocamlopt -o $@ $< || ocamlc -o $@ $<
	rm -f setup.cmx setup.cmi setup.o setup.cmo

setup.ml: _oasis
	oasis setup

setup.bin: setup.ml
	ocamlopt.opt -o $@ $< || ocamlopt -o $@ $< || ocamlc -o $@ $<
	$(RM) setup.cmx setup.cmi setup.o setup.cmo

setup.data: setup.bin
	./setup.bin -configure $(LWT) --disable-mirage 
