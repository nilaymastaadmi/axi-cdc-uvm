// AXI4 to asynchronous-domain bridge.
//
// An AXI4 slave (rtl/axi4_slave.v: bursts, IDs, multiple outstanding writes, see that
// file for the address map and scope) runs on aclk. Writes to its FIFO ports -- the
// legacy single-beat port and the burst-capable window -- are enqueued into a
// dual-clock FIFO and drained by a consumer running on bclk, which is asynchronous to
// aclk with no defined phase or frequency relationship.
//
// The property the whole design exists to guarantee: every write the slave accepts
// with an OKAY response appears exactly once at the consumer, in order, with its
// payload intact, no matter how the two clocks happen to line up. That property, and
// the internal push/full/empty/pop signal names sva/axi_props.sv binds to, are
// unchanged from the AXI4-Lite version of this file -- bursts and IDs are handled
// entirely inside axi4_slave, one beat at a time, before anything reaches the FIFO.

module cdc_bridge #(
    parameter ADDR_W = 8,
    parameter DATA_W = 32,
    parameter FIFO_AW = 4,
    parameter ID_W    = 4
) (
    // ---- AXI domain
    input  wire                aclk,
    input  wire                aresetn,

    input  wire [ADDR_W-1:0]   awaddr,
    input  wire [ID_W-1:0]     awid,
    input  wire [7:0]          awlen,
    input  wire [2:0]          awsize,
    input  wire [1:0]          awburst,
    input  wire                awvalid,
    output wire                awready,
    input  wire [DATA_W-1:0]   wdata,
    input  wire [DATA_W/8-1:0] wstrb,
    input  wire                wlast,
    input  wire                wvalid,
    output wire                wready,
    output wire [1:0]          bresp,
    output wire [ID_W-1:0]     bid,
    output wire                bvalid,
    input  wire                bready,
    input  wire [ADDR_W-1:0]   araddr,
    input  wire [ID_W-1:0]     arid,
    input  wire [7:0]          arlen,
    input  wire [2:0]          arsize,
    input  wire [1:0]          arburst,
    input  wire                arvalid,
    output wire                arready,
    output wire [DATA_W-1:0]   rdata,
    output wire [1:0]          rresp,
    output wire [ID_W-1:0]     rid,
    output wire                rlast,
    output wire                rvalid,
    input  wire                rready,

    // ---- consumer domain
    input  wire                bclk,
    input  wire                bresetn,
    input  wire                consume_en,     // consumer-side backpressure control
    output wire                cons_valid,     // a payload was popped this cycle
    output wire [ADDR_W+DATA_W-1:0] cons_data,
    output wire [31:0]         cons_count      // running total popped, for checking
);

    localparam PW = ADDR_W + DATA_W;

    wire          push;
    wire [PW-1:0] push_data;
    wire          full, empty;

    axi4_slave #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W)) u_slave (
        .aclk(aclk), .aresetn(aresetn),
        .awaddr(awaddr), .awid(awid), .awlen(awlen), .awsize(awsize), .awburst(awburst),
        .awvalid(awvalid), .awready(awready),
        .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready),
        .bresp(bresp), .bid(bid), .bvalid(bvalid), .bready(bready),
        .araddr(araddr), .arid(arid), .arlen(arlen), .arsize(arsize), .arburst(arburst),
        .arvalid(arvalid), .arready(arready),
        .rdata(rdata), .rresp(rresp), .rid(rid), .rlast(rlast), .rvalid(rvalid), .rready(rready),
        .fifo_push(push), .fifo_wdata(push_data),
        .fifo_full(full), .fifo_empty(empty)
    );

    wire [PW-1:0] fifo_rdata;
    wire          pop = consume_en && !empty;

    async_fifo #(.DW(PW), .AW(FIFO_AW)) u_fifo (
        .wclk(aclk),  .wrst_n(aresetn), .wr_en(push), .wr_data(push_data), .full(full),
        .rclk(bclk),  .rrst_n(bresetn), .rd_en(pop),  .rd_data(fifo_rdata), .empty(empty)
    );

    // ------------------------------------------------------------ consumer side
    reg [PW-1:0] cons_data_r;
    reg          cons_valid_r;
    reg [31:0]   cons_count_r;

    always @(posedge bclk or negedge bresetn) begin
        if (!bresetn) begin
            cons_data_r  <= {PW{1'b0}};
            cons_valid_r <= 1'b0;
            cons_count_r <= 32'd0;
        end else begin
            cons_valid_r <= pop;
            if (pop) begin
                cons_data_r  <= fifo_rdata;
                cons_count_r <= cons_count_r + 32'd1;
            end
        end
    end

    assign cons_valid = cons_valid_r;
    assign cons_data  = cons_data_r;
    assign cons_count = cons_count_r;

endmodule
