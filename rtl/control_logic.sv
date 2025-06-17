module ddr_sdram_control_logic(
	input logic clk,
	input logic clkn,
	input logic cke,
	input logic cs_n,
	input logic ras_n,
	input logic cas_n,
	input logic we_n,
	input logic [13:0] addr,
	input logic [1:0] ba,
	input logic dm,
	inout logic [15:0] dq,
	inout logic dqs
);

parameter tDSGN = 32'h41594148;
parameter ROW_WIDTH = 14;
parameter COL_WIDTH = 10;
logic [3:0] burst_counter = 'b0;
logic [ROW_WIDTH-1:0] row_addr [4] = '{default:'bx};		// Address Signals
logic [1:0] p_ba;						// Previous selected Bank
logic [1:0] c_ba;						// Current selected Bank
logic [COL_WIDTH-1:0] col_addr; 
logic [2:0] burst_len; 
logic burst_type;
logic [2:0] cas_latency;      
logic [6:0]operating_mode;	  
logic ap;					  
logic [15:0] data_in_reg;		// Input data buffer
logic [15:0] data_out_reg;		// Output data buffer
logic dqs_en = 0;                 
logic dq_en = 0;
logic clk2x = 0;                  
logic cke_ps, cke_cs;         // cke previous/current state

// Address decoder signals
logic [ROW_WIDTH-1:0] d_row_add;       
logic [COL_WIDTH-1:0] d_col_add;       
logic d_ap;                   // Precharge all flag

// Memory Array signals
logic row_active [4] = '{default:'b0};
logic read_active = 0, write_active = 0;
logic [3:0] burst_length;
logic burst_stop;
memory_array m1(
	.clk(clk),
	.clkn(clkn),
	.ca(d_col_add),			//Column Address
	.ra(row_addr),		//Row Address
	.ba(c_ba),					//Bank Address
	.data_in(data_in_reg),
	.burst_len(burst_len),			//from Address Bus
	.burst_type(burst_type),
	.row_active(row_active),
	.read_active(read_active),
	.write_active(write_active),
	.burst_stop(burst_stop),
	.data_out(data_out_reg),
	.burst_length(burst_length)
);

typedef enum logic [3:0] {
    IDLE                   = 4'b0000,
    MODE_REGISTER_SET      = 4'b0001,
    ACTIVE                 = 4'b0010,
    READ                   = 4'b0011,
    WRITE                  = 4'b0100,
    PRECHARGE              = 4'b0101,
    AUTO_REFRESH           = 4'b0110,
    SELF_REFRESH           = 4'b0111,
    POWER_DOWN             = 4'b1000,
    READ_WITH_AUTOPRECHARGE= 4'b1001,
    WRITE_WITH_AUTOPRECHARGE=4'b1010,
    BURST_STOP             = 4'b1011,
	NOP					   = 4'b1100
} state_t;

state_t current_state, next_state, previous_state;

typedef enum logic [2:0] {
    BANK_IDLE		= 3'b000,
    BANK_ACTIVE		= 3'b001,
    BANK_READ		= 3'b010,
	BANK_READ_AP	= 3'b011,
	BANK_WRITE_AP	= 3'b100,
    BANK_WRITE		= 3'b101,
    BANK_PRECHARGE	= 3'b110
} bank_state_t;

bank_state_t bank_states [0:3] = '{default:BANK_IDLE} , bank_next_state; // 4 banks
logic [3:0] bank_active;        // Tracks which banks have active rows
logic [15:0] data_reg [8];
logic [15:0] dq_reg;
assign burst_stop = (current_state == BURST_STOP) ? 1 : 0;

