// Dual-clock asynchronous FIFO.
//
// The write and read pointers live in unrelated clock domains, so each is carried
// across as Gray code through a two-flop synchroniser. Gray coding is what makes the
// crossing safe: consecutive Gray values differ in exactly one bit, so if the
// synchroniser samples a pointer mid-transition the worst case is that it captures the
// old value or the new one, never a spurious third value. A binary pointer crossing
// 0111 -> 1000 has four bits settling at once and can be sampled as any of sixteen
// values, several of which are catastrophically wrong.
//
// Depth is 2**AW entries. The pointers are AW+1 bits wide: the extra MSB distinguishes
// "full" from "empty" when the low bits match.

module async_fifo #(
    parameter DW = 40,          // payload width
    parameter AW = 4            // address width; depth = 2**AW
) (
    // write domain
    input  wire           wclk,
    input  wire           wrst_n,
    input  wire           wr_en,
    input  wire [DW-1:0]  wr_data,
    output wire           full,

    // read domain
    input  wire           rclk,
    input  wire           rrst_n,
    input  wire           rd_en,
    output wire [DW-1:0]  rd_data,
    output wire           empty
);

    // ------------------------------------------------------------------ storage
    // Simple dual-port array. Written in the wclk domain, read combinationally in the
    // rclk domain. The read is only ever performed at an address the write side has
    // already finished writing, which the pointer handshake guarantees.
    reg [DW-1:0] mem [0:(1<<AW)-1];

    // Registered full/empty flags, declared here (ahead of first use) because the
    // net-declaration-style assigns below reference them: SystemVerilog elaborates
    // those in textual order, so a forward reference to a not-yet-declared reg is an
    // error under strict elaboration (Xcelium) even though Verilator and Icarus both
    // tolerate it.
    reg empty_r, full_r;

    // ------------------------------------------------------------- write pointers
    reg  [AW:0] wbin, wgray;
    wire [AW:0] wbin_next  = wbin + {{AW{1'b0}}, (wr_en & ~full_r)};
    wire [AW:0] wgray_next = (wbin_next >> 1) ^ wbin_next;

    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            wbin  <= {(AW+1){1'b0}};
            wgray <= {(AW+1){1'b0}};
        end else begin
            wbin  <= wbin_next;
            wgray <= wgray_next;
        end
    end

    always @(posedge wclk) begin
        if (wr_en && !full_r) mem[wbin[AW-1:0]] <= wr_data;
    end

    // -------------------------------------------------------------- read pointers
    reg  [AW:0] rbin, rgray;
    wire [AW:0] rbin_next  = rbin + {{AW{1'b0}}, (rd_en & ~empty_r)};
    wire [AW:0] rgray_next = (rbin_next >> 1) ^ rbin_next;

    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            rbin  <= {(AW+1){1'b0}};
            rgray <= {(AW+1){1'b0}};
        end else begin
            rbin  <= rbin_next;
            rgray <= rgray_next;
        end
    end

    assign rd_data = mem[rbin[AW-1:0]];

    // ------------------------------------------------- two-flop synchronisers
    // Each pointer is resynchronised into the opposite domain. Two flops is the
    // standard depth: the first may go metastable, the second gives it a full clock
    // period to resolve before anything downstream sees it.
    reg [AW:0] rgray_s1, rgray_s2;   // read pointer seen by the write domain
    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            rgray_s1 <= {(AW+1){1'b0}};
            rgray_s2 <= {(AW+1){1'b0}};
        end else begin
            rgray_s1 <= rgray;
            rgray_s2 <= rgray_s1;
        end
    end

    reg [AW:0] wgray_s1, wgray_s2;   // write pointer seen by the read domain
    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            wgray_s1 <= {(AW+1){1'b0}};
            wgray_s2 <= {(AW+1){1'b0}};
        end else begin
            wgray_s1 <= wgray;
            wgray_s2 <= wgray_s1;
        end
    end

    // ----------------------------------------------------------- full and empty
    // Both flags are REGISTERED, not combinational, and this is not a stylistic choice.
    //
    // The pointer increment has to be qualified by the flag (never write when full,
    // never read when empty). If the flag were also a combinational function of the
    // incremented pointer, the result is a genuine combinational loop:
    //
    //     empty -> rd_en qualification -> rbin_next -> rgray_next -> empty
    //
    // Registering the flag breaks the loop: the increment consumes last cycle's flag
    // while this cycle's flag is computed from the new pointer. The first version of
    // this file did compute both flags combinationally, and it did not simulate: the
    // simulator reported that the active region did not converge, which is what a
    // zero-delay feedback path looks like from the scheduler's point of view.
    //
    // Empty is the plain comparison: the read pointer has caught up with the write
    // pointer exactly, all bits including the wrap bit.
    wire empty_val = (rgray_next == wgray_s2);

    // Full is the same low bits but an inverted wrap bit, which in Gray code means
    // inverting the top *two* bits rather than one. That is a consequence of the Gray
    // encoding reflecting about its midpoint, not an arbitrary trick.
    wire full_val  = (wgray_next == {~rgray_s2[AW:AW-1], rgray_s2[AW-2:0]});

    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) empty_r <= 1'b1;   // a FIFO comes out of reset empty
        else         empty_r <= empty_val;
    end

    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) full_r <= 1'b0;
        else         full_r <= full_val;
    end

    assign empty = empty_r;
    assign full  = full_r;

    // Occupancy as the write side understands it, for testbench observation only.
    // Conservative by construction: it is computed from a synchronised (therefore
    // stale) read pointer, so it can only ever over-report how full the FIFO is,
    // never under-report. Over-reporting is the safe direction because it can only
    // cause an unnecessary stall, never an overflow.
    function [AW:0] gray2bin;
        input [AW:0] g;
        integer k;
        begin
            gray2bin[AW] = g[AW];
            for (k = AW-1; k >= 0; k = k - 1)
                gray2bin[k] = gray2bin[k+1] ^ g[k];
        end
    endfunction

endmodule
