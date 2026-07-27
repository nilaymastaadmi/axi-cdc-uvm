// Layered testbench for cdc_bridge.
//
// Structure mirrors a UVM environment: a transaction class, a scoreboard that owns the
// expected-value model, and a coverage collector with explicit bins. The driver and
// monitor are tasks rather than classes because this must run on an open-source
// simulator; the UVM port in uvm/ has them as proper components.
//
// Randomisation is done explicitly through $urandom_range rather than through rand /
// constraint blocks. That is deliberate: Verilator 5.020 accepts randomize() but does
// not enforce constraints, so a constraint-based generator would silently produce
// out-of-range stimulus and the coverage numbers would be fiction. Explicit generation
// gives the same distribution and is reproducible from a seed on any simulator.
//
// Correctness is decided by the scoreboard, not by inspection: every write the slave
// accepts with OKAY must reappear at the consumer exactly once, in order, with the
// byte-strobe merge applied. Any mismatch, any drop, any duplicate is a failure.

`timescale 1ns/1ps

// ---------------------------------------------------------------- transaction
class axi_txn;
    typedef enum {ADDR_FIFO, ADDR_REG, ADDR_UNMAPPED} addr_kind_e;

    bit [7:0]  addr;
    bit [31:0] data;
    bit [3:0]  strb;
    bit        is_read;
    addr_kind_e kind;

    // Explicit constrained generation. Weights chosen so that all three address
    // classes and all strobe shapes are reachable in a few hundred transactions.
    function void gen();
        int r;
        r = $urandom_range(0, 99);
        if (r < 55)      kind = ADDR_FIFO;
        else if (r < 90) kind = ADDR_REG;
        else             kind = ADDR_UNMAPPED;

        case (kind)
            ADDR_FIFO:     addr = 8'h00;
            ADDR_REG:      addr = 8'h10 + (8'(  $urandom_range(0, 11) ) << 2);
            ADDR_UNMAPPED: begin
                // Either above the mapped window or misaligned inside it, so both
                // decode failure modes are exercised.
                if ($urandom_range(0, 1)) addr = 8'h40 + 8'($urandom_range(0, 190));
                else                      addr = 8'h10 + 8'($urandom_range(1, 3));
            end
        endcase

        data = {$urandom(), $urandom()} [31:0];

        // Strobe shapes: full word, single byte, halfword, and arbitrary. Never zero,
        // which the spec permits but which has no observable effect here.
        r = $urandom_range(0, 99);
        if      (r < 45) strb = 4'hF;
        else if (r < 65) strb = 4'h1 << $urandom_range(0, 3);
        else if (r < 85) strb = $urandom_range(0, 1) ? 4'b0011 : 4'b1100;
        else             strb = 4'($urandom_range(1, 15));

        is_read = 0;
    endfunction

    function bit [31:0] masked() ;
        bit [31:0] m = 32'h0;
        for (int i = 0; i < 4; i++)
            if (strb[i]) m[8*i +: 8] = data[8*i +: 8];
        return m;
    endfunction

    function string convert2string();
        return $sformatf("addr=%02h data=%08h strb=%04b kind=%0d", addr, data, strb, kind);
    endfunction
endclass

// ----------------------------------------------------------------- scoreboard
class axi_scoreboard;
    bit [39:0] expect_q [$];
    int        n_pushed, n_popped, n_mismatch, n_okay, n_slverr;

    function void expect_push(bit [39:0] payload);
        expect_q.push_back(payload);
        n_pushed++;
    endfunction

    function void observe_pop(bit [39:0] got);
        bit [39:0] exp;
        n_popped++;
        if (expect_q.size() == 0) begin
            n_mismatch++;
            $display("[SCOREBOARD] FAIL: consumer produced %010h with nothing expected", got);
            return;
        end
        exp = expect_q.pop_front();
        if (exp !== got) begin
            n_mismatch++;
            $display("[SCOREBOARD] FAIL: expected %010h got %010h", exp, got);
        end
    endfunction

    function void report();
        $display("[SCOREBOARD] pushed=%0d popped=%0d outstanding=%0d mismatches=%0d",
                 n_pushed, n_popped, expect_q.size(), n_mismatch);
        $display("[SCOREBOARD] responses: OKAY=%0d SLVERR=%0d", n_okay, n_slverr);
    endfunction
endclass

// ------------------------------------------------------------------- coverage
// Explicit bin counters rather than covergroups: no open-source simulator implements
// covergroups, and a coverage number that cannot be reproduced is worthless. The bin
// definitions here are the same ones the UVM covergroup in uvm/ declares.
class axi_coverage;
    int cv_addr   [3];    // fifo / reg / unmapped
    int cv_strb   [4];    // full / single-byte / half / other
    int cv_resp   [2];    // OKAY / SLVERR
    int cv_occ    [5];    // fifo occupancy: empty / low / mid / high / full
    int cv_cross  [3][2]; // addr kind x response

    function void sample_txn(axi_txn t, bit [1:0] resp);
        int ai, si, ri;
        ai = int'(t.kind);
        if      (t.strb == 4'hF)                              si = 0;
        else if (t.strb inside {4'h1,4'h2,4'h4,4'h8})         si = 1;
        else if (t.strb inside {4'b0011,4'b1100})             si = 2;
        else                                                  si = 3;
        ri = (resp == 2'b00) ? 0 : 1;

        cv_addr[ai]++;
        cv_strb[si]++;
        cv_resp[ri]++;
        cv_cross[ai][ri]++;

        if (is_illegal_cross(ai, ri)) begin
            n_illegal_hit++;
            $display("[COVERAGE] FAIL: illegal cross hit (kind=%0d resp=%0d) -- decoder produced a response it must never produce", ai, ri);
        end
    endfunction

    function void sample_occupancy(int level, int depth);
        if      (level == 0)          cv_occ[0]++;
        else if (level <= depth/4)    cv_occ[1]++;
        else if (level <= depth/2)    cv_occ[2]++;
        else if (level <  depth)      cv_occ[3]++;
        else                          cv_occ[4]++;
    endfunction

    // Two of the six address-kind x response crosses are unreachable by construction,
    // and treating them as coverage holes would mean chasing stimulus that cannot
    // exist:
    //
    //   (REG, SLVERR)      a mapped, aligned register write always returns OKAY
    //   (UNMAPPED, OKAY)   an unmapped address always returns SLVERR
    //
    // In a covergroup these are illegal_bins, not ignore_bins: they are excluded from
    // the denominator AND hitting one is a failure, because it would mean the decoder
    // had accepted something it must reject. is_illegal_cross is checked on every
    // sample for exactly that reason.
    function bit is_illegal_cross(int a, int r);
        return (a == 1 && r == 1) || (a == 2 && r == 0);
    endfunction

    int n_illegal_hit;

    function int bins_total();
        return 3 + 4 + 2 + 5 + 4;   // 6 crosses less the 2 illegal ones
    endfunction

    function int bins_hit();
        int h = 0;
        foreach (cv_addr[i]) if (cv_addr[i] > 0) h++;
        foreach (cv_strb[i]) if (cv_strb[i] > 0) h++;
        foreach (cv_resp[i]) if (cv_resp[i] > 0) h++;
        foreach (cv_occ[i])  if (cv_occ[i]  > 0) h++;
        for (int a = 0; a < 3; a++)
            for (int r = 0; r < 2; r++)
                if (!is_illegal_cross(a, r) && cv_cross[a][r] > 0) h++;
        return h;
    endfunction

    function void report();
        real pct = 100.0 * real'(bins_hit()) / real'(bins_total());
        $display("[COVERAGE] address kind    fifo=%0d reg=%0d unmapped=%0d",
                 cv_addr[0], cv_addr[1], cv_addr[2]);
        $display("[COVERAGE] strobe shape    full=%0d single=%0d half=%0d other=%0d",
                 cv_strb[0], cv_strb[1], cv_strb[2], cv_strb[3]);
        $display("[COVERAGE] response        OKAY=%0d SLVERR=%0d", cv_resp[0], cv_resp[1]);
        $display("[COVERAGE] fifo occupancy  empty=%0d low=%0d mid=%0d high=%0d full=%0d",
                 cv_occ[0], cv_occ[1], cv_occ[2], cv_occ[3], cv_occ[4]);
        $display("[COVERAGE] cross(kind,resp) [%0d %0d][%0d %0d][%0d %0d]",
                 cv_cross[0][0], cv_cross[0][1], cv_cross[1][0], cv_cross[1][1],
                 cv_cross[2][0], cv_cross[2][1]);
        $display("[COVERAGE] illegal bins hit %0d (must be 0)", n_illegal_hit);
        $display("[COVERAGE] bins hit %0d / %0d = %0.1f%%", bins_hit(), bins_total(), pct);
    endfunction
endclass

// ------------------------------------------------------------------- testbench
module tb_cdc;

    localparam ADDR_W  = 8;
    localparam DATA_W  = 32;
    localparam FIFO_AW = 4;
    localparam DEPTH   = 1 << FIFO_AW;
    localparam PW      = ADDR_W + DATA_W;

    // Two unrelated clocks. 100 MHz against 27 MHz is deliberately awkward: the ratio
    // is irrational in cycle terms, so edges drift through every phase relationship
    // over a long run instead of settling into a repeating pattern.
    reg aclk = 0, bclk = 0;
    always #5.0000 aclk = ~aclk;      // 100.0 MHz
    always #18.5185 bclk = ~bclk;     // ~27.0 MHz

    reg aresetn = 0, bresetn = 0;

    reg  [ADDR_W-1:0]   awaddr;
    reg                 awvalid;
    wire                awready;
    reg  [DATA_W-1:0]   wdata;
    reg  [DATA_W/8-1:0] wstrb;
    reg                 wvalid;
    wire                wready;
    wire [1:0]          bresp;
    wire                bvalid;
    reg                 bready;
    reg  [ADDR_W-1:0]   araddr;
    reg                 arvalid;
    wire                arready;
    wire [DATA_W-1:0]   rdata;
    wire [1:0]          rresp;
    wire                rvalid;
    reg                 rready;

    reg                 consume_en;
    wire                cons_valid;
    wire [PW-1:0]       cons_data;
    wire [31:0]         cons_count;

    cdc_bridge #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .FIFO_AW(FIFO_AW)) dut (
        .aclk(aclk), .aresetn(aresetn),
        .awaddr(awaddr), .awvalid(awvalid), .awready(awready),
        .wdata(wdata), .wstrb(wstrb), .wvalid(wvalid), .wready(wready),
        .bresp(bresp), .bvalid(bvalid), .bready(bready),
        .araddr(araddr), .arvalid(arvalid), .arready(arready),
        .rdata(rdata), .rresp(rresp), .rvalid(rvalid), .rready(rready),
        .bclk(bclk), .bresetn(bresetn), .consume_en(consume_en),
        .cons_valid(cons_valid), .cons_data(cons_data), .cons_count(cons_count)
    );

    axi_scoreboard sb;
    axi_coverage   cov;

    int n_assert_checked, n_assert_failed;

    // ------------------------------------------------------- protocol checkers
    // Concurrent SVA properties are not supported by any open-source simulator here
    // (Verilator rejects ## delay expressions, Icarus rejects property blocks), so the
    // same rules are checked procedurally. sva/axi_props.sv carries the real SVA for a
    // commercial simulator; these two must stay in agreement.
    reg        aw_held;
    reg [7:0]  aw_held_addr;
    always @(posedge aclk) begin
        if (!aresetn) begin
            aw_held <= 0;
        end else begin
            // AWVALID must remain asserted with a stable payload until AWREADY.
            if (awvalid && !awready) begin
                n_assert_checked++;
                if (aw_held && aw_held_addr !== awaddr) begin
                    n_assert_failed++;
                    $display("[ASSERT] FAIL: AWADDR changed while AWVALID held without AWREADY");
                end
                aw_held      <= 1'b1;
                aw_held_addr <= awaddr;
            end else if (awvalid && awready) begin
                aw_held <= 1'b0;
            end

            // A push must never be issued into a full FIFO.
            if (dut.push) begin
                n_assert_checked++;
                if (dut.full) begin
                    n_assert_failed++;
                    $display("[ASSERT] FAIL: push asserted while FIFO full");
                end
            end
        end
    end

    // Gray pointers must only ever change by a single bit. This is the property that
    // makes the clock crossing safe; if it fails, the synchronisers can latch a value
    // that never existed.
    reg [FIFO_AW:0] wgray_prev, rgray_prev;
    reg             wg_init, rg_init;

    function automatic int popcount(input [FIFO_AW:0] v);
        int c = 0;
        for (int i = 0; i <= FIFO_AW; i++) if (v[i]) c++;
        return c;
    endfunction

    always @(posedge aclk) begin
        if (!aresetn) begin
            wg_init <= 0;
        end else begin
            if (wg_init) begin
                n_assert_checked++;
                if (dut.u_fifo.wgray !== wgray_prev && popcount(dut.u_fifo.wgray ^ wgray_prev) != 1) begin
                    n_assert_failed++;
                    $display("[ASSERT] FAIL: write Gray pointer changed %0d bits at once",
                             popcount(dut.u_fifo.wgray ^ wgray_prev));
                end
            end
            wgray_prev <= dut.u_fifo.wgray;
            wg_init    <= 1;
        end
    end

    always @(posedge bclk) begin
        if (!bresetn) begin
            rg_init <= 0;
        end else begin
            if (rg_init) begin
                n_assert_checked++;
                if (dut.u_fifo.rgray !== rgray_prev && popcount(dut.u_fifo.rgray ^ rgray_prev) != 1) begin
                    n_assert_failed++;
                    $display("[ASSERT] FAIL: read Gray pointer changed %0d bits at once",
                             popcount(dut.u_fifo.rgray ^ rgray_prev));
                end
            end
            rgray_prev <= dut.u_fifo.rgray;
            rg_init    <= 1;
        end
    end

    // ---------------------------------------------------------------- monitors
    // Write-side monitor. The expectation is registered when the DUT actually performs
    // the push, not when the driver thinks it did. Predicting from the driver is a
    // race: the consumer runs in another clock domain and can pop the payload before
    // the driver's write task has even returned its response, which is exactly what
    // happened in the first version of this testbench.
    always @(posedge aclk) begin
        if (aresetn && dut.push) sb.expect_push(dut.push_data);
    end

    // Read-side monitor. Hands every popped payload to the scoreboard.
    always @(posedge bclk) begin
        if (bresetn && cons_valid) sb.observe_pop(cons_data);
    end

    // Occupancy sampling for coverage, taken in the write domain.
    always @(posedge aclk) begin
        if (aresetn) cov.sample_occupancy(int'(dut.u_fifo.wbin - dut.u_fifo.gray2bin(dut.u_fifo.rgray_s2)), DEPTH);
    end

    // ----------------------------------------------------------------- driver
    // Drive and sample on the negedge.
    //
    // Every AXI handshake signal here is registered, so between one posedge and the
    // next it holds a constant value -- and that value is exactly what the upcoming
    // posedge will sample. Observing at the negedge therefore tells the driver what
    // the next clock edge is about to do, with no dependence on how the simulator
    // orders processes within the edge itself.
    //
    // Two earlier versions of this driver got that wrong. Sampling at the posedge
    // races the non-blocking update and missed BVALID, which is high for exactly one
    // cycle. Sampling at the posedge plus a small skew reads the post-update value,
    // so an AWREADY that was high at the edge reads back low and the handshake is
    // missed in the other direction. The negedge is the only point where the answer
    // is unambiguous.

    task automatic do_write(input axi_txn t, output bit [1:0] resp);
        bit aw_hit, w_hit, aw_done, w_done;

        @(negedge aclk);
        awaddr  = t.addr;
        awvalid = 1'b1;
        wdata   = t.data;
        wstrb   = t.strb;
        wvalid  = 1'b1;
        bready  = 1'b1;
        aw_done = 1'b0;
        w_done  = 1'b0;

        // AW and W are independent channels: either may be accepted first, or both
        // together. Each VALID is held until its own READY has been seen.
        while (!aw_done || !w_done) begin
            aw_hit = awvalid && awready;
            w_hit  = wvalid  && wready;
            @(negedge aclk);
            if (aw_hit) begin awvalid = 1'b0; aw_done = 1'b1; end
            if (w_hit ) begin wvalid  = 1'b0; w_done  = 1'b1; end
        end

        forever begin
            if (bvalid) begin
                resp = bresp;
                break;
            end
            @(negedge aclk);
        end
        @(negedge aclk);
        bready = 1'b0;
    endtask

    task automatic do_read(input bit [7:0] a, output bit [31:0] d, output bit [1:0] resp);
        @(negedge aclk);
        araddr  = a;
        arvalid = 1'b1;
        rready  = 1'b1;

        forever begin
            if (arvalid && arready) begin
                @(negedge aclk);
                arvalid = 1'b0;
                break;
            end
            @(negedge aclk);
        end

        forever begin
            if (rvalid) begin
                d    = rdata;
                resp = rresp;
                break;
            end
            @(negedge aclk);
        end
        @(negedge aclk);
        rready = 1'b0;
    endtask

    // ------------------------------------------------------------------ tests
    int seed;
    int n_txn;
    string testname;

    task automatic drive_and_score(axi_txn t);
        bit [1:0] resp;
        do_write(t, resp);
        cov.sample_txn(t, resp);
        if (resp == 2'b00) sb.n_okay++;
        else               sb.n_slverr++;
    endtask

    initial begin
        if (!$value$plusargs("seed=%d", seed))  seed  = 1;
        if (!$value$plusargs("n=%d",    n_txn)) n_txn = 300;
        if (!$value$plusargs("test=%s", testname)) testname = "random";

        sb  = new();
        cov = new();

        awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
        awaddr = 0; wdata = 0; wstrb = 0; araddr = 0;
        consume_en = 1;

        // Deterministic from the seed so any run is reproducible.
        void'($urandom(seed));

        repeat (5) @(posedge aclk);
        aresetn = 1;
        repeat (5) @(posedge bclk);
        bresetn = 1;
        repeat (5) @(posedge aclk);

        case (testname)
            // ---- directed: one write, end to end
            "smoke": begin
                axi_txn t = new();
                t.kind = axi_txn::ADDR_FIFO;
                t.addr = 8'h00; t.data = 32'hDEAD_BEEF; t.strb = 4'hF;
                drive_and_score(t);
                repeat (40) @(posedge bclk);
            end

            // ---- unmapped and misaligned addresses must return SLVERR
            "error_response": begin
                axi_txn t;
                bit [1:0] resp;
                bit [31:0] d;
                // Three addresses above the mapped window, three misaligned inside
                // it. The misaligned ones must land on 0x11/0x12/0x13, not 0x14 --
                // 0x14 is a perfectly valid aligned register and returns OKAY. An
                // earlier version of this loop used 0x14 and labelled it unmapped,
                // which the illegal-bin check caught immediately: the coverage model
                // knew (unmapped, OKAY) was impossible, so the test had to be wrong.
                foreach_addr: for (int a = 0; a < 6; a++) begin
                    t = new();
                    t.kind = axi_txn::ADDR_UNMAPPED;
                    t.addr = (a < 3) ? 8'(8'h80 + a) : 8'(8'h0E + a);
                    t.data = 32'hA5A5_0000 + a; t.strb = 4'hF;
                    drive_and_score(t);
                end
                // reads of unmapped space too
                do_read(8'hF0, d, resp);
                n_assert_checked++;
                if (resp !== 2'b10) begin
                    n_assert_failed++;
                    $display("[ASSERT] FAIL: unmapped read returned %b not SLVERR", resp);
                end
                repeat (20) @(posedge bclk);
            end

            // ---- register file write/read-back including partial strobes
            "regfile": begin
                axi_txn t;
                bit [1:0] resp;
                bit [31:0] rd, model [12];
                for (int i = 0; i < 12; i++) model[i] = 32'h0;
                for (int i = 0; i < 60; i++) begin
                    t = new();
                    t.gen();
                    t.kind = axi_txn::ADDR_REG;
                    t.addr = 8'(8'h10 + ((i % 12) << 2));
                    drive_and_score(t);
                    for (int bidx = 0; bidx < 4; bidx++)
                        if (t.strb[bidx]) model[i % 12][8*bidx +: 8] = t.data[8*bidx +: 8];
                end
                for (int i = 0; i < 12; i++) begin
                    do_read(8'(8'h10 + (i << 2)), rd, resp);
                    n_assert_checked++;
                    if (rd !== model[i]) begin
                        n_assert_failed++;
                        $display("[ASSERT] FAIL: reg[%0d] expected %08h got %08h", i, model[i], rd);
                    end
                end
            end

            // ---- consumer stalled: FIFO must fill, then refuse pushes with SLVERR
            "fifo_full": begin
                axi_txn t;
                int slverr_seen = 0;
                consume_en = 0;
                for (int i = 0; i < DEPTH + 6; i++) begin
                    t = new();
                    t.kind = axi_txn::ADDR_FIFO;
                    t.addr = 8'h00; t.data = 32'(32'h1000 + i); t.strb = 4'hF;
                    drive_and_score(t);
                end
                slverr_seen = sb.n_slverr;
                n_assert_checked++;
                if (slverr_seen == 0) begin
                    n_assert_failed++;
                    $display("[ASSERT] FAIL: FIFO never reported full under a stalled consumer");
                end
                // release the consumer and let everything drain
                consume_en = 1;
                repeat (400) @(posedge bclk);
            end

            // ---- back-to-back writes with no idle cycles between them
            "back_to_back": begin
                axi_txn t;
                for (int i = 0; i < 64; i++) begin
                    t = new();
                    t.kind = axi_txn::ADDR_FIFO;
                    t.addr = 8'h00; t.data = 32'(32'hB2B0_0000 + i); t.strb = 4'hF;
                    drive_and_score(t);
                end
                repeat (600) @(posedge bclk);
            end

            // ---- the main regression: constrained-random traffic with a consumer
            //      that stalls at random, so the crossing is exercised at every
            //      occupancy level rather than always running near-empty.
            default: begin
                axi_txn t;
                int gap, burst, stall;
                fork
                    // Bursty consumer. A per-cycle random enable never stalls long
                    // enough to fill a 16-deep FIFO, so occupancy never leaves the
                    // low bins and the full/backpressure path goes unexercised. Long
                    // stalls are what actually reach the interesting states.
                    begin
                        forever begin
                            burst = $urandom_range(15, 50);
                            consume_en <= 1'b1;
                            for (int k = 0; k < burst; k++) @(posedge bclk);
                            stall = $urandom_range(40, 140);
                            consume_en <= 1'b0;
                            for (int k = 0; k < stall; k++) @(posedge bclk);
                        end
                    end
                    begin
                        for (int i = 0; i < n_txn; i++) begin
                            t = new();
                            t.gen();
                            drive_and_score(t);
                            if ($urandom_range(0, 99) < 20) begin
                                gap = $urandom_range(1, 4);
                                for (int g = 0; g < gap; g++) @(posedge aclk);
                            end
                        end
                    end
                join_any
                consume_en = 1;
                repeat (2000) @(posedge bclk);
            end
        endcase

        // let anything still in flight drain
        repeat (200) @(posedge bclk);

        $display("");
        $display("=== TEST: %s  seed=%0d ===", testname, seed);
        sb.report();
        cov.report();
        $display("[ASSERT] checked=%0d failed=%0d", n_assert_checked, n_assert_failed);

        if (sb.n_mismatch == 0 && n_assert_failed == 0 && sb.expect_q.size() == 0
            && cov.n_illegal_hit == 0)
            $display("=== RESULT: PASS ===");
        else
            $display("=== RESULT: FAIL ===");
        $finish;
    end

    // watchdog
    initial begin
        #5_000_000;
        $display("=== RESULT: FAIL (timeout) ===");
        $finish;
    end

endmodule
