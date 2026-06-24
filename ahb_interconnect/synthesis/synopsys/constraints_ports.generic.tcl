#----------------------------------------------------------------------------
#          _    _           Family:    aRVern System IPs
#         / \__/ \          Module:    constraints_ports.generic
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# File Name          : constraints_ports.generic.tcl
# Module Description : Boundary input/output delays for the generic AHB
#                      interconnect fabric (ahb_interconnect_generic).
#----------------------------------------------------------------------------

##############################################################################
#                                                                            #
#           BOUNDARY TIMINGS FOR THE GENERIC INTERCONNECT                    #
#                                                                            #
##############################################################################

#==================================#
#    AHB SUBORDINATE INTERFACES    #
#==================================#

# Inputs
set S_HRDATA_DLY       [expr ($CLOCK_PERIOD/100) * 20]
set S_HREADYOUT_DLY    [expr ($CLOCK_PERIOD/100) * 20]
set S_HRESP_DLY        [expr ($CLOCK_PERIOD/100) * 20]

# Outputs
set S_HADDR_DLY        [expr ($CLOCK_PERIOD/100) * 60]
set S_HAUSER_DLY       [expr ($CLOCK_PERIOD/100) * 60]
set S_HBURST_DLY       [expr ($CLOCK_PERIOD/100) * 60]
set S_HMASTER_DLY      [expr ($CLOCK_PERIOD/100) * 60]
set S_HMASTLOCK_DLY    [expr ($CLOCK_PERIOD/100) * 60]
set S_HPROT_DLY        [expr ($CLOCK_PERIOD/100) * 60]
set S_HREADY_DLY       [expr ($CLOCK_PERIOD/100) * 60]
set S_HSEL_DLY         [expr ($CLOCK_PERIOD/100) * 60]
set S_HSIZE_DLY        [expr ($CLOCK_PERIOD/100) * 60]
set S_HTRANS_DLY       [expr ($CLOCK_PERIOD/100) * 60]
set S_HWDATA_DLY       [expr ($CLOCK_PERIOD/100) * 60]
set S_HWRITE_DLY       [expr ($CLOCK_PERIOD/100) * 60]


set_input_delay $S_HRDATA_DLY                 -max -clock "hclk"   [get_ports s_hrdata_i]
set_input_delay 0                             -min -clock "hclk"   [get_ports s_hrdata_i]

set_input_delay $S_HREADYOUT_DLY              -max -clock "hclk"   [get_ports s_hreadyout_i]
set_input_delay 0                             -min -clock "hclk"   [get_ports s_hreadyout_i]

set_input_delay $S_HRESP_DLY                  -max -clock "hclk"   [get_ports s_hresp_i]
set_input_delay 0                             -min -clock "hclk"   [get_ports s_hresp_i]


set_output_delay $S_HADDR_DLY      -add_delay -max -clock "hclk"   [get_ports s_haddr_o]
set_output_delay 0                            -min -clock "hclk"   [get_ports s_haddr_o]

set_output_delay $S_HAUSER_DLY     -add_delay -max -clock "hclk"   [get_ports s_hauser_o]
set_output_delay 0                            -min -clock "hclk"   [get_ports s_hauser_o]

set_output_delay $S_HBURST_DLY     -add_delay -max -clock "hclk"   [get_ports s_hburst_o]
set_output_delay 0                            -min -clock "hclk"   [get_ports s_hburst_o]

set_output_delay $S_HMASTER_DLY    -add_delay -max -clock "hclk"   [get_ports s_hmaster_o]
set_output_delay 0                            -min -clock "hclk"   [get_ports s_hmaster_o]

set_output_delay $S_HMASTLOCK_DLY  -add_delay -max -clock "hclk"   [get_ports s_hmastlock_o]
set_output_delay 0                            -min -clock "hclk"   [get_ports s_hmastlock_o]

set_output_delay $S_HPROT_DLY      -add_delay -max -clock "hclk"   [get_ports s_hprot_o]
set_output_delay 0                            -min -clock "hclk"   [get_ports s_hprot_o]

set_output_delay $S_HREADY_DLY     -add_delay -max -clock "hclk"   [get_ports s_hready_o]
set_output_delay 0                            -min -clock "hclk"   [get_ports s_hready_o]

set_output_delay $S_HSEL_DLY       -add_delay -max -clock "hclk"   [get_ports s_hsel_o]
set_output_delay 0                            -min -clock "hclk"   [get_ports s_hsel_o]

set_output_delay $S_HSIZE_DLY      -add_delay -max -clock "hclk"   [get_ports s_hsize_o]
set_output_delay 0                            -min -clock "hclk"   [get_ports s_hsize_o]

set_output_delay $S_HTRANS_DLY     -add_delay -max -clock "hclk"   [get_ports s_htrans_o]
set_output_delay 0                            -min -clock "hclk"   [get_ports s_htrans_o]

set_output_delay $S_HWDATA_DLY     -add_delay -max -clock "hclk"   [get_ports s_hwdata_o]
set_output_delay 0                            -min -clock "hclk"   [get_ports s_hwdata_o]

set_output_delay $S_HWRITE_DLY     -add_delay -max -clock "hclk"   [get_ports s_hwrite_o]
set_output_delay 0                            -min -clock "hclk"   [get_ports s_hwrite_o]
    

#==================================#
#       AHB MANAGER INTERFACE      #
#==================================#