//FSM
always_comb begin
	//Address decode
	if (current_state != READ_WITH_AUTOPRECHARGE && current_state != WRITE_WITH_AUTOPRECHARGE) begin
		c_ba = ba;
		if (current_state == ACTIVE && !((!cs_n && ras_n && !cas_n && we_n) || (!cs_n && ras_n && !cas_n && !we_n))) begin
			d_row_add = addr [ROW_WIDTH-1:0];
		end
		ap = addr[10];
	end
	if (current_state == READ || current_state == READ_WITH_AUTOPRECHARGE || current_state == WRITE || current_state == WRITE_WITH_AUTOPRECHARGE) begin
		d_col_add [9:0] = addr [COL_WIDTH-1:0];
	end
	cke_cs = cke;
    case (current_state)	//FSM start
        IDLE: begin
            if (!cs_n && !ras_n && !cas_n && !we_n) begin
				next_state = MODE_REGISTER_SET;
            end else if (!cs_n && !ras_n && cas_n && we_n && cke) begin
				next_state = ACTIVE;
				bank_next_state = BANK_ACTIVE; 
            end else if (!cs_n && !ras_n && !cas_n && we_n && cke) begin
				next_state = AUTO_REFRESH;
            end else if (!cs_n && !ras_n && !cas_n && we_n && !cke_cs ) begin
                next_state = SELF_REFRESH;
            end else if (!cs_n && !ras_n && cas_n && !we_n) begin
                next_state = PRECHARGE; // IDLE to PRECHARGE
				d_ap = ap;
            end else if (!cs_n && ras_n && cas_n && we_n && !cke_cs) begin
                next_state = POWER_DOWN;
            end else if(cs_n || !cs_n && ras_n && cas_n && we_n) begin
                next_state = IDLE; // Default to IDLE
				bank_next_state = BANK_IDLE;
            end
        end

        MODE_REGISTER_SET: begin
            next_state = IDLE;
        end

        ACTIVE: begin
			if (!cs_n && !ras_n && cas_n && we_n) begin
				next_state = ACTIVE;		//other bank activation
				bank_next_state = BANK_ACTIVE;
            end else if (!cs_n && ras_n && !cas_n && we_n && ap) begin
				next_state = READ_WITH_AUTOPRECHARGE;	//other Bank READ with AUTOPRECHARGE
				bank_next_state = BANK_READ_AP;
			end else if (!cs_n && ras_n && !cas_n && we_n) begin
				next_state = READ;			//other Bank READ
				bank_next_state = BANK_READ;
            end else if (!cs_n && ras_n && !cas_n && !we_n && ap) begin
				next_state = WRITE_WITH_AUTOPRECHARGE;	//other Bank WRITE with AUTOPRECHARGE
				bank_next_state = BANK_WRITE_AP;
			end else if (!cs_n && ras_n && !cas_n && !we_n) begin
				next_state = WRITE;			//other Bank WRITE
				bank_next_state = BANK_WRITE;
            end else if (!cs_n && !ras_n && cas_n && !we_n) begin
				next_state = PRECHARGE; //other Bank Precharge
				d_ap = ap;
            end else if (cke_ps && !cke_cs) begin
                next_state = POWER_DOWN; // ACTIVE to POWER_DOWN
            end else begin
                next_state = ACTIVE; // Default to ACTIVE
				bank_next_state = BANK_ACTIVE;
            end
        end

        READ: begin
			if (!cs_n && !ras_n && cas_n && we_n) begin
				next_state = ACTIVE;		//other bank activation
				bank_next_state = BANK_ACTIVE;
            end else if (!cs_n && ras_n && !cas_n && we_n && ap) begin
				next_state = READ_WITH_AUTOPRECHARGE;	//other Bank READ with AUTOPRECHARGE
				bank_next_state = BANK_READ_AP;
			end else if (!cs_n && ras_n && !cas_n && we_n) begin
				next_state = READ;		//other bank READ
				bank_next_state = BANK_READ;
			end else if (!cs_n && ras_n && !cas_n && !we_n && ap) begin
				next_state = WRITE_WITH_AUTOPRECHARGE;	//other Bank WRITE with AUTOPRECHARGE
				bank_next_state = BANK_WRITE_AP;
			end else if (!cs_n && ras_n && !cas_n && !we_n) begin
				next_state = WRITE;			//other Bank WRITE
				bank_next_state = BANK_WRITE;
			end else if (!cs_n && !ras_n && cas_n && !we_n) begin
				next_state = PRECHARGE; //other Bank Precharge
				d_ap = 0;
			end else if (!cs_n && ras_n && cas_n && !we_n) begin
                next_state = BURST_STOP; // READ to BURST_STOP
            end else begin
                next_state = ACTIVE;
				bank_next_state = BANK_ACTIVE;
            end
        end

        READ_WITH_AUTOPRECHARGE: begin
			if (!cs_n && !ras_n && cas_n && we_n) begin
				next_state = ACTIVE;		//other bank activation
				bank_next_state = BANK_ACTIVE;
			end else if (!cs_n && ras_n && !cas_n && we_n && ap) begin
				next_state = READ_WITH_AUTOPRECHARGE;	//other Bank READ with AUTOPRECHARGE
				bank_next_state = BANK_READ_AP;
			end else if (!cs_n && ras_n && !cas_n && we_n) begin
				next_state = READ;		//other bank READ
				bank_next_state = BANK_READ;
			end else if (!cs_n && ras_n && !cas_n && !we_n && ap) begin
				next_state = WRITE_WITH_AUTOPRECHARGE;	//other Bank WRITE with AUTOPRECHARGE
				bank_next_state = BANK_WRITE_AP;
			end else if (!cs_n && ras_n && !cas_n && !we_n) begin
				next_state = WRITE;			//other Bank WRITE
				bank_next_state = BANK_WRITE;
			end else begin
				next_state = PRECHARGE;
				bank_next_state = BANK_PRECHARGE;
			end
        end

        WRITE: begin
			if (!cs_n && !ras_n && cas_n && we_n) begin
				next_state = ACTIVE;		//other bank activation
				bank_next_state = BANK_ACTIVE;
            end else if (!cs_n && ras_n && !cas_n && !we_n && ap) begin
				next_state = WRITE_WITH_AUTOPRECHARGE;	//other Bank WRITE with AUTOPRECHARGE
				bank_next_state = BANK_WRITE_AP;
			end else if (!cs_n && ras_n && !cas_n && !we_n) begin
				next_state = WRITE;			//other Bank WRITE
				bank_next_state = BANK_WRITE;
			end else if (!cs_n && ras_n && !cas_n && we_n && ap) begin
				next_state = READ_WITH_AUTOPRECHARGE;	//other Bank READ with AUTOPRECHARGE
				bank_next_state = BANK_READ_AP;
			end else if (!cs_n && ras_n && !cas_n && we_n) begin
				next_state = READ;		//other bank READ
				bank_next_state = BANK_READ;
            end else if (!cs_n && !ras_n && cas_n && !we_n) begin
				next_state = PRECHARGE; //other Bank Precharge
				d_ap = 0;
            end else begin
                next_state = ACTIVE;
				bank_next_state = BANK_ACTIVE;
            end
        end

        WRITE_WITH_AUTOPRECHARGE: begin
			if (c_ba != p_ba) begin
			if (!cs_n && !ras_n && cas_n && we_n) begin
				next_state = ACTIVE;		//other bank activation
				bank_next_state = BANK_ACTIVE;
			end else if (!cs_n && ras_n && !cas_n && !we_n && ap) begin
				next_state = WRITE_WITH_AUTOPRECHARGE;	//other Bank WRITE with AUTOPRECHARGE
				bank_next_state = BANK_WRITE_AP;
			end else if (!cs_n && ras_n && !cas_n && !we_n) begin
				next_state = WRITE;			//other Bank WRITE
				bank_next_state = BANK_WRITE;
			end else if (!cs_n && ras_n && !cas_n && we_n && ap) begin
				next_state = READ_WITH_AUTOPRECHARGE;	//other Bank READ with AUTOPRECHARGE
				bank_next_state = BANK_READ_AP;
			end else if (!cs_n && ras_n && !cas_n && we_n) begin
				next_state = READ;		//other bank READ
				bank_next_state = BANK_READ;
			end end else begin
				next_state = PRECHARGE;
				bank_next_state = BANK_PRECHARGE;
			end
		end

        PRECHARGE: begin
            next_state = IDLE;
			bank_next_state = BANK_IDLE;
        end

        AUTO_REFRESH: begin
            next_state = IDLE; // AUTO_REFRESH to IDLE
        end

        SELF_REFRESH: begin
            if (!cke_ps && cke_cs) begin
				
					next_state = IDLE; //
				
            end else if (!cke_cs) begin
                next_state = SELF_REFRESH; // Maintain SELF_REFRESH
            end
        end

        POWER_DOWN: begin
            if (cke_cs) begin
				
					if (previous_state == ACTIVE) begin
						next_state = ACTIVE; // POWER_DOWN to ACTIVE
					end else begin
						next_state = IDLE; // POWER_DOWN to IDLE (if not from ACTIVE)
					end 
				
            end else if (!cke_cs) begin
                next_state = POWER_DOWN; // Maintain POWER_DOWN
            end
        end

        BURST_STOP: begin
            next_state = IDLE; // BURST_STOP to IDLE
        end

        default: begin
            next_state = IDLE; // Fallback to IDLE
        end
    endcase
