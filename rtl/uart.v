`timescale 1ns/1ps

module uart #(
    parameter CLK_FREQ = 100_000_000,
    parameter BAUD     = 115200
)(
    input  wire        clk,
    input  wire        rst_n,

    // MMIO interface
    input  wire [3:0]  addr,
    input  wire        wen,
    input  wire        ren,
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,

    // UART interface
    input  wire        rxd,
    output wire        txd,

    // RX interrupt
    output wire        irq
);

    // RX state definitions (two-process FSM)
    localparam RX_IDLE  = 2'd0;
    localparam RX_START = 2'd1;
    localparam RX_DATA  = 2'd2;
    localparam RX_STOP  = 2'd3;

    reg [1:0] rx_state;
    reg [1:0] rx_next_state;
    reg [2:0] rx_bit_idx;

    // RX asynchronous input synchronizer
    reg rxd_meta;
    reg rxd_sync;

    // TX data path
    reg [7:0] tx_buf;
    reg [9:0] tx_shift;

    // TX status
    reg       tx_full;
    reg       tx_busy;

    // TX control events
    wire tx_push;
    wire tx_start;
    wire tx_step;
    wire tx_done;

    assign tx_push  = rst_n && wen && !tx_full && (addr == 4'h0);
    assign tx_start = rst_n && tx_full && !tx_busy;

    // Single-byte TX waiting buffer
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_full <= 1'b0;
            tx_buf  <= 8'b0;
        end
        else if (tx_push) begin
            tx_buf  <= wdata[7:0];
            tx_full <= 1'b1;
        end
        else if (tx_start) begin
            tx_full <= 1'b0;
        end
    end

    // Baud rate configuration
    localparam DIV_RESET = CLK_FREQ / (16 * BAUD);

    reg [15:0] baud_divisor;
    reg [15:0] baud_clk_cnt;

    wire div_write;
    wire baud_tick;

    assign div_write = rst_n
                    && wen
                    && (addr == 4'hC)
                    && !tx_busy
                    && !tx_full
                    && (rx_state == RX_IDLE)
                    && rxd_sync
                    && (wdata[15:0] != 16'd0);

    assign baud_tick = (baud_clk_cnt == baud_divisor - 16'd1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            baud_divisor <= DIV_RESET[15:0];
        else if (div_write)
            baud_divisor <= wdata[15:0];
    end

    // Free-running baud rate counter (B1)
    // Restart the counter when a DIV write is accepted.
    // baud_tick is a terminal-count condition, independent of reset.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            baud_clk_cnt <= 16'd0;
        else if (div_write || baud_tick)
            baud_clk_cnt <= 16'd0;
        else
            baud_clk_cnt <= baud_clk_cnt + 16'd1;
    end

    // TX start phase
    reg [15:0] tx_start_phase;
    wire tx_baud_tick;

    assign tx_baud_tick = (baud_clk_cnt == tx_start_phase);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            tx_start_phase <= 16'd0;
        else if (tx_start)
            tx_start_phase <= baud_clk_cnt;
    end

    // TX oversampling tick counter
    reg [3:0] tx_tick_cnt;
    wire tx_bit_tick;

    assign tx_bit_tick = rst_n
                      && tx_busy
                      && tx_baud_tick
                      && (tx_tick_cnt == 4'd15);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            tx_tick_cnt <= 4'd0;
        else if (tx_start)
            tx_tick_cnt <= 4'd0;
        else if (tx_bit_tick)
            tx_tick_cnt <= 4'd0;
        else if (tx_busy && tx_baud_tick)
            tx_tick_cnt <= tx_tick_cnt + 4'd1;
    end

    // TX frame bit index
    reg [3:0] tx_bit_idx;

    assign tx_step = tx_bit_tick && (tx_bit_idx != 4'd9);
    assign tx_done = tx_bit_tick && (tx_bit_idx == 4'd9);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            tx_bit_idx <= 4'd0;
        else if (tx_start || tx_done)
            tx_bit_idx <= 4'd0;
        else if (tx_step)
            tx_bit_idx <= tx_bit_idx + 4'd1;
    end

    // TX shift register (8N1, LSB first)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            tx_shift <= 10'b1111111111;
        else if (tx_start)
            tx_shift <= {1'b1, tx_buf, 1'b0};
        else if (tx_step)
            tx_shift <= {1'b1, tx_shift[9:1]};
    end

    // TX busy status
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            tx_busy <= 1'b0;
        else if (tx_start)
            tx_busy <= 1'b1;
        else if (tx_done)
            tx_busy <= 1'b0;
    end

    // TX serial output
    assign txd = tx_shift[0];

    // RX input synchronization (idle line is high)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rxd_meta <= 1'b1;
            rxd_sync <= 1'b1;
        end
        else begin
            rxd_meta <= rxd;
            rxd_sync <= rxd_meta;
        end
    end

    // RX FSM state register and next-state logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rx_state <= RX_IDLE;
        else
            rx_state <= rx_next_state;
    end

    always @(*) begin
        rx_next_state = rx_state;

        case (rx_state)
            RX_IDLE: begin
                if (rx_start)
                    rx_next_state = RX_START;
            end
            RX_START: begin
                if (rx_half_tick && rxd_sync)
                    rx_next_state = RX_IDLE;
                else if (rx_half_tick && !rxd_sync)
                    rx_next_state = RX_DATA;
            end
            RX_DATA: begin
                if (rx_bit_tick && (rx_bit_idx == 3'd7))
                    rx_next_state = RX_STOP;
            end
            RX_STOP: begin
                if (rx_bit_tick)
                    rx_next_state = RX_IDLE;
            end
            default: begin
                rx_next_state = RX_IDLE;
            end
        endcase
    end

    // RX start event and phase capture
    reg [15:0] rx_start_phase;
    wire rx_start;
    wire rx_baud_tick;

    assign rx_start = rst_n && !rxd_sync
                            && (rx_state == RX_IDLE);
    assign rx_baud_tick = (baud_clk_cnt == rx_start_phase);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rx_start_phase <= 16'd0;
        else if (rx_start)
            rx_start_phase <= baud_clk_cnt;
    end

    // RX oversampling tick counter and center-sampling events
    reg [3:0] rx_tick_cnt;
    wire rx_half_tick;
    wire rx_bit_tick;

    assign rx_half_tick = rst_n
                        && rx_baud_tick
                        && (rx_tick_cnt == 4'd7)
                        && (rx_state == RX_START);

    assign rx_bit_tick = rst_n
                       && rx_baud_tick
                       && (rx_tick_cnt == 4'd15)
                       && ((rx_state == RX_DATA)
                        || (rx_state == RX_STOP));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rx_tick_cnt <= 4'd0;
        else if (rx_start || rx_half_tick || rx_bit_tick)
            rx_tick_cnt <= 4'd0;
        else if ((rx_state != RX_IDLE) && rx_baud_tick)
            rx_tick_cnt <= rx_tick_cnt + 4'd1;
    end

    // RX data-bit index
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rx_bit_idx <= 3'd0;
        else if (rx_state == RX_STOP)
            rx_bit_idx <= 3'd0;
        else if (rx_bit_tick && (rx_state == RX_DATA))
            rx_bit_idx <= rx_bit_idx + 3'd1;
    end

    // RX serial-to-parallel conversion (8N1, LSB first)
    reg [7:0] rx_shift;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rx_shift <= 8'b0;
        else if ((rx_state == RX_DATA) && rx_bit_tick)
            rx_shift <= {rxd_sync, rx_shift[7:1]};
    end

    // RX buffer and status
    reg [7:0] rx_buf;
    reg       rx_full;
    reg [2:0] rx_lost_cnt;

    // RX buffer control events
    wire rx_frame_valid;
    wire rx_pop;
    wire rx_overrun;

    assign rx_frame_valid = (rx_state == RX_STOP)
                         && rx_bit_tick
                         && rxd_sync;

    assign rx_pop = rst_n
                 && ren
                 && (addr == 4'h4)
                 && rx_full;

    assign rx_overrun = rx_frame_valid
                     && rx_full
                     && !rx_pop;

    // RX buffer: Overwrite Old
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rx_buf <= 8'd0;
        else if (rx_frame_valid)
            rx_buf <= rx_shift;
    end

    // RX buffer valid status
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rx_full <= 1'b0;
        else if (rx_frame_valid)
            rx_full <= 1'b1;
        else if (rx_pop)
            rx_full <= 1'b0;
    end

    // RX lost-byte counter (saturating)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rx_lost_cnt <= 3'd0;
        else if (rx_pop)
            rx_lost_cnt <= 3'd0;
        else if (rx_overrun && (rx_lost_cnt != 3'd7))
            rx_lost_cnt <= rx_lost_cnt + 3'd1;
    end

    // MMIO combinational readback (independent of ren)
    // RX data and status fields are placeholders until RX is implemented.
    always @(*) begin
        case (addr)
            4'h0:    rdata = {31'd0, tx_full};
            4'h4:    rdata = 32'd0;
            4'h8:    rdata = {30'd0, tx_busy, tx_full};
            4'hC:    rdata = {16'd0, baud_divisor};
            default: rdata = 32'd0;
        endcase
    end

endmodule