# Inputs
set M_HADDR_DLY        [expr ($CLOCK_PERIOD/100) * 20]
set M_HAUSER_DLY       [expr ($CLOCK_PERIOD/100) * 20]
set M_HBURST_DLY       [expr ($CLOCK_PERIOD/100) * 20]
set M_HMASTLOCK_DLY    [expr ($CLOCK_PERIOD/100) * 20]
set M_HPROT_DLY        [expr ($CLOCK_PERIOD/100) * 20]
set M_HSIZE_DLY        [expr ($CLOCK_PERIOD/100) * 20]
set M_HTRANS_DLY       [expr ($CLOCK_PERIOD/100) * 20]
set M_HWDATA_DLY       [expr ($CLOCK_PERIOD/100) * 20]
set M_HWRITE_DLY       [expr ($CLOCK_PERIOD/100) * 20]

# Outputs
set M_HRDATA_DLY       [expr ($CLOCK_PERIOD/100) * 60]
set M_HREADY_DLY       [expr ($CLOCK_PERIOD/100) * 60]
set M_HRESP_DLY        [expr ($CLOCK_PERIOD/100) * 60]


set_input_delay $M_HADDR_DLY                 -max -clock "hclk"   [get_ports m_haddr_i]
set_input_delay 0                            -min -clock "hclk"   [get_ports m_haddr_i]

set_input_delay $M_HAUSER_DLY                -max -clock "hclk"   [get_ports m_hauser_i]
set_input_delay 0                            -min -clock "hclk"   [get_ports m_hauser_i]

set_input_delay $M_HBURST_DLY                -max -clock "hclk"   [get_ports m_hburst_i]
set_input_delay 0                            -min -clock "hclk"   [get_ports m_hburst_i]

set_input_delay $M_HMASTLOCK_DLY             -max -clock "hclk"   [get_ports m_hmastlock_i]
set_input_delay 0                            -min -clock "hclk"   [get_ports m_hmastlock_i]

set_input_delay $M_HPROT_DLY                 -max -clock "hclk"   [get_ports m_hprot_i]
set_input_delay 0                            -min -clock "hclk"   [get_ports m_hprot_i]

set_input_delay $M_HSIZE_DLY                 -max -clock "hclk"   [get_ports m_hsize_i]
set_input_delay 0                            -min -clock "hclk"   [get_ports m_hsize_i]

set_input_delay $M_HTRANS_DLY                -max -clock "hclk"   [get_ports m_htrans_i]
set_input_delay 0                            -min -clock "hclk"   [get_ports m_htrans_i]

set_input_delay $M_HWDATA_DLY                -max -clock "hclk"   [get_ports m_hwdata_i]
set_input_delay 0                            -min -clock "hclk"   [get_ports m_hwdata_i]

set_input_delay $M_HWRITE_DLY                -max -clock "hclk"   [get_ports m_hwrite_i]
set_input_delay 0                            -min -clock "hclk"   [get_ports m_hwrite_i]


set_output_delay $M_HRDATA_DLY    -add_delay -max -clock "hclk"   [get_ports m_hrdata_o]
set_output_delay 0                           -min -clock "hclk"   [get_ports m_hrdata_o]

set_output_delay $M_HREADY_DLY    -add_delay -max -clock "hclk"   [get_ports m_hready_o]
set_output_delay 0                           -min -clock "hclk"   [get_ports m_hready_o]

set_output_delay $M_HRESP_DLY     -add_delay -max -clock "hclk"   [get_ports m_hresp_o]
set_output_delay 0                           -min -clock "hclk"   [get_ports m_hresp_o]


#=========================#
# REMAINING PORTS         #
#=========================#

set HCLK_EN_DLY         [expr ($CLOCK_PERIOD/100) * 70]

set M_GRANT_DLY         [expr ($CLOCK_PERIOD/100) * 20]
set M_REQUEST_DLY       [expr ($CLOCK_PERIOD/100) * 60]

set S_DECODER_1HOT_DLY  [expr ($CLOCK_PERIOD/100) * 20]
set S_DECODER_ADDR_DLY  [expr ($CLOCK_PERIOD/100) * 60]


# CLOCK ENABLE
set_output_delay $HCLK_EN_DLY         -add_delay -max -clock "hclk"   [get_ports hclk_en_o]
set_output_delay 0                               -min -clock "hclk"   [get_ports hclk_en_o]

# ARBITER INTERFACES
set_input_delay $M_GRANT_DLY                     -max -clock "hclk"   [get_ports m_grant_i]
set_input_delay 0                                -min -clock "hclk"   [get_ports m_grant_i]

set_output_delay $M_REQUEST_DLY       -add_delay -max -clock "hclk"   [get_ports m_request_o]
set_output_delay 0                               -min -clock "hclk"   [get_ports m_request_o]

# ADDRESS DECODER INTERFACES
set_input_delay $S_DECODER_1HOT_DLY              -max -clock "hclk"   [get_ports s_decoder_1hot_i]
set_input_delay 0                                -min -clock "hclk"   [get_ports s_decoder_1hot_i]

set_output_delay $S_DECODER_ADDR_DLY  -add_delay -max -clock "hclk"   [get_ports s_decoder_addr_o]
set_output_delay 0                               -min -clock "hclk"   [get_ports s_decoder_addr_o]


#========================#
# FEEDTHROUGH EXCEPTIONS #
#========================#

#set_max_delay [expr 2.0 + $DMEM_DOUT_DLY + $DMEM_ADDR_DLY] \
#              -from       [get_ports dmem_dout]            \
#              -to         [get_ports dmem_addr]            \
#              -group_path FEEDTHROUGH


#===============#
# FALSE PATHS   #
#===============#

set_false_path -from hresetn_i