end

always_ff @(posedge clk) begin
	previous_state <= current_state; // Update previous_state
	cke_ps <= cke_cs;
	current_state <= next_state;
	p_ba <= c_ba;
	bank_states[c_ba] <= bank_next_state;
	//state change control
	if (next_state != current_state) begin
	case (current_state)
		READ: begin
			if (burst_counter >= burst_length) begin
				previous_state <= current_state;
				current_state <= next_state;
				p_ba <= c_ba;
				bank_states[c_ba] <= bank_next_state;
				burst_counter <= 0;
				
			end else current_state <= current_state;
		end
		WRITE: begin
			if (burst_counter >= burst_length) begin
				previous_state <= current_state;
				current_state <= next_state;
				p_ba <= c_ba;
				bank_states[c_ba] <= bank_next_state;
				burst_counter <= 0;
				write_active <= 1'b0;
				data_in_reg <= 16'bx;
				data_reg <= '{default:16'bx};
			end else current_state <= current_state;
		end
		WRITE_WITH_AUTOPRECHARGE: begin
			if (burst_counter >= burst_length) begin
				previous_state <= current_state;
				current_state <= next_state;
				p_ba <= c_ba;
				bank_states[c_ba] <= bank_next_state;
				burst_counter <= 0;
				write_active <= 1'b0;
				data_in_reg <= 16'bx;
				data_reg <= '{default:16'bx};
			end else current_state <= current_state;
		end
		READ_WITH_AUTOPRECHARGE: begin
			if (burst_counter >= burst_length) begin
				previous_state <= current_state;
				current_state <= next_state;
				p_ba <= c_ba;
				bank_states[c_ba] <= bank_next_state;
				burst_counter <= 0;
				
			end else current_state <= current_state;
		end
		default: begin
			previous_state <= current_state;
			current_state <= next_state;
			p_ba <= c_ba;
			bank_states[c_ba] <= bank_next_state;
		end
	endcase
	end
	//Command Decoding
	if (current_state != previous_state) begin
	case (current_state)
		ACTIVE: begin
			row_addr[c_ba] <= d_row_add;
			row_active[c_ba] <=1'b1;
		end
		READ: begin
			col_addr <= d_col_add;
			//if (burst_counter < burst_length) begin
			//	read_active <= 1'b1;
			//end else read_active <= 1'b0;
		end
		WRITE: begin
			col_addr <= d_col_add;
			//if (burst_counter < burst_length) write_active <=1'b1;
			//else write_active <=1'b0;
		end
		READ_WITH_AUTOPRECHARGE: begin
			col_addr <= d_col_add;
			//if (burst_counter < burst_length) begin
			//	read_active <= 1'b1;	
			//end else read_active <= 1'b0;
		end
		WRITE_WITH_AUTOPRECHARGE: begin
			col_addr <= d_col_add;
			//if (burst_counter < burst_length) write_active <=1'b1;
			//else write_active <=1'b0;
		end
		PRECHARGE: begin
			if (previous_state == READ_WITH_AUTOPRECHARGE || previous_state == WRITE_WITH_AUTOPRECHARGE) begin
				bank_states[c_ba] <= BANK_IDLE; // Precharge Current Bank
				row_addr[c_ba] <= 'bz; // Precharge Active Row
				row_active[c_ba] <= 'b0;
			end else if (d_ap) begin
				bank_states <= '{default:BANK_IDLE};		// Precharge all banks
				row_addr <= '{default:'bx};
				row_active <= '{default:'b0};
			end else begin
				bank_states[c_ba] <= BANK_IDLE; // Precharge Current Bank
				row_addr[c_ba] <= 'bz; // Precharge Active Row
				row_active[c_ba] <= 'b0;
			end
		end
		MODE_REGISTER_SET: begin
			// Set mode register (burst length, CAS latency, etc.)
			burst_len <= addr [2:0];
			burst_type <= addr [3];
			cas_latency <= addr [6:4];
			operating_mode <= addr [13:7];
		end
	endcase
	end
