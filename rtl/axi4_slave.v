// AXI4 (full) slave: bursts, IDs, multiple outstanding writes, out-of-order responses.
//
// This replaces rtl/axi4lite_slave.v. The address map keeps every AXI4-Lite behaviour
// that existed before, unchanged, and adds one new thing: a burst-capable window that
// pushes multi-beat bursts into the same CDC FIFO async_fifo.v already owns.
//
//   0x00           legacy FIFO port, single-beat only (AWLEN/ARLEN must be 0).
//                  Exactly the original AXI4-Lite behaviour: write enqueues one payload,
//                  read returns the status word. A burst arriving here is rejected
//                  (SLVERR, no side effect) rather than silently reinterpreted.
//   0x40 - 0x7C    burst-capable FIFO port, 16 words wide (matches the 16-beat maximum
//                  burst this slave accepts). INCR or WRAP, one push per beat, each
//                  beat's own computed address carried into the FIFO payload.
//   0x10 - 0x3C    register file, unchanged from the AXI4-Lite version: single-beat
//                  only. A burst here is rejected the same way as at 0x00.
//   anything else  SLVERR, transaction still completes -- same rule as before.
//
// Scope, stated rather than discovered by reading the RTL:
//   - AWSIZE/ARSIZE must encode the full data width (4 bytes/beat). Any other size
//     completes with SLVERR rather than attempting a sub-word access.
//   - AWBURST/ARBURST: only INCR and WRAP are executed. FIXED and the reserved
//     encoding complete with SLVERR, matching the "always answers, never hangs"
//     philosophy which already governs unmapped addresses.
//   - WRAP is only legal at the lengths AXI4 actually allows -- 2, 4, 8 or 16 beats
//     (AWLEN/ARLEN of 1, 3, 7, 15). Any other WRAP length completes with SLVERR.
//   - Reads are serviced one at a time, strictly in order. Only writes reorder across
//     IDs here, because only writes interact with the clock crossing this repo exists
//     to verify; a second outstanding read buys verification surface with no CDC
//     relevance.
//
// Multiple outstanding writes, and out-of-order responses:
//   Up to N_OUT write transactions are accepted concurrently, each into its own slot,
//   as long as no two simultaneously-outstanding slots share an AWID -- that one rule
//   is what keeps same-ID ordering trivially correct without a per-ID reorder buffer.
//   AXI4 requires write *data* to be consumed in the same order the addresses were
//   accepted (WD interleaving was removed going from AXI3 to AXI4), so the W channel
//   still drains exactly one slot at a time, in acceptance order -- there is only ever
//   one "current" burst consuming WDATA. What genuinely reorders is the B channel: once
//   a slot's data is fully consumed it just waits, and a round-robin arbiter grants BID
//   to whichever waiting slot the rotation currently favours. If two different-ID
//   bursts both finish their data within a few cycles of each other, the round robin
//   can (and does) answer them in a different order than their addresses were accepted
//   in -- correct under AXI4's ordering model, and the only way this design can produce
//   real reordering given a single ordered W channel feeding one FIFO.

