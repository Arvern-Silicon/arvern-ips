#----------------------------------------------------------------------------
#          _    _           Family:    aRVern System IPs
#         / \__/ \          Module:    constraints_ports.hiperf
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# File Name          : constraints_ports.hiperf.tcl
# Module Description : Boundary input/output delays for the high-performance
#                      AHB interconnect fabric (ahb_interconnect_hiperf).
#----------------------------------------------------------------------------

##############################################################################
#                                                                            #
#        BOUNDARY TIMINGS FOR THE HIGH-PERFORMANCE INTERCONNECT              #
#                                                                            #
##############################################################################

#=============================================#
#    EXECUTABLE AHB SUBORDINATE INTERFACES    #
#=============================================#

# Inputs
set S_X_HRDATA_DLY       [expr ($CLOCK_PERIOD/100) * 20]
set S_X_HREADYOUT_DLY    [expr ($CLOCK_PERIOD/100) * 20]
set S_X_HRESP_DLY        [expr ($CLOCK_PERIOD/100) * 20]

# Outputs
set S_X_HADDR_DLY        [expr ($CLOCK_PERIOD/100) * 60]
set S_X_HAUSER_DLY       [expr ($CLOCK_PERIOD/100) * 60]
set S_X_HBURST_DLY       [expr ($CLOCK_PERIOD/100) * 60]
set S_X_HMASTER_DLY      [expr ($CLOCK_PERIOD/100) * 60]
set S_X_HMASTLOCK_DLY    [expr ($CLOCK_PERIOD/100) * 60]
set S_X_HPROT_DLY        [expr ($CLOCK_PERIOD/100) * 60]
set S_X_HREADY_DLY       [expr ($CLOCK_PERIOD/100) * 60]
set S_X_HSEL_DLY         [expr ($CLOCK_PERIOD/100) * 60]
set S_X_HSIZE_DLY        [expr ($CLOCK_PERIOD/100) * 60]
set S_X_HTRANS_DLY       [expr ($CLOCK_PERIOD/100) * 60]
set S_X_HWDATA_DLY       [expr ($CLOCK_PERIOD/100) * 60]
set S_X_HWRITE_DLY       [expr ($CLOCK_PERIOD/100) * 60]

set_input_delay $S_X_HRDATA_DLY                 -max -clock "hclk"   [get_ports s_x_hrdata_i]
set_input_delay 0                               -min -clock "hclk"   [get_ports s_x_hrdata_i]

set_input_delay $S_X_HREADYOUT_DLY              -max -clock "hclk"   [get_ports s_x_hreadyout_i]
set_input_delay 0                               -min -clock "hclk"   [get_ports s_x_hreadyout_i]

set_input_delay $S_X_HRESP_DLY                  -max -clock "hclk"   [get_ports s_x_hresp_i]
set_input_delay 0                               -min -clock "hclk"   [get_ports s_x_hresp_i]


set_output_delay $S_X_HADDR_DLY      -add_delay -max -clock "hclk"   [get_ports s_x_haddr_o]
set_output_delay 0                              -min -clock "hclk"   [get_ports s_x_haddr_o]

set_output_delay $S_X_HAUSER_DLY     -add_delay -max -clock "hclk"   [get_ports s_x_hauser_o]
set_output_delay 0                              -min -clock "hclk"   [get_ports s_x_hauser_o]

set_output_delay $S_X_HBURST_DLY     -add_delay -max -clock "hclk"   [get_ports s_x_hburst_o]
set_output_delay 0                              -min -clock "hclk"   [get_ports s_x_hburst_o]

set_output_delay $S_X_HMASTER_DLY    -add_delay -max -clock "hclk"   [get_ports s_x_hmaster_o]
set_output_delay 0                              -min -clock "hclk"   [get_ports s_x_hmaster_o]

set_output_delay $S_X_HMASTLOCK_DLY  -add_delay -max -clock "hclk"   [get_ports s_x_hmastlock_o]
set_output_delay 0                              -min -clock "hclk"   [get_ports s_x_hmastlock_o]

set_output_delay $S_X_HPROT_DLY      -add_delay -max -clock "hclk"   [get_ports s_x_hprot_o]
set_output_delay 0                              -min -clock "hclk"   [get_ports s_x_hprot_o]

