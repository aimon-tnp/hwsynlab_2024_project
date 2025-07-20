module top(
    input wire          clk100mhz,
    input wire          reset,
    input wire          btn,
    input               miso,
    output              mosi,
    output              sclk,
    output              cs,
    output reg          [15:0] led,
    input               gray,
    
    // VGA outputs
    input wire [15:0]   sw,
    output wire         hsync,             
    output wire         vsync,               
    output wire         [3:0] vga_r,         
    output wire         [3:0] vga_g,         
    output wire         [3:0] vga_b          
);
    reg        done;
    // Clock and reset signals
    wire       clk;            // 25MHz clk for sdcard and vga
    wire       locked;         // PLL locked signal
    wire       rst = ~locked | reset;
    
    // Debounced button signal
    wire       btn_debounced;
    wire       gray_debounced;
    reg        btn_prev = 0;
    reg        btn_pressed = 0;
    
    reg [15:0] buffer [0:3071];  // 64x48 16-bit pixel -> 49152 bit -> 12 block(sector)
    reg [14:0] buffer_addr_write = 0;   //address for write in buffer
    wire [14:0] buffer_addr_read;       // address read for vga
    
    reg [7:0]  byte_buffer;     // 1st 8 bit of 16-bit pixel
    reg        byte_ready = 0;  // Flag indicating byte buffer has data
    
    // Checksum calculation
    reg [31:0] checksum = 0;        // Holds the running sum (needs to be 32-bit to handle overflow before modulo)
    reg [14:0] checksum_addr = 0;   // Address counter for reading buffer during checksum calculation
    reg [1:0]  checksum_state = 0;  // Sub-state for checksum calculation
    
    // SD card controller signals
    reg        rd = 0;
    wire [7:0] sd_dout;
    wire       byte_available;
    wire       ready;
    
    // State machine variables
    reg [3:0]  main_state = INIT;
    parameter  INIT = 0,
               SD_WAIT_READY = 1,
               READ_SD = 2,
               WAIT_SECTOR = 3,
               DONE = 4,
               CALCULATE_CHECKSUM = 5,
               DISPLAY_CHECKSUM = 6;
    
    // Sector reading logic
    reg [31:0] current_sector = 32'd0;    // 1 picture (12 sector)
    reg [31:0] sector_base = 32'd0;       // base sector -> picture select
    reg [9:0]  bytes_read = 0;            // count block readed
    reg        reading = 0;              
    reg [6:0]  sectors_read = 0;          // count sector readed
    // Flag to indicate button was pressed, used to communicate between always blocks
    reg        change_sector_group = 0;
    
    // VGA-related signals
    wire       video_on;
    wire       p_tick;           // 25MHz pixel clock tick
    wire [9:0] pixel_x, pixel_y;
    reg gray_mode = 0;
    // Clock wizard instance for 25MHz clock
    clk_wiz_0 u_clk_wiz_0 (
        .reset       (reset),
        .clk_in1     (clk100mhz),       // input 100MHz
        .locked      (locked),
        .clk_out1    (clk)              // output 25MHz
    );
    
    // Button debouncer
    debounce btn_debouncer (
        .clk         (clk),
        .reset       (rst),
        .btn_in      (btn),
        .btn_out     (btn_debounced)
    );
     debounce gray_debouncer (
        .clk         (clk),
        .reset       (rst),
        .btn_in      (gray),
        .btn_out     (gray_debounced)
    );
    
    vga_sync vga_sync_unit (
        .clk(clk),
        .reset(rst),
        .hsync(hsync),
        .vsync(vsync),
        .video_on(video_on),
        .p_tick(p_tick),
        .x(pixel_x),
        .y(pixel_y)
    );
    
    reg [15:0] pixel_data;     // Current pixel data
    reg [12:0] scaled_x, scaled_y;
    reg [12:0] buffer_pixel_addr;
    reg [15:0] tled;

    always @* begin
        //64x48 pixel pictor
        scaled_x = pixel_x / 10;  // 640/64 = 10
        scaled_y = pixel_y / 10;  // 480/48 = 10

        buffer_pixel_addr = (scaled_y * 64) + scaled_x;
    end

   
    // Assign buffer read address for VGA display
    assign buffer_addr_read = (scaled_x < 64 && scaled_y < 48) ? 
                            buffer_pixel_addr : 
                           0; // Default to first pixel if out of bounds
    
    assign pixel_data = (video_on && main_state == DONE) ? buffer[buffer_addr_read] : 16'h0000;
   always @(*) begin
    if (gray_mode == 0) begin
        vga_r = video_on ? pixel_data[15:12] : 4'h0;
        vga_g = video_on ? pixel_data[10:7] : 4'h0;
        vga_b = video_on ? pixel_data[4:1]  : 4'h0;
    end else begin
        // กำหนดเป็นค่าสีเทา เช่น ค่าเดียวกันให้ R, G, B เท่ากัน
        // สมมติใช้แค่ระดับสีจาก bit 9:5 ของ pixel_data มาทำ grayscale
        logic [3:0] gray;
        gray = pixel_data[9:6]; // หรือจะเฉลี่ย RGB ก็ได้
        vga_r = video_on ? gray : 4'h0;
        vga_g = video_on ? gray : 4'h0;
        vga_b = video_on ? gray : 4'h0;
    end
