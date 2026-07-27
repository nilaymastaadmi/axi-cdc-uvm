// AXI4-Lite interface for the UVM environment.
//
// Kept as a plain interface with no clocking blocks: the driver samples on the negedge
// where every registered handshake signal already holds the value the next posedge
// will sample, which removes the race a clocking block would otherwise be needed to
// resolve, and keeps this interface usable from procedural code as well.

interface axi_if #(parameter ADDR_W = 8, parameter DATA_W = 32) (input logic aclk, input logic aresetn);
    logic [ADDR_W-1:0]   awaddr;
    logic                awvalid, awready;
    logic [DATA_W-1:0]   wdata;
    logic [DATA_W/8-1:0] wstrb;
    logic                wvalid, wready;
    logic [1:0]          bresp;
    logic                bvalid, bready;
    logic [ADDR_W-1:0]   araddr;
    logic                arvalid, arready;
    logic [DATA_W-1:0]   rdata;
    logic [1:0]          rresp;
    logic                rvalid, rready;

    modport master (
        input  aclk, aresetn, awready, wready, bresp, bvalid, arready, rdata, rresp, rvalid,
        output awaddr, awvalid, wdata, wstrb, wvalid, bready, araddr, arvalid, rready
    );
endinterface

// Observation interface for the CDC boundary.
//
// The scoreboard needs to see what the DUT actually pushed and what the consumer
// actually popped. Those are internal to cdc_bridge, so rather than let monitors reach
// into the hierarchy with absolute paths, the signals are exposed through a dedicated
// passive interface wired up once in the testbench top.
interface cdc_obs_if #(parameter PW = 40) (
    input logic aclk, input logic aresetn,
    input logic bclk, input logic bresetn
);
    logic          push;
    logic [PW-1:0] push_data;
    logic          cons_valid;
    logic [PW-1:0] cons_data;
endinterface
