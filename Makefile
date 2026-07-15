PROJECTS := image_proc matrix4x4 nn_fc nn_fc_accel nn_fc_zfpe rv32i test
PROJECT ?= test
BOARD ?= ulx3s

.PHONY: help list-projects tools lint verilog netlist pnr bitstream synth host \
	bsim runsim program clean clean-all

help:
	@printf '%s\n' \
		"blueYosys build dispatcher" \
		"  make synth PROJECT=test BOARD=ulx3s" \
		"  make verilog PROJECT=test BOARD=ulx3s" \
		"  make bsim PROJECT=matrix4x4 BOARD=ulx3s" \
		"  make host PROJECT=test" \
		"  make lint" \
		"  make list-projects" \
		"APIO is not required; synthesis uses bsc, yosys, nextpnr, and ecppack directly."

list-projects:
	@printf '%s\n' $(PROJECTS)

tools:
	+$(MAKE) -C tools

lint:
	bash scripts/lint_repo.sh

verilog netlist pnr bitstream synth host bsim runsim program clean:
	@test -d "projects/$(PROJECT)" || { \
		echo "Unknown PROJECT=$(PROJECT). Run 'make list-projects'." >&2; \
		exit 2; \
	}
	+$(MAKE) -C "projects/$(PROJECT)" BOARD="$(BOARD)" $@

clean-all:
	@for project in $(PROJECTS); do \
		$(MAKE) -C "projects/$$project" clean; \
	done
	+$(MAKE) -C tools clean