end
    
    always @(posedge gray_debounced) begin
        gray_mode <= ~gray_mode;
    end 
    //change picture button -> change_sector_group
    always @(posedge clk) begin
        if (rst) begin
            btn_prev <= 0;
            btn_pressed <= 0;
            change_sector_group <= 0;
        end else begin
            btn_prev <= btn_debounced;
            btn_pressed <= ~btn_prev & btn_debounced; // Rising edge detection
            
            // Set the flag when button is pressed and we're in DONE state
            if (btn_pressed && main_state == DONE) begin
                change_sector_group <= 1;
            end else begin
                change_sector_group <= 0;
            end
        end
    end
    
    // Main state machine
    always @(posedge clk) begin
        if (rst) begin
            main_state <= INIT;
            rd <= 0;
            reading <= 0;
            buffer_addr_write <= 0;
            bytes_read <= 0;
            done <= 0;
            byte_ready <= 0;
            checksum <= 0;
            checksum_addr <= 0;
            checksum_state <= 0;
            // Initialize sector variables
            sector_base <= 32'd0;
            current_sector <= 32'd0;
            sectors_read <= 0;
        end else begin
            // change picture (only when it in DONE stage)
            if (change_sector_group) begin
                if (sector_base == 0)          sector_base <= 32'd100;
                else if (sector_base == 100)   sector_base <= 32'd200;
                else if (sector_base == 200)   sector_base <= 32'd300;
                else if (sector_base == 300)   sector_base <= 32'd400;
                else if (sector_base == 400)   sector_base <= 32'd0;
                else                           sector_base <= 32'd0; 
                
                // Reset current sector to base sector
                current_sector <= sector_base;
                sectors_read <= 0;
                buffer_addr_write <= 0;  // Reset buffer address for new sector group
                main_state <= INIT;
            end else begin
                // Normal state machine operation
                case (main_state)
                    INIT: begin
                        main_state <= SD_WAIT_READY;
                        bytes_read <= 0;
                        rd <= 0;
                        reading <= 0;
                        byte_ready <= 0;
                        
                        // Use current sector position
                        current_sector <= sector_base + sectors_read;
                        
                        if (sectors_read >= 12) begin
                            done <= 1;  // Signal all sectors are read
                            main_state <= DONE;
                        end else begin
                            done <= 0;
                        end
                    end
                    
                    SD_WAIT_READY: begin
                        if (ready) begin
                            main_state <= READ_SD;
                        end
                    end
                    
                    READ_SD: begin
                        if (ready && !reading && !rd) begin
                            rd <= 1;
                            reading <= 1;
                        end else if (rd) begin
                            rd <= 0;
                        end
                        
                        if (reading && byte_available) begin
                            if (!byte_ready) begin
                                byte_buffer <= sd_dout; //store 1st 8-bit pixel in byte_buffer
                                byte_ready <= 1;
                            end else begin
                                buffer[buffer_addr_write] <= {byte_buffer, sd_dout}; //store pixel
                                buffer_addr_write <= buffer_addr_write + 1;
                                byte_ready <= 0;
                            end
                            
                            bytes_read <= bytes_read + 1;
                            
                            if (bytes_read == 511) begin
                                reading <= 0;
                                main_state <= WAIT_SECTOR;
                                sectors_read <= sectors_read + 1;
                            end
                        end
                        
                        // Handle read completion
                        if (reading && ready && !byte_available && bytes_read > 0) begin
                            reading <= 0;
                            main_state <= WAIT_SECTOR;
                            sectors_read <= sectors_read + 1;
                        end
                    end
                    
                    WAIT_SECTOR: begin
                        // Wait until SD controller is ready again
                        if (ready) begin
                            if (sectors_read < 12) begin
                                main_state <= INIT;  // Read next sector
                            end else begin
                                main_state <= CALCULATE_CHECKSUM;  // All sectors read, calculate checksum
                                checksum <= 0;       // Reset checksum
                                checksum_addr <= 0;  // Start from first buffer address
                                checksum_state <= 0; // Reset checksum calculation state
                                done <= 1;           // Signal all sectors are read
                            end
                        end
                    end
                    
                    CALCULATE_CHECKSUM: begin
                        case (checksum_state)
                            0: begin
                                // Add the current buffer value to checksum
                                checksum <= (checksum + buffer[checksum_addr]) % 65521; // Modulo 65521 (largest prime under 16 bits)
                                checksum_state <= 1;
                            end
                            1: begin
                                // Move to next address or finish
                                if (checksum_addr < buffer_addr_write - 1) begin // Check against actual data stored
                                    checksum_addr <= checksum_addr + 1;
                                    checksum_state <= 0; // Go back to state 0 for next read
                                end else begin
                                    main_state <= DISPLAY_CHECKSUM;
                                end
                                checksum_state <= 0;
                            end
                        endcase
                    end
                    
                    DISPLAY_CHECKSUM: begin
                        main_state <= DONE;
                    end
                    
                    DONE: begin
                        done <= 1;  // Signal all sectors are read
                    end
                    
                    default: main_state <= INIT;
                endcase
            end
        end
    end
    
    // SD card controller instance
    sd_controller sd_ctrl (
        .cs             (cs),
        .mosi           (mosi),
        .miso           (miso),
        .sclk           (sclk),
        
        .rd             (rd),
        .dout           (sd_dout),
        .byte_available (byte_available),
        
        .ready_for_next_byte(),               // Not used in top module
        
        .reset          (rst),
        .ready          (ready),
        .address        (current_sector),
        .clk            (clk)
    );
    
endmodule

// Button debouncer module
module debounce (
    input      clk,
    input      reset,
    input      btn_in,
    output reg btn_out
);
    parameter DEBOUNCE_PERIOD = 250000;  // 10ms at 25MHz
    
    reg [19:0] counter = 0;
    reg        btn_state = 0;
    
    always @(posedge clk) begin
        if (reset) begin
            counter <= 0;
            btn_state <= 0;
            btn_out <= 0;
        end else begin
            if (btn_in != btn_state) begin
                // Button state changed, start counting
                counter <= 0;
                btn_state <= btn_in;
            end else if (counter < DEBOUNCE_PERIOD) begin
                // Still counting
                counter <= counter + 1;
            end else begin
                // Debounce period elapsed, update output
                btn_out <= btn_state;
            end
        end
    end
endmodule