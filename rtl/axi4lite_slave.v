// AXI4-Lite slave.
//
// Implements the five channels (AW, W, B, AR, R) with the handshake rules the spec
// actually requires, which are easy to get subtly wrong:
//
//   - A source that asserts VALID must hold it, and hold its payload stable, until the
//     sink asserts READY. VALID must never be withdrawn to "take back" a request.
//   - A sink may assert READY before VALID appears, or wait for it. Both are legal.
//   - READY must not be a combinational function of VALID in a way that creates a
//     zero-delay loop between master and slave. Here every READY is registered.
//
// The address map is deliberately small and has a hole in it, so that an unmapped
// access has something real to do: it must return SLVERR rather than silently
// succeeding or hanging the channel.
//
//   0x00          FIFO push port. A write here enqueues {addr[7:0], wdata} into the
//                 CDC FIFO. Reads return the FIFO status.
//   0x10 - 0x3C   scratch register file, 12 words, read/write.
//   anything else unmapped -> SLVERR, and the transaction still completes.

module axi4lite_slave #(
    parameter ADDR_W = 8,
    parameter DATA_W = 32
) (
    input  wire                aclk,
    input  wire                aresetn,

    // ---- write address channel
    input  wire [ADDR_W-1:0]   awaddr,
    input  wire                awvalid,
    output reg                 awready,

    // ---- write data channel
    input  wire [DATA_W-1:0]   wdata,
    input  wire [DATA_W/8-1:0] wstrb,
    input  wire                wvalid,
    output reg                 wready,

    // ---- write response channel
    output reg  [1:0]          bresp,
    output reg                 bvalid,
    input  wire                bready,

    // ---- read address channel
    input  wire [ADDR_W-1:0]   araddr,
    input  wire                arvalid,
    output reg                 arready,

    // ---- read data channel
    output reg  [DATA_W-1:0]   rdata,
    output reg  [1:0]          rresp,
    output reg                 rvalid,
    input  wire                rready,

    // ---- downstream FIFO push port (write domain of the CDC FIFO)
    output reg                 fifo_push,
    output reg  [ADDR_W+DATA_W-1:0] fifo_wdata,
    input  wire                fifo_full,
    input  wire                fifo_empty
);

    localparam RESP_OKAY   = 2'b00;
    localparam RESP_SLVERR = 2'b10;

    localparam ADDR_FIFO   = 8'h00;
    localparam REG_BASE    = 8'h10;
    localparam REG_TOP     = 8'h3C;

    reg [DATA_W-1:0] regfile [0:15];

    // Latched address and data. AW and W can arrive in either order and in different
    // cycles, so each is captured as it lands and the write is performed only once
    // both are present.
    reg [ADDR_W-1:0]   aw_hold;
    reg [DATA_W-1:0]   w_hold;
    reg [DATA_W/8-1:0] wstrb_hold;
    reg                aw_seen, w_seen;

    wire [ADDR_W-1:0] wr_addr = aw_hold;
    wire is_fifo_addr = (wr_addr == ADDR_FIFO);
    wire is_reg_addr  = (wr_addr >= REG_BASE) && (wr_addr <= REG_TOP) && (wr_addr[1:0] == 2'b00);

    // Byte-strobe merge. A partial write must leave the untouched lanes alone.
    function [DATA_W-1:0] merge;
        input [DATA_W-1:0]   old_v;
        input [DATA_W-1:0]   new_v;
        input [DATA_W/8-1:0] strb;
        integer i;
        begin
            merge = old_v;
            for (i = 0; i < DATA_W/8; i = i + 1)
                if (strb[i]) merge[8*i +: 8] = new_v[8*i +: 8];
        end
    endfunction

    integer j;

    // ------------------------------------------------------------- write path
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            awready    <= 1'b0;
            wready     <= 1'b0;
            bvalid     <= 1'b0;
            bresp      <= RESP_OKAY;
            aw_seen    <= 1'b0;
            w_seen     <= 1'b0;
            aw_hold    <= {ADDR_W{1'b0}};
            w_hold     <= {DATA_W{1'b0}};
            wstrb_hold <= {(DATA_W/8){1'b0}};
            fifo_push  <= 1'b0;
            fifo_wdata <= {(ADDR_W+DATA_W){1'b0}};
            for (j = 0; j < 16; j = j + 1) regfile[j] <= {DATA_W{1'b0}};
        end else begin
            fifo_push <= 1'b0;

            // Accept an address whenever we are not already holding one and no response
            // is outstanding. READY is registered, so it cannot depend combinationally
            // on VALID this cycle.
            awready <= !aw_seen && !bvalid;
            wready  <= !w_seen  && !bvalid;

            if (awvalid && awready) begin
                aw_hold <= awaddr;
                aw_seen <= 1'b1;
                awready <= 1'b0;
            end

            if (wvalid && wready) begin
                w_hold     <= wdata;
                wstrb_hold <= wstrb;
                w_seen     <= 1'b1;
                wready     <= 1'b0;
            end

            // Both halves present and no response in flight: perform the write.
            if (aw_seen && w_seen && !bvalid) begin
                if (is_reg_addr) begin
                    regfile[wr_addr[5:2]] <= merge(regfile[wr_addr[5:2]], w_hold, wstrb_hold);
                    bresp <= RESP_OKAY;
                end else if (is_fifo_addr) begin
                    // Backpressure: if the FIFO is full the push is refused and the
                    // master is told so, rather than dropping data silently.
                    if (!fifo_full) begin
                        fifo_push  <= 1'b1;
                        fifo_wdata <= {wr_addr, merge({DATA_W{1'b0}}, w_hold, wstrb_hold)};
                        bresp      <= RESP_OKAY;
                    end else begin
                        bresp <= RESP_SLVERR;
                    end
                end else begin
                    bresp <= RESP_SLVERR;
                end
                bvalid  <= 1'b1;
                aw_seen <= 1'b0;
                w_seen  <= 1'b0;
            end

            // Response handshake completes.
            if (bvalid && bready) bvalid <= 1'b0;
        end
    end

    // -------------------------------------------------------------- read path
    // The decode happens directly on araddr at acceptance: an AXI4-Lite read has no
    // separate data phase to defer it to, so there is nothing to hold the address for.

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            arready <= 1'b0;
            rvalid  <= 1'b0;
            rdata   <= {DATA_W{1'b0}};
            rresp   <= RESP_OKAY;
        end else begin
            arready <= !rvalid;

            if (arvalid && arready) begin
                arready <= 1'b0;
                rvalid  <= 1'b1;

                if (araddr == ADDR_FIFO) begin
                    // status word: {30'b0, empty, full}
                    rdata <= {{(DATA_W-2){1'b0}}, fifo_empty, fifo_full};
                    rresp <= RESP_OKAY;
                end else if ((araddr >= REG_BASE) && (araddr <= REG_TOP) && (araddr[1:0] == 2'b00)) begin
                    rdata <= regfile[araddr[5:2]];
                    rresp <= RESP_OKAY;
                end else begin
                    rdata <= {DATA_W{1'b0}};
                    rresp <= RESP_SLVERR;
                end
            end

            if (rvalid && rready) rvalid <= 1'b0;
        end
    end

endmodule
