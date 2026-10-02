#----------------------------------------------------------------------------
#          _    _           Family:    aRVern System IPs
#         / \__/ \          Module:    constraints_ports.arv_dtm
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# File Name          : constraints_ports.arv_dtm.tcl
# Module Description : Constraints for the transport-selectable arv_dtm wrapper.
#
#   The wrapper exposes the union of every transport's pins but elaborates only
#   the front-end selected by DTM_TYPE (0=JTAG 1=UART 2=I2C 3=cJTAG). This file
#   sources that transport's constraints_ports file with the system clock bound
#   to the wrapper's clk_i. The other transports' pins are constrained nowhere:
#   their inputs are sunk and their outputs are tied to the idle level.
#
#   ::DTM_TIED_OUTPUTS lists those tied outputs (mirrors the generate branches
#   of arv_dtm.v). They have no timing path, so check_timing reports them as
#   unconstrained endpoints; synthesis.tcl writes the list to
#   results/tied_outputs.lst and the run_syn sweep excludes it from its count.
#----------------------------------------------------------------------------

set DTM_TYPE 0
if {[info exists RTL_PARAM_DTM_TYPE]} { set DTM_TYPE $RTL_PARAM_DTM_TYPE }

# JTAG's DMI clock port is hclk_i on arv_dtm_jtag; the wrapper binds it to clk_i.
set DTM_SYS_CLK_PORT clk_i

switch -- $DTM_TYPE {
    0 {
        set DTM_TRANSPORT    arv_dtm_jtag
        set ::DTM_TIED_OUTPUTS {uart_tx_o scl_pd_o sda_pd_o tmsc_o tmsc_oe_o}
    }
    1 {
        set DTM_TRANSPORT    arv_dtm_uart
        set ::DTM_TIED_OUTPUTS {tdo_o tdo_oe_o scl_pd_o sda_pd_o dbg_wakeup_o tmsc_o tmsc_oe_o}
    }
    2 {
        set DTM_TRANSPORT    arv_dtm_i2c
        set ::DTM_TIED_OUTPUTS {tdo_o tdo_oe_o uart_tx_o dbg_wakeup_o tmsc_o tmsc_oe_o}
    }
    3 {
        set DTM_TRANSPORT    arv_dtm_cjtag
        set ::DTM_TIED_OUTPUTS {tdo_o tdo_oe_o uart_tx_o scl_pd_o sda_pd_o}
    }
    default {
        puts "ERROR: arv_dtm: DTM_TYPE '$DTM_TYPE' is not 0..3"
        exit 1
    }
}

puts "arv_dtm wrapper: DTM_TYPE=$DTM_TYPE -> constraints of $DTM_TRANSPORT"
source -echo -verbose ./constraints_ports.${DTM_TRANSPORT}.tcl
