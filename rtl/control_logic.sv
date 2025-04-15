module ddr_sdram_controller (
    input  logic clk,          
	input  logic clkn,         
    input  logic rst_n,        
    input  logic cke,          
    input  logic cs,           
    input  logic ras,          
    input  logic cas,          
    input  logic we,           
    input  logic [15:0] addr,  
    inout  logic [15:0] dq,    
    inout  logic dqs,          
    input  logic dm,           
    output logic [15:0] data_out, 
    output logic init_done     
);
// Timing Parameters (Not Finalized)
parameter tRCD = 10; //Row to Column Delay
parameter tRP = 10;  //Row Precharge Time
parameter tRAS = 10; //Row Active Time
parameter tRC = 10;  //Row Cycle Time
parameter tRFC = 10; //Refresh Cycle Time
parameter tWR = 10;  //Write Recovery Time
parameter tWTR = 10; //Write to Read Delay
parameter tRRD = 10; //Row to Row Delay
parameter tDAL = 10; //Data-in to Auto Precharge Delay
parameter tDQSS = 10;//DQS Latching Transition
parameter tMRD = 10; // Mode Register Set Delay
parameter tDSGN = 32'h41594148;
parameter INIT_WAIT_CYCLES = 20000; // For 200µs at 100MHz
parameter CAPACITY = 4; // Address Parameters
parameter DATA_WIDTH = 2;

localparam ROW_WIDTH = (CAPACITY == 1) ? 12 : (CAPACITY == 2 || CAPACITY == 3) ? 13 : 14;
localparam COL_WIDTH = (CAPACITY == 1 || CAPACITY == 2) ? (DATA_WIDTH == 1) ? 11 :
															 (DATA_WIDTH == 2) ? 10 :
															 9:
															 (DATA_WIDTH == 1) ? 12 :
															 (DATA_WIDTH == 2) ? 11 :
															 10;
//Timings signals
logic [7:0] tRCD_counter;  
logic [7:0] tRP_counter;   
logic [7:0] tRFC_counter;  
logic [7:0] tMRD_counter;  
logic [7:0] tRAS_counter;  
logic [7:0] tRC_counter;   
logic [7:0] tRRD_counter;  
logic [7:0] tWR_counter;   
logic [7:0] tWTR_counter;  
logic [7:0] tDAL_counter;  
logic [2:0] burst_counter;
logic [15:0] init_counter, init_precharge_done, init_mrs_done, init_refresh_count; // Initialization signals
logic [ROW_WIDTH-1:0] row_addr; // Address Signals
logic [1:0] p_ba;				// Previous selected Bank
logic [1:0] c_ba;				// Current selected Bank
logic [COL_WIDTH-1:0] col_addr; 
logic [2:0] burst_length;     
logic burst_type;			  
logic [2:0] cas_latency;      
logic [6:0]operating_mode;	  
logic ap;					  
logic [15:0] data_in;         // Input data buffer
logic [15:0] data_out_reg;    // Output data buffer
logic dqs_en;                 
logic dq_en;                  
logic cke_ps, cke_cs;         // cke previous/current state

// Address decoder signals
logic [1:0] d_ba;             // Decoded bank address
logic [2:0] d_burst_len;      
logic d_burst_type;           
logic [2:0] d_cl;             // Decoded CAS latency
logic [6:0] d_operating_mode; 
logic [ROW_WIDTH-1:0] d_row_add;       
logic [COL_WIDTH-1:0] d_col_add;       
logic d_ap;                   // Decoded auto precharge flag
// adf signal to map state_t to address_decoder function codes
logic [3:0] adf;

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

typedef enum logic [3:0] {
    BANK_IDLE,
    BANK_ACTIVE,
    BANK_READ,
	BANK_READ_AP,
	BANK_WRITE_AP,
    BANK_WRITE,
    BANK_PRECHARGE
} bank_state_t;

bank_state_t bank_states [0:3], bank_next_state; // 4 banks
logic [3:0] bank_active;        // Tracks which banks have active rows

// Instantiate the address_decoder module
address_decoder #(
    .CAPACITY(4),             //capacity parameter (1Gb)
    .DATA_WIDTH(2)            //data width parameter (x8)
) addr_decoder_inst (
    .address(addr),
    .adf(adf),               // Use the mapped adf signal
    .BA(d_ba),               
    .burst_len(d_burst_len), 
    .burst_type(d_burst_type), 
    .CL(d_cl),               
    .operating_mode(d_operating_mode), 
    .row_add(d_row_add),     
    .col_add(d_col_add),     
    .ap(d_ap)                
);

