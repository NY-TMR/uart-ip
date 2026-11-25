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
    wire tx_step;  // TODO: bit timing
    wire tx_done;  // TODO: frame completion

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

endmodule