end

//int i=0,j=0;

always_ff @(posedge clk or posedge clkn) begin
	clk2x <= ~clk2x;
	case (current_state)
		READ, READ_WITH_AUTOPRECHARGE: begin
			if (burst_counter < burst_length) begin
				read_active = 1'b1;	
			end else begin
				dqs_en <= 1'b0;
				dq_en <= 1'b0;
				read_active <= 1'b0;
				dq_reg <= 16'bx;
			end
			if (read_active) begin
				dqs_en <= 1'b1;
				dq_en <= 1'b1;
				if (dqs_en && dq_en && burst_counter < burst_length && data_out_reg !== 16'bx) begin
					dq_reg <= data_out_reg;
					burst_counter <= burst_counter + 1;
				end
			end
		end
		WRITE, WRITE_WITH_AUTOPRECHARGE: begin
			/*if (dqs !== 'bz && i < burst_length && dq !== 16'bx) begin
				data_reg [i] <= dq;
				i <= i + 1;
			end*/
			if (burst_counter < burst_length) write_active =1'b1;
			else write_active =1'b0;
			if (write_active && !dqs_en && !dq_en && burst_counter < burst_length && dq !== 16'bx && dqs !== 1'bz) begin
				data_in_reg <= dq;
				burst_counter <= burst_counter + 1;
				//j <= j + 1;
			end
		end
		BURST_STOP : begin
			dqs_en <= 1'b0;
			dq_en <= 1'b0;
		end
	endcase
end
assign dqs = dqs_en ? (clk2x ? 1'b1 : 1'b0) : 1'bz;
assign dq = dq_en ? dq_reg : 16'bz;
endmodule