//FSM
always_comb begin
// Map state_t to adf based on the table in address_decoder.sv
    case (current_state)
        IDLE:                   adf = 4'b0001; // NO OPERATION (NOP)
        MODE_REGISTER_SET:      adf = 4'b1000; // MODEREGISTER SET Op-Code
        ACTIVE:                 adf = 4'b0010; // ACTIVE
        READ:                   adf = 4'b0011; // READ
        WRITE:                  adf = 4'b0100; // WRITE
        PRECHARGE:              adf = 4'b0110; // PRECHARGE
        AUTO_REFRESH:           adf = 4'b0111; // AUTO/Self refresh
        SELF_REFRESH:           adf = 4'b0111; // AUTO/Self refresh
        READ_WITH_AUTOPRECHARGE: adf = 4'b0011; // READ (with auto-precharge)
        WRITE_WITH_AUTOPRECHARGE: adf = 4'b0100; // WRITE (with auto-precharge)
        BURST_STOP:             adf = 4'b0101; // BURST TERMINATE
        default:                adf = 4'b0001; // Default to NOP
    endcase
	
if (init_done) begin		//Initialization check
    case (current_state)	//FSM start
        IDLE: begin
            if (!cs && !ras && !cas && !we) begin
				if (bank_states[0] == BANK_IDLE && bank_states[1] == BANK_IDLE && bank_states[2] == BANK_IDLE && bank_states[3] == BANK_IDLE) begin
					next_state = MODE_REGISTER_SET;
				end
            end else if (!cs && !ras && cas && we) begin
				if (bank_states[c_ba] == BANK_IDLE) begin
					next_state = ACTIVE;
					bank_next_state = BANK_ACTIVE;
					bank_active[c_ba] = 1'b1; 
				end
            end else if (!cs && !ras && !cas && we && cke) begin
				if (bank_states[0] == BANK_IDLE && bank_states[1] == BANK_IDLE && bank_states[2] == BANK_IDLE && bank_states[3] == BANK_IDLE) begin
					next_state = AUTO_REFRESH;
				end
            end else if (!cs && !ras && !cas && we && cke_ps && !cke_cs ) begin
                next_state = SELF_REFRESH;
            end else if (!cs && !ras && cas && !we) begin
                next_state = PRECHARGE; // IDLE to PRECHARGE
            end else if (cke_ps && !cke_cs) begin
                next_state = POWER_DOWN;
            end else if(cs || !cs && ras && cas && we) begin
                next_state = IDLE; // Default to IDLE
            end
        end

        MODE_REGISTER_SET: begin
            next_state = IDLE;
        end

        ACTIVE: begin
			if (!cs && !ras && cas && we) begin
				if (bank_states[c_ba] == BANK_IDLE && bank_states[p_ba] == BANK_ACTIVE) begin
					next_state = ACTIVE;		//other bank activation
					bank_next_state = BANK_ACTIVE;
					bank_active[c_ba] = 1'b1;
				end
            end else if (!cs && ras && !cas && we) begin
				if (bank_states[c_ba] == BANK_ACTIVE && bank_states[p_ba] == BANK_ACTIVE) begin
					next_state = READ;			//other Bank READ
					bank_next_state = BANK_READ;
				end else if (bank_states[c_ba] == BANK_ACTIVE) begin
					next_state = READ;			//same Bank READ
					bank_next_state = BANK_READ;
				end
            end else if (!cs && ras && !cas && !we) begin
				if (bank_states[c_ba] == BANK_ACTIVE && bank_states[p_ba] == BANK_ACTIVE) begin
					next_state = WRITE;			//other Bank WRITE
					bank_next_state = BANK_WRITE;
				end else if (bank_states[c_ba] == BANK_ACTIVE) begin
					next_state = WRITE;			//same Bank WRITE
					bank_next_state = BANK_WRITE;
				end
            end else if (!cs && !ras && cas && !we) begin
				if (bank_states[c_ba] != BANK_IDLE && bank_states[p_ba] == BANK_ACTIVE) begin
					next_state = PRECHARGE; //other Bank Precharge
				end else begin
					next_state = PRECHARGE; //same Bank Precharge
				end
            end else if (cke_ps && !cke_cs) begin
                next_state = POWER_DOWN; // ACTIVE to POWER_DOWN
            end else if (!cs && ras && !cas && we && d_ap) begin
				if (bank_states[c_ba] == BANK_ACTIVE && bank_states[p_ba] == BANK_ACTIVE) begin
					next_state = READ_WITH_AUTOPRECHARGE;	//other Bank READ with AUTOPRECHARGE
					bank_next_state = BANK_READ_AP;
				end else if (bank_states[c_ba] == BANK_ACTIVE) begin
					next_state = READ_WITH_AUTOPRECHARGE; // ACTIVE to READ with AUTOPRECHARGE
					bank_next_state = BANK_READ_AP;
				end
            end else if (!cs && ras && !cas && !we && d_ap) begin
				if (bank_states[c_ba] == BANK_ACTIVE && bank_states[p_ba] == BANK_ACTIVE) begin
					next_state = WRITE_WITH_AUTOPRECHARGE;	//other Bank WRITE with AUTOPRECHARGE
					bank_next_state = BANK_WRITE_AP;
				end else if (bank_states[c_ba] == BANK_ACTIVE) begin
					next_state = WRITE_WITH_AUTOPRECHARGE; // ACTIVE to WRITE with AUTOPRECHARGE
					bank_next_state = BANK_WRITE_AP;
				end
            end else if(cs || !cs && ras && cas && we) begin
                next_state = ACTIVE; // Default to ACTIVE
            end
        end

        READ: begin
			if (!cs && !ras && cas && we) begin
				if (bank_states[c_ba] == BANK_IDLE && bank_states[p_ba] == BANK_READ) begin
					next_state = ACTIVE;		//other bank activation
					bank_next_state = BANK_ACTIVE;
					bank_active[c_ba] = 1'b1;
				end
            end else if (!cs && ras && !cas && we) begin
				if (bank_states[c_ba] == BANK_ACTIVE && bank_states[p_ba] == BANK_READ) begin
					next_state = READ;		//other bank READ
					bank_next_state = BANK_READ;
				end else if (bank_states[c_ba] == BANK_READ) begin
					next_state = READ;	// Consecutive READ same Bank
					bank_next_state = BANK_READ;
				end
			end else if (!cs && ras && !cas && !we) begin
				if (bank_states[c_ba] == BANK_ACTIVE && bank_states[p_ba] == BANK_READ) begin
					next_state = WRITE;			//other Bank WRITE
					bank_next_state = BANK_WRITE;
                end else if (bank_states[c_ba] == BANK_READ) begin
					next_state = WRITE; // READ to WRITE same Bank
					bank_next_state = BANK_WRITE;
				end
            end else if (!cs && ras && !cas && we && d_ap) begin
				if (bank_states[c_ba] == BANK_ACTIVE && bank_states[p_ba] == BANK_READ) begin
					next_state = READ_WITH_AUTOPRECHARGE;	//other Bank READ with AUTOPRECHARGE
					bank_next_state = BANK_READ_AP;
				end else if (bank_states[c_ba] == BANK_READ) begin
					next_state = READ_WITH_AUTOPRECHARGE; // READ to READ with AUTOPRECHARGE same Bank
					bank_next_state = BANK_READ_AP;
				end
            end else if (!cs && ras && !cas && !we && d_ap) begin
				if (bank_states[c_ba] == BANK_ACTIVE && bank_states[p_ba] == BANK_READ) begin
					next_state = WRITE_WITH_AUTOPRECHARGE;	//other Bank WRITE with AUTOPRECHARGE
					bank_next_state = BANK_WRITE_AP;
				end else if (bank_states[c_ba] == BANK_READ) begin
					next_state = WRITE_WITH_AUTOPRECHARGE; // READ to WRITE with AUTOPRECHARGE same Bank
					bank_next_state = BANK_WRITE_AP;
				end
			end else if (!cs && !ras && cas && !we) begin
				if (bank_states[c_ba] != BANK_IDLE && bank_states[p_ba] == BANK_READ) begin
					next_state = PRECHARGE; //other Bank Precharge
				end else begin
					next_state = PRECHARGE; //same Bank Precharge
				end
			end else if (!cs && ras && cas && !we) begin
                next_state = BURST_STOP; // READ to BURST_STOP
            end else if(cs || !cs && ras && cas && we) begin
                next_state = READ; // Default to READ
            end
        end

        READ_WITH_AUTOPRECHARGE: begin
			if (!cs && !ras && cas && we) begin
				if (bank_states[c_ba] == BANK_IDLE && bank_states[p_ba] == BANK_READ_AP) begin
					next_state = ACTIVE;		//other bank activation
					bank_next_state = BANK_ACTIVE;
					bank_active[c_ba] = 1'b1;
				end
			end else if (!cs && ras && !cas && we) begin
				if (bank_states[c_ba] == BANK_ACTIVE && bank_states[p_ba] == BANK_READ_AP) begin
					next_state = READ;		//other bank READ
					bank_next_state = BANK_READ;
				end
			end else if (!cs && ras && !cas && !we) begin
				if (bank_states[c_ba] == BANK_ACTIVE && bank_states[p_ba] == BANK_READ_AP) begin
					next_state = WRITE;			//other Bank WRITE
					bank_next_state = BANK_WRITE;
				end
			end else if (!cs && ras && !cas && we && d_ap) begin
				if (bank_states[c_ba] == BANK_ACTIVE && bank_states[p_ba] == BANK_READ_AP) begin
					next_state = READ_WITH_AUTOPRECHARGE;	//other Bank READ with AUTOPRECHARGE
					bank_next_state = BANK_READ_AP;
				end
			end else if (!cs && ras && !cas && !we && d_ap) begin
				if (bank_states[c_ba] == BANK_ACTIVE && bank_states[p_ba] == BANK_READ_AP) begin
					next_state = WRITE_WITH_AUTOPRECHARGE;	//other Bank WRITE with AUTOPRECHARGE
					bank_next_state = BANK_WRITE_AP;
				end
			end else if (bank_states[c_ba] != BANK_IDLE && bank_states[p_ba] == BANK_READ_AP) begin
					next_state = PRECHARGE; //other Bank Precharge
				end else begin
					next_state = PRECHARGE; //same Bank Precharge
				end
        end

        WRITE: begin
			if (!cs && !ras && cas && we) begin
				if (bank_states[c_ba] == BANK_IDLE && bank_states[p_ba] == BANK_WRITE) begin
					next_state = ACTIVE;		//other bank activation
					bank_next_state = BANK_ACTIVE;
					bank_active[c_ba] = 1'b1;
				end
            end else if (!cs && ras && !cas && !we) begin
				if (bank_states[c_ba] == BANK_ACTIVE && bank_states[p_ba] == BANK_WRITE) begin
					next_state = WRITE;			//other Bank WRITE
					bank_next_state = BANK_WRITE;
				end else if (bank_states[c_ba] == BANK_WRITE) begin
					next_state = WRITE; // Consecutive WRITE same Bank
					bank_next_state = BANK_WRITE;
				end
			end else if (!cs && ras && !cas && we) begin
				if (bank_states[c_ba] == BANK_ACTIVE && bank_states[p_ba] == BANK_WRITE) begin
					next_state = READ;		//other bank READ
					bank_next_state = BANK_READ;
				end else if (bank_states[c_ba] == BANK_WRITE) begin
					next_state = READ;	// WRITE to READ same Bank
					bank_next_state = BANK_READ;
				end
			end else if (!cs && ras && !cas && !we && d_ap) begin
				if (bank_states[c_ba] == BANK_ACTIVE && bank_states[p_ba] == BANK_WRITE) begin
					next_state = WRITE_WITH_AUTOPRECHARGE;	//other Bank WRITE with AUTOPRECHARGE
					bank_next_state = BANK_WRITE_AP;
				end else if (bank_states[c_ba] == BANK_WRITE) begin
					next_state = WRITE_WITH_AUTOPRECHARGE; // WRITE to WRITE with AUTOPRECHARGE same Bank
					bank_next_state = BANK_WRITE_AP;
				end
            end else if (!cs && ras && !cas && we && d_ap) begin
				if (bank_states[c_ba] == BANK_ACTIVE && bank_states[p_ba] == BANK_WRITE) begin
					next_state = READ_WITH_AUTOPRECHARGE;	//other Bank READ with AUTOPRECHARGE
					bank_next_state = BANK_READ_AP;
                end else if (bank_states[c_ba] == BANK_WRITE) begin
					next_state = READ_WITH_AUTOPRECHARGE; // WRITE to READ with AUTOPRECHARGE same Bank
					bank_next_state = BANK_READ_AP;
				end
            end else if (!cs && !ras && cas && !we) begin
				if (bank_states[c_ba] != BANK_IDLE && bank_states[p_ba] == BANK_WRITE) begin
					next_state = PRECHARGE; //other Bank Precharge
				end else begin
					next_state = PRECHARGE; //same Bank Precharge
				end
            end else if(cs || !cs && ras && cas && we) begin
                next_state = WRITE; // Default to WRITE
            end
        end

        WRITE_WITH_AUTOPRECHARGE: begin
			if (!cs && !ras && cas && we) begin
				if (bank_states[c_ba] == BANK_IDLE && bank_states[p_ba] == BANK_WRITE_AP) begin
					next_state = ACTIVE;		//other bank activation
					bank_next_state = BANK_ACTIVE;
					bank_active[c_ba] = 1'b1;
				end
			end else if (!cs && ras && !cas && !we) begin
				if (bank_states[c_ba] == BANK_ACTIVE && bank_states[p_ba] == BANK_WRITE_AP) begin
					next_state = WRITE;			//other Bank WRITE
					bank_next_state = BANK_WRITE;
				end
			end else if (!cs && ras && !cas && we) begin
				if (bank_states[c_ba] == BANK_ACTIVE && bank_states[p_ba] == BANK_WRITE_AP) begin
					next_state = READ;		//other bank READ
					bank_next_state = BANK_READ;
				end
			end else if (!cs && ras && !cas && !we && d_ap) begin
				if (bank_states[c_ba] == BANK_ACTIVE && bank_states[p_ba] == BANK_WRITE_AP) begin
					next_state = WRITE_WITH_AUTOPRECHARGE;	//other Bank WRITE with AUTOPRECHARGE
					bank_next_state = BANK_WRITE_AP;
				end
			end else if (!cs && ras && !cas && we && d_ap) begin
				if (bank_states[c_ba] == BANK_ACTIVE && bank_states[p_ba] == BANK_WRITE_AP) begin
					next_state = READ_WITH_AUTOPRECHARGE;	//other Bank READ with AUTOPRECHARGE
					bank_next_state = BANK_READ_AP;
				end
			end else if (bank_states[c_ba] != BANK_IDLE && bank_states[p_ba] == BANK_WRITE_AP) begin
				next_state = PRECHARGE; //other Bank Precharge
			end else begin
				next_state = PRECHARGE; //same Bank Precharge
			end
		end

        PRECHARGE: begin
            next_state = IDLE;
        end

        AUTO_REFRESH: begin
            next_state = PRECHARGE; // AUTO_REFRESH to PRECHARGE
        end

        SELF_REFRESH: begin
            if (!cke_ps && cke_cs) begin
				if (cs || !cs && ras && cas && we) begin
					next_state = IDLE; //
				end
            end else if (!cke_ps && !cke_cs) begin
                next_state = SELF_REFRESH; // Maintain SELF_REFRESH
            end
        end

        POWER_DOWN: begin
            if (!cke_ps && cke_cs) begin
				if (cs || !cs && ras && cas && we) begin
					if (previous_state == ACTIVE) begin
						next_state = ACTIVE; // POWER_DOWN to ACTIVE
					end else begin
						next_state = IDLE; // POWER_DOWN to IDLE (if not from ACTIVE)
					end 
				end
            end else if (!cke_ps && !cke_cs) begin
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
else begin		//Initialization start
    if (init_counter < INIT_WAIT_CYCLES) begin
		next_state = IDLE; // Wait period
	end
	else if (!init_precharge_done) begin
		next_state = PRECHARGE;
	end
	else if (!init_mrs_done) begin
		next_state = MODE_REGISTER_SET;
	end
	else if (init_refresh_count < 2) begin
		next_state = AUTO_REFRESH;
	end
	else begin
		next_state = IDLE; // Initialization complete
	end
