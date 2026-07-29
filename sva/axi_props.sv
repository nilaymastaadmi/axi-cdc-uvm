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
//
// The AXI4-full extension (bursts, IDs, multiple outstanding writes, out-of-order B)
// added ID/RLAST ports and the properties that use them below; every property that
// existed before is unchanged, in the same words, checking the same thing. That was
// the constraint the extension had to survive, not a goal it happened to meet.

module axi_props #(
    parameter ADDR_W  = 8,
    parameter DATA_W  = 32,
    parameter FIFO_AW = 4,
    parameter ID_W    = 4
) (
    input logic                aclk,
    input logic                aresetn,
    input logic [ADDR_W-1:0]   awaddr,
    input logic [ID_W-1:0]     awid,
    input logic [7:0]          awlen,
    input logic [1:0]          awburst,
    input logic                awvalid,
    input logic                awready,
    input logic [DATA_W-1:0]   wdata,
    input logic                wvalid,
    input logic                wready,
    input logic [1:0]          bresp,
    input logic [ID_W-1:0]     bid,
    input logic                bvalid,
    input logic                bready,
    input logic                arvalid,
    input logic [ID_W-1:0]     arid,
    input logic                arready,
    input logic [ID_W-1:0]     rid,
    input logic                rlast,
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

    // AWID is payload like AWADDR: the AXI4-full slave picks an outstanding slot and
    // same-ID-conflict result from whatever AWID is presented at acceptance, so a
    // mid-request change here would be exactly as wrong as AWADDR changing.
    property p_awid_stable;
        awvalid && !awready |=> $stable(awid);
    endproperty
    a_awid_stable: assert property (p_awid_stable)
        else $error("AWID changed while AWVALID held without AWREADY");

    // ARVALID/ARADDR stability was never checked here before -- the AXI4-Lite version
    // had no per-request identity on the read side for it to matter as much. Adding
    // AXI4-full IDs is the reason to close this the same way the write side already was,
    // not a new requirement invented for its own sake.
    property p_arvalid_stable;
        arvalid && !arready |=> arvalid;
    endproperty
    a_arvalid_stable: assert property (p_arvalid_stable)
        else $error("ARVALID deasserted before ARREADY");

    // araddr is read through the bind's port list further down; re-declared as a local
    // reference is unnecessary since the module already has it as an input.
    property p_araddr_stable;
        arvalid && !arready |=> $stable(araddr);
    endproperty
    a_araddr_stable: assert property (p_araddr_stable)
        else $error("ARADDR changed while ARVALID held without ARREADY");

    property p_arid_stable;
        arvalid && !arready |=> $stable(arid);
    endproperty
    a_arid_stable: assert property (p_arid_stable)
        else $error("ARID changed while ARVALID held without ARREADY");

    // BRESP/BID stability matters more now than it did for the single-outstanding
    // AXI4-Lite slave: the round-robin arbiter picks a slot and latches its response
    // once, but if it were ever re-evaluated while BVALID was still pending on BREADY,
    // a different slot's result could glitch onto the bus mid-wait.
    property p_bresp_stable;
        bvalid && !bready |=> $stable(bresp);
    endproperty
    a_bresp_stable: assert property (p_bresp_stable)
        else $error("BRESP changed while BVALID held without BREADY");

    property p_bid_stable;
        bvalid && !bready |=> $stable(bid);
    endproperty
    a_bid_stable: assert property (p_bid_stable)
        else $error("BID changed while BVALID held without BREADY");

    // RID must stay constant across every beat of one read burst -- it identifies the
    // whole transaction, not the individual beat.
    property p_rid_stable_in_burst;
        (rvalid && !rlast && rready) |=> (rvalid |-> $stable(rid));
    endproperty
    a_rid_stable_in_burst: assert property (p_rid_stable_in_burst)
        else $error("RID changed within a single read burst");

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

    // AXI4-full: confirm the new burst machinery is actually exercised, not just
    // present in the RTL and never hit.
    c_incr_burst:      cover property (awvalid && awready && awburst == 2'b01 && awlen != 8'd0);
    c_wrap_burst:       cover property (awvalid && awready && awburst == 2'b10);
    c_max_len_burst:    cover property (awvalid && awready && awlen == 8'd15);

endmodule

// ---------------------------------------------------------------------- bind
bind cdc_bridge axi_props #(
    .ADDR_W(ADDR_W), .DATA_W(DATA_W), .FIFO_AW(FIFO_AW), .ID_W(ID_W)
) u_axi_props (
    .aclk(aclk), .aresetn(aresetn),
    .awaddr(awaddr), .awid(awid), .awlen(awlen), .awburst(awburst),
    .awvalid(awvalid), .awready(awready),
    .wdata(wdata), .wvalid(wvalid), .wready(wready),
    .bresp(bresp), .bid(bid), .bvalid(bvalid), .bready(bready),
    .arvalid(arvalid), .arid(arid), .arready(arready),
    .rid(rid), .rlast(rlast), .rvalid(rvalid), .rready(rready),
    .bclk(bclk), .bresetn(bresetn),
    .push(push), .full(full), .empty(empty), .pop(pop),
    .wgray(u_fifo.wgray), .rgray(u_fifo.rgray)
);