module axi4_slave #(
    parameter ADDR_W = 8,
    parameter DATA_W = 32,
    parameter ID_W   = 4
) (
    input  wire                aclk,
    input  wire                aresetn,

    // ---- write address channel
    input  wire [ADDR_W-1:0]   awaddr,
    input  wire [ID_W-1:0]     awid,
    input  wire [7:0]          awlen,     // burst length - 1
    input  wire [2:0]          awsize,    // must be 3'b010 (4 bytes) -- see Scope
    input  wire [1:0]          awburst,   // 01=INCR, 10=WRAP supported -- see Scope
    input  wire                awvalid,
    output reg                 awready,

    // ---- write data channel
    input  wire [DATA_W-1:0]   wdata,
    input  wire [DATA_W/8-1:0] wstrb,
    input  wire                wlast,
    input  wire                wvalid,
    output reg                 wready,

    // ---- write response channel
    output reg  [1:0]          bresp,
    output reg  [ID_W-1:0]     bid,
    output reg                 bvalid,
    input  wire                bready,

    // ---- read address channel
    input  wire [ADDR_W-1:0]   araddr,
    input  wire [ID_W-1:0]     arid,
    input  wire [7:0]          arlen,
    input  wire [2:0]          arsize,
    input  wire [1:0]          arburst,
    input  wire                arvalid,
    output reg                 arready,

    // ---- read data channel
    output reg  [DATA_W-1:0]   rdata,
    output reg  [1:0]          rresp,
    output reg  [ID_W-1:0]     rid,
    output reg                 rlast,
    output reg                 rvalid,
    input  wire                rready,

    // ---- downstream FIFO push port (write domain of the CDC FIFO) -- unchanged
    // signature from the AXI4-Lite slave: one push per beat, regardless of whether
    // that beat came from the legacy single-beat port or the burst window.
    output reg                 fifo_push,
    output reg  [ADDR_W+DATA_W-1:0] fifo_wdata,
    input  wire                fifo_full,
    input  wire                fifo_empty
);

    localparam N_OUT = 4;   // outstanding write slots -- fixed, not derived from ID_W

    localparam RESP_OKAY   = 2'b00;
    localparam RESP_SLVERR = 2'b10;

    localparam KIND_FIFO    = 2'b00;
    localparam KIND_REG     = 2'b01;
    localparam KIND_INVALID = 2'b10;

    localparam ADDR_FIFO_LEGACY = 8'h00;
    localparam REG_BASE         = 8'h10;
    localparam REG_TOP          = 8'h3C;
    // Burst window: 0x40-0x7F, sized to exactly one 16-beat*4B burst.
    localparam BURST_WIN_HIGH   = 2'b01;   // awaddr[7:6]

    reg [DATA_W-1:0] regfile [0:15];
    integer j;

    // ---------------------------------------------------------- shared classification
    // Same rules for reads and writes: size must be the full data width, only INCR/WRAP
    // execute, WRAP length must be one AXI4 actually allows, and each region's own
    // single-beat-or-bounded-burst rule must hold.
    function automatic wrap_len_legal;
        input [7:0] len;
        begin
            wrap_len_legal = (len == 8'd1) || (len == 8'd3) || (len == 8'd7) || (len == 8'd15);
        end
    endfunction

    function automatic [1:0] classify_txn;
        input [ADDR_W-1:0] a;
        input [7:0]        len;
        input [2:0]        size;
        input [1:0]        burst;
        reg                is_fifo_legacy, is_fifo_burst, is_reg;
        reg [7:0]          last_off;
        begin
            is_fifo_legacy = (a == ADDR_FIFO_LEGACY);
            is_fifo_burst  = (a[7:6] == BURST_WIN_HIGH) && (a[1:0] == 2'b00);
            is_reg         = (a >= REG_BASE) && (a <= REG_TOP) && (a[1:0] == 2'b00);
            last_off       = a[5:0] + (len << 2);

            if (size != 3'b010)
                classify_txn = KIND_INVALID;                       // only full-width beats
            else if (burst == 2'b00 || burst == 2'b11)
                classify_txn = KIND_INVALID;                       // FIXED / reserved unsupported
            else if (burst == 2'b10 && !wrap_len_legal(len))
                classify_txn = KIND_INVALID;                       // illegal WRAP length
            else if (burst == 2'b10 && ((a[5:0] & wrapmask_for(len)[5:0]) != 6'd0))
                classify_txn = KIND_INVALID;                       // WRAP base not block-aligned
            else if (is_fifo_legacy)
                classify_txn = (len == 8'd0) ? KIND_FIFO : KIND_INVALID;
            else if (is_fifo_burst) begin
                // INCR grows linearly, so the *last* beat must still land in the window --
                // last_off is the check. WRAP never leaves the window in the first place:
                // masking a[5:0] by (block size - 1) only ever touches bits already inside
                // the window (a[7:6] is fixed by is_fifo_burst and untouched by the mask),
                // so applying the same linear bound to a WRAP burst would wrongly reject a
                // legal wrap block that sits near the top of the window (e.g. base 0x7C
                // wrapping within [0x70,0x7F]) even though every beat it visits is in range.
                if (burst == 2'b10) classify_txn = KIND_FIFO;
                else                classify_txn = (last_off <= 8'd60) ? KIND_FIFO : KIND_INVALID;
            end else if (is_reg)
                classify_txn = (len == 8'd0) ? KIND_REG : KIND_INVALID;
            else
                classify_txn = KIND_INVALID;                       // unmapped
        end
    endfunction

    function automatic [7:0] wrapmask_for;
        input [7:0] len;
        begin
            case (len)
                8'd1:    wrapmask_for = 8'd7;
                8'd3:    wrapmask_for = 8'd15;
                8'd7:    wrapmask_for = 8'd31;
                8'd15:   wrapmask_for = 8'd63;
                default: wrapmask_for = 8'd0;   // never consulted unless WRAP+legal length
            endcase
        end
    endfunction

    function automatic [ADDR_W-1:0] beat_addr_calc;
        input [ADDR_W-1:0] base;
        input              is_wrap;
        input [7:0]        wmask;
        input [7:0]        beat_idx;
        reg   [ADDR_W-1:0] lin;
        begin
            lin = base + (beat_idx << 2);
            beat_addr_calc = is_wrap ? ((base & ~wmask[ADDR_W-1:0]) | (lin & wmask[ADDR_W-1:0])) : lin;
        end
    endfunction

    // Byte-strobe merge, unchanged from the AXI4-Lite slave.
    function automatic [DATA_W-1:0] merge;
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

    // ============================================================== write side
    reg              slot_valid [0:N_OUT-1];
    reg [ID_W-1:0]   slot_id    [0:N_OUT-1];
    reg [ADDR_W-1:0] slot_base  [0:N_OUT-1];
    reg              slot_wrap  [0:N_OUT-1];
    reg [7:0]        slot_wmask [0:N_OUT-1];
    reg [1:0]        slot_kind  [0:N_OUT-1];
    reg [7:0]        slot_len   [0:N_OUT-1];
    reg [7:0]        slot_beat  [0:N_OUT-1];
    reg [1:0]        slot_resp  [0:N_OUT-1];
    reg              slot_done  [0:N_OUT-1];   // W data fully consumed, waiting for B

    // Order write addresses were accepted in. The W channel drains exactly this order --
    // AXI4 does not allow write-data interleaving across bursts -- so this is the only
    // ordering the design needs to enforce explicitly; the B channel is free to differ.
    reg [1:0] order_q [0:N_OUT-1];
    reg [2:0] order_cnt;
    reg [1:0] order_head, order_tail;

    // ---- admission (combinational, over *registered* slot state)
    reg              free_found;
    reg [1:0]        free_idx;
    reg              id_conflict;
    integer          k;
    always @(*) begin
        free_found  = 1'b0;
        free_idx    = 2'd0;
        id_conflict = 1'b0;
        for (k = 0; k < N_OUT; k = k + 1) begin
            if (!free_found && !slot_valid[k]) begin
                free_found = 1'b1;
                free_idx   = k[1:0];
            end
            if (slot_valid[k] && slot_id[k] == awid) id_conflict = 1'b1;
        end
    end

    wire accept_aw = awvalid && awready;
    wire [1:0] cur_stream_slot = order_q[order_head];
    wire       streaming       = (order_cnt != 3'd0);
    wire accept_w = wvalid && wready && streaming;

    // ---- B-channel round-robin arbiter (combinational scan over registered state)
    reg [1:0] rr_ptr;
    reg       grant_found;
    reg [1:0] grant_idx;
    integer   m;
    always @(*) begin
        grant_found = 1'b0;
        grant_idx   = 2'd0;
        for (m = 0; m < N_OUT; m = m + 1) begin
            if (!grant_found && slot_valid[(rr_ptr + m[1:0])] && slot_done[(rr_ptr + m[1:0])])
                begin grant_found = 1'b1; grant_idx = rr_ptr + m[1:0]; end
        end
    end
    wire b_free_this_cycle = (!bvalid) || (bvalid && bready);

    // Which slot the currently-presented B response belongs to, so it can be freed
    // exactly when the handshake completes rather than at grant time. Declared here,
    // ahead of the always block below that reads it: async_fifo.v's earlier fix was
    // exactly this lesson -- Xcelium rejects a forward reference to a not-yet-declared
    // reg even though Verilator and Icarus would tolerate it.
    reg [1:0] grant_idx_latched;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            awready    <= 1'b0;
            wready     <= 1'b0;
            bvalid     <= 1'b0;
            bresp      <= RESP_OKAY;
            bid        <= {ID_W{1'b0}};
            order_cnt  <= 3'd0;
            order_head <= 2'd0;
            order_tail <= 2'd0;
            rr_ptr     <= 2'd0;
            fifo_push  <= 1'b0;
            fifo_wdata <= {(ADDR_W+DATA_W){1'b0}};
            for (j = 0; j < N_OUT; j = j + 1) begin
                slot_valid[j] <= 1'b0;
                slot_id[j]    <= {ID_W{1'b0}};
                slot_base[j]  <= {ADDR_W{1'b0}};
                slot_wrap[j]  <= 1'b0;
                slot_wmask[j] <= 8'd0;
                slot_kind[j]  <= KIND_INVALID;
                slot_len[j]   <= 8'd0;
                slot_beat[j]  <= 8'd0;
                slot_resp[j]  <= RESP_OKAY;
                slot_done[j]  <= 1'b0;
            end
            for (j = 0; j < 16; j = j + 1) regfile[j] <= {DATA_W{1'b0}};
        end else begin
            fifo_push <= 1'b0;

            // -------- admission: a free slot, no ID already outstanding
            //
            // Gated by awvalid at the point of the check, not just at the point of use.
            // id_conflict depends on awid, and AWID is only guaranteed stable once AWVALID
            // is actually asserted -- unlike the AXI4-Lite version's `!aw_seen && !bvalid`,
            // which depended on no incoming field at all and so had no such hazard. Without
            // the awvalid gate here, a don't-care awid sampled while awvalid was low could
            // register a false "no conflict" that wrongly admits a genuinely conflicting ID
            // the following cycle.
            awready <= awvalid && free_found && !id_conflict;

            if (accept_aw) begin
                slot_valid[free_idx] <= 1'b1;
                slot_id[free_idx]    <= awid;
                slot_base[free_idx]  <= awaddr;
                slot_wrap[free_idx]  <= (awburst == 2'b10);
                slot_wmask[free_idx] <= wrapmask_for(awlen);
                slot_kind[free_idx]  <= classify_txn(awaddr, awlen, awsize, awburst);
                slot_len[free_idx]   <= awlen;
                slot_beat[free_idx]  <= 8'd0;
                slot_resp[free_idx]  <= (classify_txn(awaddr, awlen, awsize, awburst) == KIND_INVALID)
                                        ? RESP_SLVERR : RESP_OKAY;
                slot_done[free_idx]  <= 1'b0;

                order_q[order_tail] <= free_idx;
                order_tail          <= order_tail + 2'd1;
            end

            // -------- W channel: drains exactly one slot, in acceptance order
            wready <= streaming;

            if (accept_w) begin
                if (slot_kind[cur_stream_slot] == KIND_FIFO
                    && slot_resp[cur_stream_slot] != RESP_SLVERR && !fifo_full) begin
                    fifo_push  <= 1'b1;
                    fifo_wdata <= {beat_addr_calc(slot_base[cur_stream_slot], slot_wrap[cur_stream_slot],
                                                  slot_wmask[cur_stream_slot], slot_beat[cur_stream_slot]),
                                   merge({DATA_W{1'b0}}, wdata, wstrb)};
                end else if (slot_kind[cur_stream_slot] == KIND_FIFO && fifo_full) begin
                    slot_resp[cur_stream_slot] <= RESP_SLVERR;   // dropped beat -> whole burst errors
                end else if (slot_kind[cur_stream_slot] == KIND_REG
                             && slot_resp[cur_stream_slot] != RESP_SLVERR) begin
                    regfile[slot_base[cur_stream_slot][5:2]] <=
                        merge(regfile[slot_base[cur_stream_slot][5:2]], wdata, wstrb);
                end

                if (wlast) begin
                    slot_done[cur_stream_slot] <= 1'b1;
                    order_head                 <= order_head + 2'd1;
                end else begin
                    slot_beat[cur_stream_slot] <= slot_beat[cur_stream_slot] + 8'd1;
                end
            end

            // order_cnt has exactly one writer: a single net-change expression, not two
            // independent +1/-1 assignments in the accept_aw and wlast branches above. AW
            // acceptance and a burst's last beat can land in the same cycle (independent
            // channels), and two non-blocking assigns to the same reg in one always block
            // would let the textually-later one silently win instead of applying both --
            // net +1 (admit) and -1 (retire) would have collapsed to just -1.
            order_cnt <= order_cnt + (accept_aw ? 3'd1 : 3'd0)
                                    - ((accept_w && wlast) ? 3'd1 : 3'd0);

            // -------- B channel: round-robin across slots whose data is fully consumed.
            // Written from a single if/else, not two independent same-target assigns, so
            // "handshake completes and another response is immediately ready" resolves to
            // one unambiguous outcome (stay asserted, present the new response) instead of
            // depending on statement order.
            if (b_free_this_cycle) begin
                if (grant_found) begin
                    bvalid <= 1'b1;
                    bresp  <= slot_resp[grant_idx];
                    bid    <= slot_id[grant_idx];
                    rr_ptr <= grant_idx + 2'd1;
                end else begin
                    bvalid <= 1'b0;
                end
            end
            if (bvalid && bready) begin
                slot_valid[grant_idx_latched] <= 1'b0;
            end
        end
    end

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) grant_idx_latched <= 2'd0;
        else if (b_free_this_cycle && grant_found) grant_idx_latched <= grant_idx;
    end

    // ============================================================== read side
    // Single AR in flight at a time, strictly in order -- see Scope above. Response
    // content never depends on which beat of a burst is being presented here (the
    // status word and the "invalid" SLVERR/0 both hold for every beat), so unlike the
    // write side there is no per-beat address computation needed for read data.
    reg        ar_active;
    reg [7:0]  ar_len_r;
    reg [7:0]  ar_beat;
    reg [1:0]  ar_kind;
    reg [3:0]  ar_regidx;

    wire accept_ar = arvalid && arready;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            arready   <= 1'b0;
            rvalid    <= 1'b0;
            rdata     <= {DATA_W{1'b0}};
            rresp     <= RESP_OKAY;
            rid       <= {ID_W{1'b0}};
            rlast     <= 1'b0;
            ar_active <= 1'b0;
            ar_len_r  <= 8'd0;
            ar_beat   <= 8'd0;
            ar_kind   <= KIND_INVALID;
            ar_regidx <= 4'd0;
        end else begin
            arready <= !ar_active;

            if (accept_ar) begin
                ar_active <= 1'b1;
                ar_len_r  <= arlen;
                ar_beat   <= 8'd0;
                ar_kind   <= classify_txn(araddr, arlen, arsize, arburst);
                ar_regidx <= araddr[5:2];

                rvalid <= 1'b1;
                rid    <= arid;
                rlast  <= (arlen == 8'd0);

                case (classify_txn(araddr, arlen, arsize, arburst))
                    KIND_FIFO: begin
                        rdata <= {{(DATA_W-2){1'b0}}, fifo_empty, fifo_full};
                        rresp <= RESP_OKAY;
                    end
                    KIND_REG: begin
                        rdata <= regfile[araddr[5:2]];
                        rresp <= RESP_OKAY;
                    end
                    default: begin
                        rdata <= {DATA_W{1'b0}};
                        rresp <= RESP_SLVERR;
                    end
                endcase
            end else if (rvalid && rready) begin
                if (rlast) begin
                    rvalid    <= 1'b0;
                    ar_active <= 1'b0;
                end else begin
                    ar_beat <= ar_beat + 8'd1;
                    rlast   <= (ar_beat + 8'd1 == ar_len_r);
                    case (ar_kind)
                        KIND_FIFO: begin
                            rdata <= {{(DATA_W-2){1'b0}}, fifo_empty, fifo_full};
                            rresp <= RESP_OKAY;
                        end
                        default: begin   // KIND_REG never reaches here: regfile bursts are rejected
                            rdata <= {DATA_W{1'b0}};
                            rresp <= RESP_SLVERR;
                        end
                    endcase
                end
            end
        end
    end

endmodule