end
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
		// Reset Timings signals
		tRCD_counter <= '0;
        tRP_counter <= '0;
        tRFC_counter <= '0;
        tRAS_counter <= '0;
		tRC_counter <= '0;
		tRRD_counter <= '0; //Row to Row Delay
        tWR_counter <= '0;
        tWTR_counter <= '0;
        tDAL_counter <= '0;
		// Reset Initialization signals
		init_counter <= 0;
        init_precharge_done <= 0;
        init_mrs_done <= 0;
        init_refresh_count <= 0;
        init_done <= 0;
		// Reset all Command registers and signals
		current_state <= IDLE;
        previous_state <= IDLE;		// Initialize previous_state
		cke_cs <= 1;
		cke_ps <= 1;		
        row_addr <= '0;
		p_ba <= '0; // Previous selected Bank
        c_ba <= '0; // Current selected Bank
        col_addr <= '0;
        burst_length <= '0;
        cas_latency <= '0;
        ap <= '0;
        data_out <= '0;
        dqs_en <= '0;
        dq_en <= '0;
    end
	else begin
		previous_state <= current_state; // Update previous_state
		cke_ps <= cke_cs;
		cke_cs <= cke;
		
		c_ba <= d_ba;
		// Initialization tracking
        if (!init_done) begin
            init_counter <= init_counter + 1;
            
            if (current_state == PRECHARGE && tRP_counter >= tRP) begin
                init_precharge_done <= 1;
            end
            if (current_state == MODE_REGISTER_SET) begin
                burst_length <= 3'b010; // Default lenght 4
				burst_type <= 1'b0;		// Default type sequential
                cas_latency <= 3'b010;	// Default CAS Latency 2
				operating_mode <= 'b0;	// Default Normal Operation
				if (tMRD_counter >= tMRD)
					init_mrs_done <= 1;
            end
            if (current_state == AUTO_REFRESH && tRFC_counter >= tRFC) begin
                init_refresh_count <= init_refresh_count + 1;
            end
            if (init_refresh_count >= 2) begin
                init_done <= 1;
            end
        end
		// Timing tracking
        case (current_state)
            ACTIVE: begin
				tRAS_counter <= tRAS_counter + 1;
				tRCD_counter <= tRCD_counter + 1;
				tRC_counter <= tRC_counter + 1;
				tRRD_counter <= tRRD_counter + 1;
				if (next_state == ACTIVE && tRRD_counter >= tRRD) begin
					if (c_ba == p_ba && tRC_counter >= tRC) begin
						current_state <= next_state;
						p_ba <= c_ba;
						bank_states[c_ba] <= bank_next_state;
						tRC_counter <= '0;
						tRRD_counter <= '0;
					end else if (c_ba != p_ba) begin
						current_state <= next_state;
						p_ba <= c_ba;
						bank_states[c_ba] <= bank_next_state;
						tRRD_counter <= '0;
					end
				end else if (next_state == READ && tRCD_counter >= tRCD) begin
					current_state <= next_state;
					p_ba <= c_ba;
					bank_states[c_ba] <= bank_next_state;
					tRCD_counter <= '0;
				end
            end
			READ: begin
				tRRD_counter <= tRRD_counter + 1;
				if (c_ba == p_ba) begin
					current_state <= next_state;
					p_ba <= c_ba;
					bank_states[c_ba] <= bank_next_state;
                end else if (c_ba != p_ba && next_state == ACTIVE && tRRD_counter >= tRRD) begin
					current_state <= next_state;
					p_ba <= c_ba;
					bank_states[c_ba] <= bank_next_state;
					tRRD_counter <= '0;
				end
			end
			WRITE: begin
				tRRD_counter <= tRRD_counter + 1;
				if (c_ba == p_ba) begin
					current_state <= next_state;
					p_ba <= c_ba;
					bank_states[c_ba] <= bank_next_state;
                end else if (c_ba != p_ba && next_state == ACTIVE && tRRD_counter >= tRRD) begin
					current_state <= next_state;
					p_ba <= c_ba;
					bank_states[c_ba] <= bank_next_state;
					tRRD_counter <= '0;
				end
			end
            PRECHARGE: begin
                if (tRAS_counter >= tRAS) begin
					tRP_counter <= tRP_counter + 1;
					if (tRP_counter >= tRP) begin
						current_state <= next_state;
						p_ba <= c_ba;
						bank_states[c_ba] <= bank_next_state;
						tRP_counter <= '0;
						tRAS_counter <= '0;
					end
                end 
            end
			WRITE_WITH_AUTOPRECHARGE: begin
				tRRD_counter <= tRRD_counter + 1;
				if (burst_counter == burst_length - 1) begin
					tDAL_counter <= tDAL_counter + 1;
					if (tDAL_counter >= tDAL) begin
						current_state <= next_state;
						p_ba <= c_ba;
						bank_states[c_ba] <= bank_next_state;
						tDAL_counter <= 0;
					end
				end else if (c_ba != p_ba && next_state == ACTIVE && tRRD_counter >= tRRD) begin
					current_state <= next_state;
					p_ba <= c_ba;
					bank_states[c_ba] <= bank_next_state;
					tRRD_counter <= '0;
				end
			end
			READ_WITH_AUTOPRECHARGE: begin
					tRRD_counter <= tRRD_counter + 1;
					if (c_ba == p_ba) begin
						current_state <= next_state;
						p_ba <= c_ba;
						bank_states[c_ba] <= bank_next_state;
					end else if (c_ba != p_ba && next_state == ACTIVE && tRRD_counter >= tRRD) begin
						current_state <= next_state;
						p_ba <= c_ba;
						bank_states[c_ba] <= bank_next_state;
						tRRD_counter <= '0;
					end
				end
            AUTO_REFRESH: begin
                tRFC_counter <= tRFC_counter + 1;
                if (tRFC_counter >= tRFC) begin
                    current_state <= next_state;
					p_ba <= c_ba;
					bank_states[c_ba] <= bank_next_state;
					tRFC_counter <= '0;
                end
            end
			WRITE: begin
				tWTR_counter <= tWTR_counter + 1;
				if (burst_counter == burst_length - 1) begin
					tWR_counter <= tWR_counter + 1;
					if (next_state == PRECHARGE && tWR_counter >= tWR) begin
						current_state <= next_state;
						p_ba <= c_ba;
						bank_states[c_ba] <= bank_next_state;
						tWR_counter <= '0;
					end
				end	else if (next_state == READ && tWTR_counter >= tWTR) begin
					current_state <= next_state;
					p_ba <= c_ba;
					bank_states[c_ba] <= bank_next_state;
					tWTR_counter <= '0;
				end
			end

            MODE_REGISTER_SET: begin
                tMRD_counter <= tMRD_counter + 1;
                if (tMRD_counter >= tMRD) begin
                    current_state <= next_state;
                end
            end
			default: begin
			current_state <= next_state;
			p_ba <= c_ba;
			bank_states[c_ba] <= bank_next_state;
			end
        endcase
		//Command Decoding
        case (current_state)
            ACTIVE: begin
                row_addr <= d_row_add;
            end
            READ: begin
                col_addr <= d_col_add;
				ap <= d_ap;
                dqs_en <= 1'b1;
                dq_en <= 1'b1;
                data_out <= data_out_reg;
            end
            WRITE: begin
                col_addr <= d_col_add;
				ap <= d_ap;
                data_in <= dq;
                dqs_en <= 1'b1;
                dq_en <= 1'b0;
            end
			READ_WITH_AUTOPRECHARGE: begin
                col_addr <= d_col_add;
				ap <= d_ap;
                dqs_en <= 1'b1;
                dq_en <= 1'b1;
                data_out <= data_out_reg;
            end
            WRITE_WITH_AUTOPRECHARGE: begin
                col_addr <= d_col_add;
				ap <= d_ap;
                data_in <= dq;
                dqs_en <= 1'b1;
                dq_en <= 1'b0;
            end
            PRECHARGE: begin
				ap <= d_ap;
					if (ap) begin
						//if (previous_state == READ_WITH_AUTOPRECHARGE || previous_state == WRITE_WITH_AUTOPRECHARGE) begin
							bank_states[c_ba] <= IDLE; // Precharge Current Bank
						//end 
					end else begin
						bank_states[0] <= IDLE;		// Precharge all banks
						bank_states[1] <= IDLE;
						bank_states[2] <= IDLE;
						bank_states[3] <= IDLE;
					end
					/*else begin
						row_addr <= 'bz;
						//ba <= 'bz; 			// Precharge selected banks
					end*/
			end
            MODE_REGISTER_SET: begin
                // Set mode register (burst length, CAS latency, etc.)
                burst_length <= d_burst_len;
				burst_type <= d_burst_type;
                cas_latency <= d_cl;
				operating_mode <= d_operating_mode;
            end
			BURST_STOP : begin
				if (previous_state == READ && ap == 1'b0) begin			
					dqs_en <= 1'b0;
					dq_en <= 1'b0;
					data_out <= 'bz;
				end
			end
        endcase
    end
end

assign dqs = dqs_en ? (clk ? 1'b1 : 1'b0) : 1'bz;
assign dq = dq_en ? data_out : 16'bz;

endmodule
