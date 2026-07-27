// UVM verification environment for cdc_bridge.
//
// This is the same verification intent as tb/tb_cdc.sv expressed as a proper UVM
// environment: a sequence item, a driver/monitor/sequencer agent, a scoreboard
// connected by TLM analysis ports, a coverage subscriber, and a set of tests layered
// on a common base.
//
// It needs a simulator with the UVM library. Verilator has no UVM support and Icarus
// has no class-based constraint solver, so this is developed and run on Xcelium (or
// VCS) -- EDA Playground is sufficient. The open-source testbench in tb/ exists so the
// design is still regressed without a commercial licence; the two check the same
// properties and must be kept in agreement.
//
//   xrun -uvm -sv rtl/*.v uvm/axi_if.sv uvm/axi_pkg.sv uvm/tb_top_uvm.sv \
//        +UVM_TESTNAME=axi_random_test

package axi_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    typedef enum {ADDR_FIFO, ADDR_REG, ADDR_UNMAPPED} addr_kind_e;

    // ------------------------------------------------------------ sequence item
    class axi_txn extends uvm_sequence_item;
        rand bit [7:0]     addr;
        rand bit [31:0]    data;
        rand bit [3:0]     strb;
        rand addr_kind_e   kind;
             bit [1:0]     resp;      // filled in by the driver

        `uvm_object_utils_begin(axi_txn)
            `uvm_field_int(addr, UVM_ALL_ON)
            `uvm_field_int(data, UVM_ALL_ON)
            `uvm_field_int(strb, UVM_ALL_ON)
            `uvm_field_enum(addr_kind_e, kind, UVM_ALL_ON)
        `uvm_object_utils_end

        function new(string name = "axi_txn");
            super.new(name);
        endfunction

        // Address must agree with the declared kind, so the scoreboard can predict the
        // response without re-deriving the decode.
        constraint c_kind_dist {
            kind dist { ADDR_FIFO := 55, ADDR_REG := 35, ADDR_UNMAPPED := 10 };
        }

        constraint c_addr_matches_kind {
            (kind == ADDR_FIFO) -> addr == 8'h00;
            (kind == ADDR_REG)  -> (addr inside {[8'h10:8'h3C]} && addr[1:0] == 2'b00);
            (kind == ADDR_UNMAPPED) -> !(addr == 8'h00)
                                    && !(addr inside {[8'h10:8'h3C]} && addr[1:0] == 2'b00);
        }

        // A zero strobe is legal AXI but has no observable effect, so it is excluded
        // to keep every generated transaction meaningful.
        constraint c_strb_nonzero { strb != 4'h0; }

        constraint c_strb_shapes {
            strb dist { 4'hF := 45, 4'h1 := 5, 4'h2 := 5, 4'h4 := 5, 4'h8 := 5,
                        4'b0011 := 10, 4'b1100 := 10, [4'h3:4'hE] := 15 };
        }

        function bit [31:0] masked();
            bit [31:0] m = 32'h0;
            for (int i = 0; i < 4; i++)
                if (strb[i]) m[8*i +: 8] = data[8*i +: 8];
            return m;
        endfunction
    endclass

    // ------------------------------------------------------------------ sequencer
    typedef uvm_sequencer #(axi_txn) axi_sequencer;

    // --------------------------------------------------------------------- driver
    class axi_driver extends uvm_driver #(axi_txn);
        `uvm_component_utils(axi_driver)

        virtual axi_if vif;

        // Completed transactions, with the response actually received, published for
        // coverage. The driver is the only component that knows which request a given
        // response belongs to, so sampling the address off the bus at B-channel time
        // would be wrong: AWADDR has long since moved on.
        uvm_analysis_port #(axi_txn) ap_done;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            ap_done = new("ap_done", this);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual axi_if)::get(this, "", "vif", vif))
                `uvm_fatal("NOVIF", "virtual interface not set for axi_driver")
        endfunction

        task run_phase(uvm_phase phase);
            vif.awvalid <= 1'b0;
            vif.wvalid  <= 1'b0;
            vif.bready  <= 1'b0;
            @(posedge vif.aresetn);

            forever begin
                axi_txn t;
                seq_item_port.get_next_item(t);
                drive(t);
                seq_item_port.item_done();
            end
        endtask

        // Sampled on the negedge for the same reason as the open-source driver: every
        // handshake signal is registered, so at the negedge it holds exactly what the
        // upcoming posedge will sample, with no dependence on process ordering.
        task drive(axi_txn t);
            bit aw_hit, w_hit, aw_done, w_done;

            @(negedge vif.aclk);
            vif.awaddr  = t.addr;
            vif.awvalid = 1'b1;
            vif.wdata   = t.data;
            vif.wstrb   = t.strb;
            vif.wvalid  = 1'b1;
            vif.bready  = 1'b1;
            aw_done = 0; w_done = 0;

            while (!aw_done || !w_done) begin
                aw_hit = vif.awvalid && vif.awready;
                w_hit  = vif.wvalid  && vif.wready;
                @(negedge vif.aclk);
                if (aw_hit) begin vif.awvalid = 1'b0; aw_done = 1'b1; end
                if (w_hit ) begin vif.wvalid  = 1'b0; w_done  = 1'b1; end
            end

            forever begin
                if (vif.bvalid) begin
                    t.resp = vif.bresp;
                    break;
                end
                @(negedge vif.aclk);
            end
            @(negedge vif.aclk);
            vif.bready = 1'b0;
            ap_done.write(t);
        endtask
    endclass

    // ------------------------------------------------------------ CDC monitor
    // Watches both sides of the clock crossing. The expectation is taken from the
    // DUT's own push rather than predicted by the driver: the consumer runs in an
    // unrelated clock domain and can pop a payload before the driver's write task has
    // returned its response, so a driver-side prediction races the checker.
    class cdc_monitor extends uvm_monitor;
        `uvm_component_utils(cdc_monitor)

        virtual cdc_obs_if vif;
        uvm_analysis_port #(axi_txn) ap_push;
        uvm_analysis_port #(axi_txn) ap_pop;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            ap_push = new("ap_push", this);
            ap_pop  = new("ap_pop", this);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual cdc_obs_if)::get(this, "", "obs_vif", vif))
                `uvm_fatal("NOVIF", "observation interface not set for cdc_monitor")
        endfunction

        task run_phase(uvm_phase phase);
            fork
                forever begin
                    @(posedge vif.aclk);
                    if (vif.aresetn && vif.push) begin
                        axi_txn t = axi_txn::type_id::create("pushed");
                        t.addr = vif.push_data[39:32];
                        t.data = vif.push_data[31:0];
                        t.strb = 4'hF;      // payload is already strobe-merged by the slave
                        ap_push.write(t);
                    end
                end
                forever begin
                    @(posedge vif.bclk);
                    if (vif.bresetn && vif.cons_valid) begin
                        axi_txn t = axi_txn::type_id::create("popped");
                        t.addr = vif.cons_data[39:32];
                        t.data = vif.cons_data[31:0];
                        t.strb = 4'hF;
                        ap_pop.write(t);
                    end
                end
            join
        endtask
    endclass

    // ---------------------------------------------------------------------- agent
    class axi_agent extends uvm_agent;
        `uvm_component_utils(axi_agent)

        axi_driver    drv;
        axi_sequencer sqr;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (get_is_active() == UVM_ACTIVE) begin
                drv = axi_driver::type_id::create("drv", this);
                sqr = axi_sequencer::type_id::create("sqr", this);
            end
        endfunction

        function void connect_phase(uvm_phase phase);
            if (get_is_active() == UVM_ACTIVE)
                drv.seq_item_port.connect(sqr.seq_item_export);
        endfunction
    endclass

    // ----------------------------------------------------------------- scoreboard
    `uvm_analysis_imp_decl(_push)
    `uvm_analysis_imp_decl(_pop)

    class axi_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(axi_scoreboard)

        uvm_analysis_imp_push #(axi_txn, axi_scoreboard) push_imp;
        uvm_analysis_imp_pop  #(axi_txn, axi_scoreboard) pop_imp;

        bit [39:0] expect_q [$];
        int n_pushed, n_popped, n_mismatch;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            push_imp = new("push_imp", this);
            pop_imp  = new("pop_imp", this);
        endfunction

        function void write_push(axi_txn t);
            expect_q.push_back({t.addr, t.masked()});
            n_pushed++;
        endfunction

        function void write_pop(axi_txn t);
            bit [39:0] exp, got;
            got = {t.addr, t.data};
            n_popped++;
            if (expect_q.size() == 0) begin
                n_mismatch++;
                `uvm_error("SCBD", $sformatf("consumer produced %010h with nothing expected", got))
                return;
            end
            exp = expect_q.pop_front();
            if (exp !== got) begin
                n_mismatch++;
                `uvm_error("SCBD", $sformatf("expected %010h got %010h", exp, got))
            end
        endfunction

        function void check_phase(uvm_phase phase);
            if (expect_q.size() != 0)
                `uvm_error("SCBD", $sformatf("%0d payloads never reached the consumer",
                                             expect_q.size()))
            `uvm_info("SCBD", $sformatf("pushed=%0d popped=%0d mismatches=%0d",
                                        n_pushed, n_popped, n_mismatch), UVM_LOW)
        endfunction
    endclass

    // ------------------------------------------------------------------- coverage
    class axi_coverage extends uvm_subscriber #(axi_txn);
        `uvm_component_utils(axi_coverage)

        axi_txn tr;

        covergroup cg_axi;
            option.per_instance = 1;

            cp_kind: coverpoint tr.kind {
                bins fifo     = {ADDR_FIFO};
                bins reg_file = {ADDR_REG};
                bins unmapped = {ADDR_UNMAPPED};
            }

            cp_strb: coverpoint tr.strb {
                bins full_word = {4'hF};
                bins single    = {4'h1, 4'h2, 4'h4, 4'h8};
                bins half      = {4'b0011, 4'b1100};
                bins other     = default;
            }

            cp_resp: coverpoint tr.resp {
                bins okay   = {2'b00};
                bins slverr = {2'b10};
                illegal_bins reserved = {2'b01, 2'b11};
            }

            // The two impossible combinations are illegal_bins, not ignore_bins: a
            // mapped aligned register write can only return OKAY and an unmapped
            // address can only return SLVERR, so hitting either would mean the address
            // decoder had accepted something it must reject. Excluding them from the
            // denominator is correct; silently ignoring them would not be.
            x_kind_resp: cross cp_kind, cp_resp {
                illegal_bins reg_err   = binsof(cp_kind.reg_file) && binsof(cp_resp.slverr);
                illegal_bins unmap_ok  = binsof(cp_kind.unmapped) && binsof(cp_resp.okay);
            }
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cg_axi = new();
        endfunction

        function void write(axi_txn t);
            tr = t;
            cg_axi.sample();
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("COV", $sformatf("functional coverage %0.2f%%", cg_axi.get_coverage()),
                      UVM_LOW)
        endfunction
    endclass

    // ------------------------------------------------------------------ environment
    class axi_env extends uvm_env;
        `uvm_component_utils(axi_env)

        axi_agent      agt;
        cdc_monitor    cdc_mon;
        axi_scoreboard scb;
        axi_coverage   cov;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            agt     = axi_agent::type_id::create("agt", this);
            cdc_mon = cdc_monitor::type_id::create("cdc_mon", this);
            scb     = axi_scoreboard::type_id::create("scb", this);
            cov     = axi_coverage::type_id::create("cov", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            agt.drv.ap_done.connect(cov.analysis_export);
            cdc_mon.ap_push.connect(scb.push_imp);
            cdc_mon.ap_pop.connect(scb.pop_imp);
        endfunction
    endclass

    // -------------------------------------------------------------------- sequences
    class axi_base_seq extends uvm_sequence #(axi_txn);
        `uvm_object_utils(axi_base_seq)
        rand int unsigned n_txn = 300;

        function new(string name = "axi_base_seq");
            super.new(name);
        endfunction

        task body();
            repeat (n_txn) begin
                axi_txn t = axi_txn::type_id::create("t");
                start_item(t);
                if (!t.randomize())
                    `uvm_fatal("RAND", "transaction randomisation failed")
                finish_item(t);
            end
        endtask
    endclass

    class axi_fifo_only_seq extends axi_base_seq;
        `uvm_object_utils(axi_fifo_only_seq)
        function new(string name = "axi_fifo_only_seq"); super.new(name); endfunction

        task body();
            repeat (n_txn) begin
                axi_txn t = axi_txn::type_id::create("t");
                start_item(t);
                if (!t.randomize() with { kind == ADDR_FIFO; })
                    `uvm_fatal("RAND", "transaction randomisation failed")
                finish_item(t);
            end
        endtask
    endclass

    class axi_error_seq extends axi_base_seq;
        `uvm_object_utils(axi_error_seq)
        function new(string name = "axi_error_seq"); super.new(name); endfunction

        task body();
            repeat (n_txn) begin
                axi_txn t = axi_txn::type_id::create("t");
                start_item(t);
                if (!t.randomize() with { kind == ADDR_UNMAPPED; })
                    `uvm_fatal("RAND", "transaction randomisation failed")
                finish_item(t);
            end
        endtask
    endclass

    // ------------------------------------------------------------------------ tests
    class axi_base_test extends uvm_test;
        `uvm_component_utils(axi_base_test)
        axi_env env;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            env = axi_env::type_id::create("env", this);
        endfunction

        task run_phase(uvm_phase phase);
            axi_base_seq seq;
            phase.raise_objection(this);
            seq = axi_base_seq::type_id::create("seq");
            void'(seq.randomize() with { n_txn == 300; });
            seq.start(env.agt.sqr);
            #10us;
            phase.drop_objection(this);
        endtask
    endclass

    class axi_random_test extends axi_base_test;
        `uvm_component_utils(axi_random_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
    endclass

    class axi_fifo_full_test extends axi_base_test;
        `uvm_component_utils(axi_fifo_full_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        task run_phase(uvm_phase phase);
            axi_fifo_only_seq seq;
            phase.raise_objection(this);
            seq = axi_fifo_only_seq::type_id::create("seq");
            void'(seq.randomize() with { n_txn == 400; });
            seq.start(env.agt.sqr);
            #20us;
            phase.drop_objection(this);
        endtask
    endclass

    class axi_error_test extends axi_base_test;
        `uvm_component_utils(axi_error_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        task run_phase(uvm_phase phase);
            axi_error_seq seq;
            phase.raise_objection(this);
            seq = axi_error_seq::type_id::create("seq");
            void'(seq.randomize() with { n_txn == 100; });
            seq.start(env.agt.sqr);
            #10us;
            phase.drop_objection(this);
        endtask
    endclass

endpackage
