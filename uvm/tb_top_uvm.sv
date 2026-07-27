// UVM testbench top for cdc_bridge.
//
//   xrun -uvm -sv -timescale 1ns/1ps rtl/*.v uvm/axi_if.sv uvm/axi_pkg.sv \
//        uvm/tb_top_uvm.sv sva/axi_props.sv +UVM_TESTNAME=axi_random_test

`timescale 1ns/1ps

module tb_top_uvm;
    import uvm_pkg::*;
    import axi_pkg::*;
    `include "uvm_macros.svh"

    // Deliberately unrelated clocks: 100 MHz against 27 MHz drifts through every phase
    // relationship rather than settling into a repeating pattern, so the crossing is
    // exercised at arbitrary alignments over a long run.
    logic aclk = 0, bclk = 0;
    always #5.0000  aclk = ~aclk;
    always #18.5185 bclk = ~bclk;

    logic aresetn = 0, bresetn = 0;

    axi_if     #(.ADDR_W(8), .DATA_W(32)) vif (.aclk(aclk), .aresetn(aresetn));
    cdc_obs_if #(.PW(40)) obs (.aclk(aclk), .aresetn(aresetn),
                               .bclk(bclk), .bresetn(bresetn));

    logic        consume_en = 1;
    logic        cons_valid;
    logic [39:0] cons_data;
    logic [31:0] cons_count;

    cdc_bridge #(.ADDR_W(8), .DATA_W(32), .FIFO_AW(4)) dut (
        .aclk(aclk), .aresetn(aresetn),
        .awaddr(vif.awaddr), .awvalid(vif.awvalid), .awready(vif.awready),
        .wdata(vif.wdata), .wstrb(vif.wstrb), .wvalid(vif.wvalid), .wready(vif.wready),
        .bresp(vif.bresp), .bvalid(vif.bvalid), .bready(vif.bready),
        .araddr(vif.araddr), .arvalid(vif.arvalid), .arready(vif.arready),
        .rdata(vif.rdata), .rresp(vif.rresp), .rvalid(vif.rvalid), .rready(vif.rready),
        .bclk(bclk), .bresetn(bresetn), .consume_en(consume_en),
        .cons_valid(cons_valid), .cons_data(cons_data), .cons_count(cons_count)
    );

    // Expose the CDC boundary to the passive monitor.
    assign obs.push       = dut.push;
    assign obs.push_data  = dut.push_data;
    assign obs.cons_valid = cons_valid;
    assign obs.cons_data  = cons_data;

    // Bursty consumer. A per-cycle random enable never stalls long enough to fill a
    // 16-deep FIFO, so the full and backpressure paths go unexercised; long stalls are
    // what actually reach those states.
    initial begin
        forever begin
            consume_en <= 1'b1;
            repeat ($urandom_range(15, 50))  @(posedge bclk);
            consume_en <= 1'b0;
            repeat ($urandom_range(40, 140)) @(posedge bclk);
        end
    end

    initial begin
        uvm_config_db #(virtual axi_if)::set(null, "*", "vif", vif);
        uvm_config_db #(virtual cdc_obs_if)::set(null, "*", "obs_vif", obs);

        repeat (5) @(posedge aclk); aresetn = 1;
        repeat (5) @(posedge bclk); bresetn = 1;
    end

    initial begin
        run_test();
    end

    initial begin
        #5ms;
        `uvm_fatal("TIMEOUT", "simulation did not complete")
    end
endmodule
