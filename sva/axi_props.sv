// SystemVerilog assertions for cdc_bridge, written as a bind module.
//
// Binding rather than inlining keeps the RTL free of verification code and lets the
// same properties be attached to a different instance, or left out of synthesis
// entirely, without editing the design.
//
// These do not run on the open-source flow: Verilator rejects ## delay expressions in
// sequences and Icarus does not parse property blocks at all. The equivalent checks
// are implemented procedurally in tb/tb_cdc.sv so that the open-source regression is
// still checking the same rules; if a property here changes, that file must change
// with it. On a commercial simulator this file is the authoritative version.
//
//   xrun -sv rtl/*.v tb/tb_cdc.sv sva/axi_props.sv +define+USE_SVA

module axi_props #(
    parameter ADDR_W  = 8,
    parameter DATA_W  = 32,
    parameter FIFO_AW = 4
) (
    input logic                aclk,
    input logic                aresetn,
    input logic [ADDR_W-1:0]   awaddr,
    input logic                awvalid,
    input logic                awready,
    input logic [DATA_W-1:0]   wdata,
    input logic                wvalid,
    input logic                wready,
    input logic [1:0]          bresp,
    input logic                bvalid,
    input logic                bready,
    input logic                arvalid,
    input logic                arready,
    input logic                rvalid,
    input logic                rready,

    input logic                bclk,
    input logic                bresetn,
    input logic                push,
    input logic                full,
    input logic                empty,
    input logic                pop,
    input logic [FIFO_AW:0]    wgray,
    input logic [FIFO_AW:0]    rgray
);

    default clocking cb @(posedge aclk); endclocking
    default disable iff (!aresetn);

    // ------------------------------------------------------------ AXI handshake
    // A source that has asserted VALID must keep it asserted until READY. Withdrawing
    // a request is the single most common AXI master bug and it deadlocks slaves that
    // have already begun servicing it.
    property p_awvalid_stable;
        awvalid && !awready |=> awvalid;
    endproperty
    a_awvalid_stable: assert property (p_awvalid_stable)
        else $error("AWVALID deasserted before AWREADY");

    property p_wvalid_stable;
        wvalid && !wready |=> wvalid;
    endproperty
    a_wvalid_stable: assert property (p_wvalid_stable)
        else $error("WVALID deasserted before WREADY");

    property p_bvalid_stable;
        bvalid && !bready |=> bvalid;
    endproperty
    a_bvalid_stable: assert property (p_bvalid_stable)
        else $error("BVALID deasserted before BREADY");

    // Payload must not change while a transfer is pending.
    property p_awaddr_stable;
        awvalid && !awready |=> $stable(awaddr);
    endproperty
    a_awaddr_stable: assert property (p_awaddr_stable)
        else $error("AWADDR changed while AWVALID held without AWREADY");

    property p_wdata_stable;
        wvalid && !wready |=> $stable(wdata);
    endproperty
    a_wdata_stable: assert property (p_wdata_stable)
        else $error("WDATA changed while WVALID held without WREADY");

    // Every accepted write must be answered. The bound is generous; the point is that
    // the response channel never simply stops.
    property p_write_answered;
        (awvalid && awready) |-> ##[1:32] (bvalid && bready);
    endproperty
    a_write_answered: assert property (p_write_answered)
        else $error("write accepted but never answered on the B channel");

    property p_read_answered;
        (arvalid && arready) |-> ##[1:32] (rvalid && rready);
    endproperty
    a_read_answered: assert property (p_read_answered)
        else $error("read accepted but never answered on the R channel");

    // Only OKAY and SLVERR are produced by this slave.
    a_bresp_legal: assert property (bvalid |-> bresp inside {2'b00, 2'b10})
        else $error("illegal BRESP encoding");

    // ------------------------------------------------------------- FIFO safety
    a_no_push_when_full: assert property (push |-> !full)
        else $error("push into a full FIFO");

    a_no_pop_when_empty: assert property (@(posedge bclk) disable iff (!bresetn)
                                          pop |-> !empty)
        else $error("pop from an empty FIFO");

    // ------------------------------------------------------- CDC correctness
    // The property that makes the crossing safe. A Gray pointer must change by exactly
    // one bit per clock; if two bits ever move together, a synchroniser sampling
    // mid-transition can latch a value that was never on the bus, and the FIFO's
    // full/empty logic will act on a pointer that does not exist.
    function automatic int unsigned onehot_delta(logic [FIFO_AW:0] a, logic [FIFO_AW:0] b);
        return $countones(a ^ b);
    endfunction

    property p_wgray_onehot;
        !$stable(wgray) |-> (onehot_delta(wgray, $past(wgray)) == 1);
    endproperty
    a_wgray_onehot: assert property (p_wgray_onehot)
        else $error("write Gray pointer changed more than one bit in a cycle");

    property p_rgray_onehot;
        @(posedge bclk) disable iff (!bresetn)
        !$stable(rgray) |-> (onehot_delta(rgray, $past(rgray)) == 1);
    endproperty
    a_rgray_onehot: assert property (p_rgray_onehot)
        else $error("read Gray pointer changed more than one bit in a cycle");

    // Full and empty are mutually exclusive once the pointers have been synchronised.
    a_not_full_and_empty: assert property (!(full && empty))
        else $error("FIFO reported full and empty simultaneously");

    // ------------------------------------------------------------------ cover
    // Coverage of the states that matter, so a passing regression that never reached
    // them is visibly distinguishable from one that did.
    c_fifo_full:        cover property (full);
    c_fifo_empty:       cover property (empty);
    c_slverr:           cover property (bvalid && bresp == 2'b10);
    c_push_while_full:  cover property (full && awvalid && awready);
    c_simultaneous_aw_w: cover property ((awvalid && awready) && (wvalid && wready));

endmodule

// ---------------------------------------------------------------------- bind
bind cdc_bridge axi_props #(
    .ADDR_W(ADDR_W), .DATA_W(DATA_W), .FIFO_AW(FIFO_AW)
) u_axi_props (
    .aclk(aclk), .aresetn(aresetn),
    .awaddr(awaddr), .awvalid(awvalid), .awready(awready),
    .wdata(wdata), .wvalid(wvalid), .wready(wready),
    .bresp(bresp), .bvalid(bvalid), .bready(bready),
    .arvalid(arvalid), .arready(arready),
    .rvalid(rvalid), .rready(rready),
    .bclk(bclk), .bresetn(bresetn),
    .push(push), .full(full), .empty(empty), .pop(pop),
    .wgray(u_fifo.wgray), .rgray(u_fifo.rgray)
);
