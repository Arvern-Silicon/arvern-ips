# Regenerate the documentation waveforms (SVG) from their WaveDrom JSON sources.
#
#   make          # rebuild every <name>.svg whose <name>.json is newer
#   make force    # rebuild all SVGs unconditionally
#   make clean    # remove the generated SVGs
#   make preview  # PNGs under ./preview for visual review (not committed)
#
# Requires Node.js. wavedrom-cli is fetched on demand via `npx -y` (no install
# needed); override with e.g. `make WAVEDROM='wavedrom-cli'` if you have it
# installed locally. Both the .json sources and the generated .svg files are
# committed, so a consumer never has to run this - it is only for maintainers
# editing a waveform.

WAVEDROM ?= npx -y wavedrom-cli

JSON := $(wildcard *.json)
SVG  := $(JSON:.json=.svg)
PNG  := $(addprefix preview/,$(JSON:.json=.png))

.PHONY: all force clean preview
all: $(SVG)

%.svg: %.json
	$(WAVEDROM) -i $< -s $@

force: clean all

preview: $(PNG)

preview/%.png: %.json
	@mkdir -p preview
	$(WAVEDROM) -i $< -p $@

clean:
	rm -f $(SVG)