set_output_delay $S_X_HREADY_DLY     -add_delay -max -clock "hclk"   [get_ports s_x_hready_o]
set_output_delay 0                              -min -clock "hclk"   [get_ports s_x_hready_o]

set_output_delay $S_X_HSEL_DLY       -add_delay -max -clock "hclk"   [get_ports s_x_hsel_o]
set_output_delay 0                              -min -clock "hclk"   [get_ports s_x_hsel_o]

set_output_delay $S_X_HSIZE_DLY      -add_delay -max -clock "hclk"   [get_ports s_x_hsize_o]
set_output_delay 0                              -min -clock "hclk"   [get_ports s_x_hsize_o]

set_output_delay $S_X_HTRANS_DLY     -add_delay -max -clock "hclk"   [get_ports s_x_htrans_o]
set_output_delay 0                              -min -clock "hclk"   [get_ports s_x_htrans_o]

set_output_delay $S_X_HWDATA_DLY     -add_delay -max -clock "hclk"   [get_ports s_x_hwdata_o]
set_output_delay 0                              -min -clock "hclk"   [get_ports s_x_hwdata_o]

set_output_delay $S_X_HWRITE_DLY     -add_delay -max -clock "hclk"   [get_ports s_x_hwrite_o]
set_output_delay 0                              -min -clock "hclk"   [get_ports s_x_hwrite_o]
    

#=================================================#
#    NON-EXECUTABLE AHB SUBORDINATE INTERFACES    #
#=================================================#

# Inputs
set S_NX_HRDATA_DLY       [expr ($CLOCK_PERIOD/100) * 20]
set S_NX_HREADYOUT_DLY    [expr ($CLOCK_PERIOD/100) * 20]
set S_NX_HRESP_DLY        [expr ($CLOCK_PERIOD/100) * 20]

# Outputs
set S_NX_HADDR_DLY        [expr ($CLOCK_PERIOD/100) * 60]
set S_NX_HAUSER_DLY       [expr ($CLOCK_PERIOD/100) * 60]
set S_NX_HBURST_DLY       [expr ($CLOCK_PERIOD/100) * 60]
set S_NX_HMASTER_DLY      [expr ($CLOCK_PERIOD/100) * 60]
set S_NX_HMASTLOCK_DLY    [expr ($CLOCK_PERIOD/100) * 60]
set S_NX_HPROT_DLY        [expr ($CLOCK_PERIOD/100) * 60]
set S_NX_HREADY_DLY       [expr ($CLOCK_PERIOD/100) * 60]
set S_NX_HSEL_DLY         [expr ($CLOCK_PERIOD/100) * 60]
set S_NX_HSIZE_DLY        [expr ($CLOCK_PERIOD/100) * 60]
set S_NX_HTRANS_DLY       [expr ($CLOCK_PERIOD/100) * 60]
set S_NX_HWDATA_DLY       [expr ($CLOCK_PERIOD/100) * 60]
set S_NX_HWRITE_DLY       [expr ($CLOCK_PERIOD/100) * 60]


set_input_delay $S_NX_HRDATA_DLY                 -max -clock "hclk"   [get_ports s_nx_hrdata_i]
set_input_delay 0                                -min -clock "hclk"   [get_ports s_nx_hrdata_i]

set_input_delay $S_NX_HREADYOUT_DLY              -max -clock "hclk"   [get_ports s_nx_hreadyout_i]
set_input_delay 0                                -min -clock "hclk"   [get_ports s_nx_hreadyout_i]

set_input_delay $S_NX_HRESP_DLY                  -max -clock "hclk"   [get_ports s_nx_hresp_i]
set_input_delay 0                                -min -clock "hclk"   [get_ports s_nx_hresp_i]


set_output_delay $S_NX_HADDR_DLY      -add_delay -max -clock "hclk"   [get_ports s_nx_haddr_o]
set_output_delay 0                               -min -clock "hclk"   [get_ports s_nx_haddr_o]

set_output_delay $S_NX_HAUSER_DLY     -add_delay -max -clock "hclk"   [get_ports s_nx_hauser_o]
set_output_delay 0                               -min -clock "hclk"   [get_ports s_nx_hauser_o]

set_output_delay $S_NX_HBURST_DLY     -add_delay -max -clock "hclk"   [get_ports s_nx_hburst_o]
set_output_delay 0                               -min -clock "hclk"   [get_ports s_nx_hburst_o]

