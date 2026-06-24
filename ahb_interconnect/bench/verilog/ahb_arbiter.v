//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    ahb_arbiter
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : ahb_arbiter.v
// Module Description : Behavioural AHB arbiter model for the testbench.
//----------------------------------------------------------------------------

module  ahb_arbiter (

// AHB CLOCK & RESET
    hclk_i,
    hresetn_i,

// ARBITER INTERFACES
    request_i,
    grant_o
);

// AHB CLOCK & RESET
//======================================
input           hclk_i;
input           hresetn_i;

// ARBITER INTERFACES
//======================================
input     [2:0] request_i;
output    [2:0] grant_o;


//=============================================================================
// 1)  INTERNAL WIRES/REGISTERS/PARAMETERS DECLARATION
//=============================================================================

wire    [6-1:0] double_request;
reg     [6-1:0] double_request_mask;
wire    [6-1:0] double_request_vector;
wire    [6-1:0] double_grant_vector;


//=============================================================================
// 2) REQUEST PREPROCESSING
//=============================================================================

// The request mask determines the priority order of the requests and is processed from LSB to MSB.
//       + Bit 0 is for AHB Master 0 (M0)
//       + Bit 1 is for AHB Master 1 (M1)
//       + Bit 2 is for AHB Master 2 (M2)
//       + Bit 3 is for AHB Master 0 (M0)
//       + Bit 4 is for AHB Master 1 (M1)
//       + Bit 5 is for AHB Master 2 (M2)   <-- unused (as wrap around to bit 0 when M2 is granted)
always @(posedge hclk_i or negedge hresetn_i)
  if (!hresetn_i)      double_request_mask  <= 6'b000111;  // Default priority order: 1. M0 / 2. M1 / 3. M2
  else if (grant_o[0]) double_request_mask  <= 6'b001110;  // If M0 granted         : 1. M1 / 2. M2 / 3. M0
  else if (grant_o[1]) double_request_mask  <= 6'b011100;  // If M1 granted         : 1. M2 / 2. M0 / 3. M1
  else if (grant_o[2]) double_request_mask  <= 6'b000111;  // If M2 granted         : 1. M0 / 2. M1 / 3. M2


// Create double request vector
assign double_request        = {request_i, request_i};

// Mask the Request with the Grant Mask
assign double_request_vector = double_request & double_request_mask;


//=============================================================================
// 3) GRANT GENERATION
//=============================================================================

// Function keeping the first 1 in a vector when scanning from LSB to MSB
function   [6-1:0] keep_first_one;
    input  [6-1:0] request_vector;
    begin
        keep_first_one[0]  = request_vector[0];
        keep_first_one[1]  = request_vector[1] & (keep_first_one[0]   == 1'b0    );
        keep_first_one[2]  = request_vector[2] & (keep_first_one[1:0] == 2'b00   );
        keep_first_one[3]  = request_vector[3] & (keep_first_one[2:0] == 3'b000  );
        keep_first_one[4]  = request_vector[4] & (keep_first_one[3:0] == 4'b0000 );
        keep_first_one[5]  = request_vector[5] & (keep_first_one[4:0] == 5'b00000);
    end
endfunction

// Generate the grant vector (keep the first 1 found when scanning from LSB to MSB)
assign double_grant_vector = keep_first_one(double_request_vector);

// Combine to generate the grant back
assign grant_o = double_grant_vector[5:3] |
                 double_grant_vector[2:0] ;


endmodule
