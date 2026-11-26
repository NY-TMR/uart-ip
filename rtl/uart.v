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