set_output_delay $S_NX_HMASTER_DLY    -add_delay -max -clock "hclk"   [get_ports s_nx_hmaster_o]
set_output_delay 0                               -min -clock "hclk"   [get_ports s_nx_hmaster_o]

set_output_delay $S_NX_HMASTLOCK_DLY  -add_delay -max -clock "hclk"   [get_ports s_nx_hmastlock_o]
set_output_delay 0                               -min -clock "hclk"   [get_ports s_nx_hmastlock_o]

set_output_delay $S_NX_HPROT_DLY      -add_delay -max -clock "hclk"   [get_ports s_nx_hprot_o]
set_output_delay 0                               -min -clock "hclk"   [get_ports s_nx_hprot_o]

set_output_delay $S_NX_HREADY_DLY     -add_delay -max -clock "hclk"   [get_ports s_nx_hready_o]
set_output_delay 0                               -min -clock "hclk"   [get_ports s_nx_hready_o]

set_output_delay $S_NX_HSEL_DLY       -add_delay -max -clock "hclk"   [get_ports s_nx_hsel_o]
set_output_delay 0                               -min -clock "hclk"   [get_ports s_nx_hsel_o]

set_output_delay $S_NX_HSIZE_DLY      -add_delay -max -clock "hclk"   [get_ports s_nx_hsize_o]
set_output_delay 0                               -min -clock "hclk"   [get_ports s_nx_hsize_o]

set_output_delay $S_NX_HTRANS_DLY     -add_delay -max -clock "hclk"   [get_ports s_nx_htrans_o]
set_output_delay 0                               -min -clock "hclk"   [get_ports s_nx_htrans_o]

set_output_delay $S_NX_HWDATA_DLY     -add_delay -max -clock "hclk"   [get_ports s_nx_hwdata_o]
set_output_delay 0                               -min -clock "hclk"   [get_ports s_nx_hwdata_o]

set_output_delay $S_NX_HWRITE_DLY     -add_delay -max -clock "hclk"   [get_ports s_nx_hwrite_o]
set_output_delay 0                               -min -clock "hclk"   [get_ports s_nx_hwrite_o]
    

#========================================#
#  EXECUTABLE AHB BUS MANAGER INTERFACE  #
#========================================#

# Inputs
set M_X_HADDR_DLY        [expr ($CLOCK_PERIOD/100) * 20]
set M_X_HAUSER_DLY       [expr ($CLOCK_PERIOD/100) * 20]
set M_X_HBURST_DLY       [expr ($CLOCK_PERIOD/100) * 20]
set M_X_HMASTLOCK_DLY    [expr ($CLOCK_PERIOD/100) * 20]
set M_X_HPROT_DLY        [expr ($CLOCK_PERIOD/100) * 20]
set M_X_HSIZE_DLY        [expr ($CLOCK_PERIOD/100) * 20]
set M_X_HTRANS_DLY       [expr ($CLOCK_PERIOD/100) * 20]
set M_X_HWDATA_DLY       [expr ($CLOCK_PERIOD/100) * 20]
set M_X_HWRITE_DLY       [expr ($CLOCK_PERIOD/100) * 20]

# Outputs
set M_X_HRDATA_DLY       [expr ($CLOCK_PERIOD/100) * 60]
set M_X_HREADY_DLY       [expr ($CLOCK_PERIOD/100) * 60]
set M_X_HRESP_DLY        [expr ($CLOCK_PERIOD/100) * 60]


set_input_delay $M_X_HADDR_DLY                 -max -clock "hclk"   [get_ports m_x_haddr_i]
set_input_delay 0                              -min -clock "hclk"   [get_ports m_x_haddr_i]

set_input_delay $M_X_HAUSER_DLY                -max -clock "hclk"   [get_ports m_x_hauser_i]
set_input_delay 0                              -min -clock "hclk"   [get_ports m_x_hauser_i]

set_input_delay $M_X_HBURST_DLY                -max -clock "hclk"   [get_ports m_x_hburst_i]
set_input_delay 0                              -min -clock "hclk"   [get_ports m_x_hburst_i]

set_input_delay $M_X_HMASTLOCK_DLY             -max -clock "hclk"   [get_ports m_x_hmastlock_i]
set_input_delay 0                              -min -clock "hclk"   [get_ports m_x_hmastlock_i]

