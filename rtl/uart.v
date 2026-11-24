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

endmodule
