#!/bin/bash
#----------------------------------------------------------------------------
#          _    _           Family:    aRVern System IPs
#         / \__/ \          Module:    rtlsim
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# File Name          : rtlsim.sh
# Module Description : RTL simulation driver script.
#----------------------------------------------------------------------------

if [ $# -lt 5 ] || [ $# -gt 6 ]; then
  echo "ERROR    : wrong number of arguments"
  echo "USAGE    : rtlsim.sh <verilog stimulus file> <submit file>   <seed>  <design>  <wait-state>  [<extra-define>]"
  echo "Example  : rtlsim.sh ./stimulus.v            ../../../bench/verilog/submit.f  123    HIPERF    RANDOM_WS     FUSED_FIXED_B_PRIO"
  echo "VERILOG_SIMULATOR env keeps simulator name iverilog/cver/verilog/ncverilog/vsim/vcs"
  exit 1
fi

# Optional 6th argument: extra macro define (empty if not used)
EXTRA_DEFINE_IV=""
EXTRA_DEFINE_VARGS=""
if [ $# -eq 6 ] && [ -n "$6" ]; then
    EXTRA_DEFINE_IV="-D $6"
    EXTRA_DEFINE_VARGS="-D $6"
fi

# Optional environment passthrough for additional build-time defines (e.g.
# synchronous-reset coverage: SIM_EXTRA_DEFINES="-D ASYNC_RST_EN=0").  The
# variable is appended verbatim and already carries its own "-D" token(s);
# when unset it expands to nothing and is a no-op.
SIM_EXTRA_DEFINES=${SIM_EXTRA_DEFINES:-}


###############################################################################
#                     Check if the required files exist                       #
###############################################################################

if [ ! -e $1 ]; then
    echo "Verilog stimulus file $1 doesn't exist"
    exit 1
fi
if [ ! -e $2 ]; then
    echo "Verilog submit file $2 doesn't exist"
    exit 1
fi


###############################################################################
#               Flatten the submit filelist to absolute paths                 #
###############################################################################
# Each IP's rtl/verilog/filelist.f uses paths relative to the filelist's own
# directory (Option-2 portable-filelist scheme).  flatten_filelist.py walks
# the -f tree, resolves every entry against its containing filelist's dir,
# and emits one absolute-path flat file safe to pass to any simulator
# regardless of cwd.
#
# The flattened result is dropped into the cwd as `submit_sim.f` so it's
# easy to inspect for debugging (e.g. when a file is mis-located or a
# nested -f doesn't resolve).  The file is overwritten on every run.

FLATTEN_PY="$(dirname "$(realpath "$0")")/flatten_filelist.py"
SUBMIT_F="./submit_sim.f"
"$FLATTEN_PY" "$2" "$SUBMIT_F" >/dev/null


###############################################################################
#                         Start verilog simulation                            #
###############################################################################

if [ "${VERILOG_SIMULATOR:-iverilog}" = iverilog ]; then

    rm -rf simv

    NODUMP=${SIMULATION_NODUMP-0}
    if [ $NODUMP -eq 1 ]
      then
        iverilog -o simv -c $SUBMIT_F -D SEED=$3 -D $4 -D $5 $EXTRA_DEFINE_IV $SIM_EXTRA_DEFINES -D NODUMP
      else
        iverilog -o simv -c $SUBMIT_F -D SEED=$3 -D $4 -D $5 $EXTRA_DEFINE_IV $SIM_EXTRA_DEFINES
    fi

    if [[ $(uname -s) == CYGWIN* ]];
    then
     	vvp.exe ./simv
    else
        ./simv
    fi

else

    NODUMP=${SIMULATION_NODUMP-0}
    if [ $NODUMP -eq 1 ] ; then
       vargs="+define+SEED=$3 -D $4 -D $5 $EXTRA_DEFINE_VARGS $SIM_EXTRA_DEFINES +define+NODUMP"
    else
       vargs="+define+SEED=$3 -D $4 -D $5 $EXTRA_DEFINE_VARGS $SIM_EXTRA_DEFINES"
    fi

   case $VERILOG_SIMULATOR in
    cver* )
       vargs="$vargs +define+VXL +define+CVER" ;;
    verilog* )
       vargs="$vargs +define+VXL" ;;
    ncverilog* )
       rm -rf INCA_libs
       vargs="$vargs +access+r +svseed=$3 +nclicq +define+TRN_FILE" ;;
    vcs* )
       rm -rf csrc simv*
       vargs="$vargs -lca -debug_access+all -sverilog +define+VPD_FILE" ;;
    vsim* )
       # Modelsim
       if [ -d work ]; then  vdel -all; fi
       vlib work
       exec vlog +acc=prn -f $SUBMIT_F $vargs -R -c -do "run -all" ;;
    isim )
       # Xilinx simulator
       rm -rf fuse* isim*
       fuse tb_openMSP430 -prj $SUBMIT_F -o isim.exe -i ../../../bench/verilog/ -i ../../../rtl/verilog/
       echo "run all" > isim.tcl
       ./isim.exe -tclbatch isim.tcl
       exit
   esac

   echo "Running: $VERILOG_SIMULATOR -f $SUBMIT_F $vargs"
   exec $VERILOG_SIMULATOR -f $SUBMIT_F $vargs
fi