set_input_delay $M_X_HPROT_DLY                 -max -clock "hclk"   [get_ports m_x_hprot_i]
set_input_delay 0                              -min -clock "hclk"   [get_ports m_x_hprot_i]

set_input_delay $M_X_HSIZE_DLY                 -max -clock "hclk"   [get_ports m_x_hsize_i]
set_input_delay 0                              -min -clock "hclk"   [get_ports m_x_hsize_i]

set_input_delay $M_X_HTRANS_DLY                -max -clock "hclk"   [get_ports m_x_htrans_i]
set_input_delay 0                              -min -clock "hclk"   [get_ports m_x_htrans_i]

set_input_delay $M_X_HWDATA_DLY                -max -clock "hclk"   [get_ports m_x_hwdata_i]
set_input_delay 0                              -min -clock "hclk"   [get_ports m_x_hwdata_i]

set_input_delay $M_X_HWRITE_DLY                -max -clock "hclk"   [get_ports m_x_hwrite_i]
set_input_delay 0                              -min -clock "hclk"   [get_ports m_x_hwrite_i]


set_output_delay $M_X_HRDATA_DLY    -add_delay -max -clock "hclk"   [get_ports m_x_hrdata_o]
set_output_delay 0                             -min -clock "hclk"   [get_ports m_x_hrdata_o]

set_output_delay $M_X_HREADY_DLY    -add_delay -max -clock "hclk"   [get_ports m_x_hready_o]
set_output_delay 0                             -min -clock "hclk"   [get_ports m_x_hready_o]

set_output_delay $M_X_HRESP_DLY     -add_delay -max -clock "hclk"   [get_ports m_x_hresp_o]
set_output_delay 0                             -min -clock "hclk"   [get_ports m_x_hresp_o]

#============================================#
#  NON-EXECUTABLE AHB BUS MANAGER INTERFACE  #
#============================================#

# Inputs
set M_NX_HADDR_DLY        [expr ($CLOCK_PERIOD/100) * 20]
set M_NX_HAUSER_DLY       [expr ($CLOCK_PERIOD/100) * 20]
set M_NX_HBURST_DLY       [expr ($CLOCK_PERIOD/100) * 20]
set M_NX_HMASTLOCK_DLY    [expr ($CLOCK_PERIOD/100) * 20]
set M_NX_HPROT_DLY        [expr ($CLOCK_PERIOD/100) * 20]
set M_NX_HSIZE_DLY        [expr ($CLOCK_PERIOD/100) * 20]
set M_NX_HTRANS_DLY       [expr ($CLOCK_PERIOD/100) * 20]
set M_NX_HWDATA_DLY       [expr ($CLOCK_PERIOD/100) * 20]
set M_NX_HWRITE_DLY       [expr ($CLOCK_PERIOD/100) * 20]

# Outputs
set M_NX_HRDATA_DLY       [expr ($CLOCK_PERIOD/100) * 60]
set M_NX_HREADY_DLY       [expr ($CLOCK_PERIOD/100) * 60]
set M_NX_HRESP_DLY        [expr ($CLOCK_PERIOD/100) * 60]


set_input_delay $M_NX_HADDR_DLY                 -max -clock "hclk"   [get_ports m_nx_haddr_i]
set_input_delay 0                               -min -clock "hclk"   [get_ports m_nx_haddr_i]

set_input_delay $M_NX_HAUSER_DLY                -max -clock "hclk"   [get_ports m_nx_hauser_i]
set_input_delay 0                               -min -clock "hclk"   [get_ports m_nx_hauser_i]

set_input_delay $M_NX_HBURST_DLY                -max -clock "hclk"   [get_ports m_nx_hburst_i]
set_input_delay 0                               -min -clock "hclk"   [get_ports m_nx_hburst_i]

set_input_delay $M_NX_HMASTLOCK_DLY             -max -clock "hclk"   [get_ports m_nx_hmastlock_i]
set_input_delay 0                               -min -clock "hclk"   [get_ports m_nx_hmastlock_i]

set_input_delay $M_NX_HPROT_DLY                 -max -clock "hclk"   [get_ports m_nx_hprot_i]
set_input_delay 0                               -min -clock "hclk"   [get_ports m_nx_hprot_i]

