/*
address decoder
Capacity : (1)128Mb, (2)256Mb, (3)512Mb, (4)1Gb
Data Width : (1)x4, (2)x8,(3)x16

address_decoder_function:
Function		address	 value
DESELECT (NOP) 		X 	   0
NO OPERATION(NOP) 	X	   1
ACTIVE			Bank/Row   2
READ			Bank/Col   3
WRITE			Bank/Col   4
BURST TERMINATE 	X	   5
PRECHARGE		  Code	   6
AUTO/Self refresh	X	   7
MODEREGISTER SET Op-Code   8
*/


module address_decoder #(
parameter CAPACITY = 4,
parameter DATA_WIDTH = 2,
localparam ROW_WIDTH = (CAPACITY == 1) ? 12 : (CAPACITY == 2 || CAPACITY == 3) ? 13 : 14,
localparam COL_WIDTH = (CAPACITY == 1 || CAPACITY == 2) ? (DATA_WIDTH == 1) ? 11 :
														  (DATA_WIDTH == 2) ? 10 :
														  9:
														  (DATA_WIDTH == 1) ? 12 :
														  (DATA_WIDTH == 2) ? 11 :
														  10
)(
input logic [15:0] address,
input logic [3:0] adf, //address_decoder_function: It determines whether the address is row/col addresses or opcodes
//input logic RASn, // Row Address Strobe
//input logic CASn, // Column Address Strobe
//input logic WEn, // Write Enable
//input logic CSn, // Chip Select
output logic [1:0] BA, // Bank Address
output logic [2:0] burst_len,
output logic burst_type,
output logic [2:0] CL, //CAS Latency
output logic [6:0] operating_mode,
output logic [ROW_WIDTH-1:0] row_add,
output logic [COL_WIDTH-1:0] col_add,
output logic ap //Auto Precharge
);
localparam cw = (COL_WIDTH >=11) ? COL_WIDTH : 11;
assign BA = address[15:14];

always_comb
	begin
		if (adf==2)
			row_add = address[ROW_WIDTH-1:0];

		if (adf==3 || adf==4)
			begin
				if(COL_WIDTH <11)
					col_add = address[COL_WIDTH-1:0];
				else
					col_add = {address[cw:11], address[9:0]};
			end

		if(adf==3 || adf==4 || adf == 6)
			ap = address[10];

		if(adf==8)
			begin
				operating_mode = address[13:7];
				CL = address[6:4];
				burst_type = address[3];
				burst_len = address[2:0];
			end
	end
endmodule