set_input_delay $M_NX_HSIZE_DLY                 -max -clock "hclk"   [get_ports m_nx_hsize_i]
set_input_delay 0                               -min -clock "hclk"   [get_ports m_nx_hsize_i]

set_input_delay $M_NX_HTRANS_DLY                -max -clock "hclk"   [get_ports m_nx_htrans_i]
set_input_delay 0                               -min -clock "hclk"   [get_ports m_nx_htrans_i]

set_input_delay $M_NX_HWDATA_DLY                -max -clock "hclk"   [get_ports m_nx_hwdata_i]
set_input_delay 0                               -min -clock "hclk"   [get_ports m_nx_hwdata_i]

set_input_delay $M_NX_HWRITE_DLY                -max -clock "hclk"   [get_ports m_nx_hwrite_i]
set_input_delay 0                               -min -clock "hclk"   [get_ports m_nx_hwrite_i]


set_output_delay $M_NX_HRDATA_DLY    -add_delay -max -clock "hclk"   [get_ports m_nx_hrdata_o]
set_output_delay 0                              -min -clock "hclk"   [get_ports m_nx_hrdata_o]

set_output_delay $M_NX_HREADY_DLY    -add_delay -max -clock "hclk"   [get_ports m_nx_hready_o]
set_output_delay 0                              -min -clock "hclk"   [get_ports m_nx_hready_o]

set_output_delay $M_NX_HRESP_DLY     -add_delay -max -clock "hclk"   [get_ports m_nx_hresp_o]
set_output_delay 0                              -min -clock "hclk"   [get_ports m_nx_hresp_o]


#=========================#
# REMAINING PORTS         #
#=========================#

set HCLK_EN_DLY           [expr ($CLOCK_PERIOD/100) * 70]

set M_NX_GRANT_DLY        [expr ($CLOCK_PERIOD/100) * 20]
set M_NX_REQUEST_DLY      [expr ($CLOCK_PERIOD/100) * 60]

set S_DECODER_1HOT_DLY    [expr ($CLOCK_PERIOD/100) * 20]
set S_DECODER_ADDR_DLY    [expr ($CLOCK_PERIOD/100) * 60]

set S_X_DECODER_1HOT_DLY  [expr ($CLOCK_PERIOD/100) * 20]
set S_X_DECODER_ADDR_DLY  [expr ($CLOCK_PERIOD/100) * 60]


# CLOCK ENABLE
set_output_delay $HCLK_EN_DLY           -add_delay -max -clock "hclk"   [get_ports hclk_en_o]
set_output_delay 0                                 -min -clock "hclk"   [get_ports hclk_en_o]

# ARBITER INTERFACE FOR NON-EXECUTABLE MANAGERS
set_input_delay $M_NX_GRANT_DLY                    -max -clock "hclk"   [get_ports m_nx_grant_i]
set_input_delay 0                                  -min -clock "hclk"   [get_ports m_nx_grant_i]

set_output_delay $M_NX_REQUEST_DLY      -add_delay -max -clock "hclk"   [get_ports m_nx_request_o]
set_output_delay 0                                 -min -clock "hclk"   [get_ports m_nx_request_o]

# ADDRESS DECODER INTERFACES (FOR ALL SUBORDINATES)
set_input_delay $S_DECODER_1HOT_DLY                -max -clock "hclk"   [get_ports s_decoder_1hot_i]
set_input_delay 0                                  -min -clock "hclk"   [get_ports s_decoder_1hot_i]

set_output_delay $S_DECODER_ADDR_DLY    -add_delay -max -clock "hclk"   [get_ports s_decoder_addr_o]
set_output_delay 0                                 -min -clock "hclk"   [get_ports s_decoder_addr_o]

# ADDRESS DECODER INTERFACES (FOR EXECUTABLE SUBORDINATES ONLY)
set_input_delay $S_X_DECODER_1HOT_DLY              -max -clock "hclk"   [get_ports s_x_decoder_1hot_i]
set_input_delay 0                                  -min -clock "hclk"   [get_ports s_x_decoder_1hot_i]

set_output_delay $S_X_DECODER_ADDR_DLY  -add_delay -max -clock "hclk"   [get_ports s_x_decoder_addr_o]
set_output_delay 0                                 -min -clock "hclk"   [get_ports s_x_decoder_addr_o]


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
