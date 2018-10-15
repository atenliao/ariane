// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Florian Zaruba, ETH Zurich
// Date: 16.05.2017
// Description: Instruction Tracer Main Class


class instruction_tracer;
    // interface to the core
    virtual instruction_tracer_if tracer_if;
    // keep the decoded instructions in a queue
    logic [31:0] decode_queue [$];
    // keep the issued instructions in a queue
    logic [31:0] issue_queue [$];
    // issue scoreboard entries
    scoreboard_entry_t issue_sbe_queue [$];
    scoreboard_entry_t issue_sbe;
    // store resolved branches, get (mis-)predictions
    branchpredict_t bp [$];
    // shadow copy of the register files
    logic [63:0] gp_reg_file [32];
    logic [63:0] fp_reg_file [32];
    // 64 bit clock tick count
    longint unsigned clk_ticks;
    int f, commit_log;
    // address mapping
    // contains mappings of the form vaddr <-> paddr
    // should it print the instructions to the console
    logic display_instructions;
    logic [63:0] store_mapping[$], load_mapping[$], address_mapping;

    // static uvm_cmdline_processor uvcl = uvm_cmdline_processor::get_inst();


    function new(virtual instruction_tracer_if tracer_if, logic display_instructions);

        this.tracer_if = tracer_if;
        this.display_instructions = display_instructions;

    endfunction : new

    function void create_file(logic [5:0] cluster_id, logic [3:0] core_id);
        string fn, fn_commit_log;
        $sformat(fn, "trace_core_%h_%h.log", cluster_id, core_id);
        $sformat(fn_commit_log, "trace_core_%h_%h_commit.log", cluster_id, core_id);
        $display("[TRACER] Output filename is: %s", fn);

        this.f = $fopen(fn,"w");
        if (ENABLE_SPIKE_COMMIT_LOG) this.commit_log = $fopen(fn_commit_log, "w");
    endfunction : create_file

    task trace();
        logic [31:0] decode_instruction, issue_instruction, issue_commit_instruction;
        scoreboard_entry_t commit_instruction;
        // initialize register 0
        gp_reg_file [0] = 0;

        forever begin
            automatic branchpredict_t bp_instruction = '0;
            // new cycle, we are only interested if reset is de-asserted
            @(tracer_if.pck iff tracer_if.pck.rstn);
            // increment clock tick
            clk_ticks++;

            // -------------------
            // Instruction Decode
            // -------------------
            // we are decoding an instruction
            if (tracer_if.pck.fetch_valid && tracer_if.pck.fetch_ack) begin
                decode_instruction = tracer_if.pck.instruction;
                decode_queue.push_back(decode_instruction);
            end
            // -------------------
            // Instruction Issue
            // -------------------
            // we got a new issue ack, so put the element from the decode queue to
            // the issue queue
            if (tracer_if.pck.issue_ack && !tracer_if.pck.flush_unissued) begin
                issue_instruction = decode_queue.pop_front();
                issue_queue.push_back(issue_instruction);
                // also save the scoreboard entry to a separate issue queue
                issue_sbe_queue.push_back(scoreboard_entry_t'(tracer_if.pck.issue_sbe));
            end

            // --------------------
            // Address Translation
            // --------------------
            if (tracer_if.pck.st_valid) begin
                store_mapping.push_back(tracer_if.pck.st_paddr);
            end

            if (tracer_if.pck.ld_valid && !tracer_if.pck.ld_kill) begin
                load_mapping.push_back(tracer_if.pck.ld_paddr);
            end
            // ----------------------
            // Store predictions
            // ----------------------
            if (tracer_if.pck.resolve_branch.valid) begin
                bp.push_back(tracer_if.pck.resolve_branch);
            end
            // --------------
            //  Commit
            // --------------
            // we are committing an instruction
            for (int i = 0; i < 2; i++) begin
                if (tracer_if.pck.commit_ack[i]) begin
                    commit_instruction = scoreboard_entry_t'(tracer_if.pck.commit_instr[i]);
                    issue_commit_instruction = issue_queue.pop_front();
                    issue_sbe = issue_sbe_queue.pop_front();
                    // check if the instruction retiring is a load or store, get the physical address accordingly
                    if (tracer_if.pck.commit_instr[i].fu == LOAD)
                        address_mapping = load_mapping.pop_front();
                    else if (tracer_if.pck.commit_instr[i].fu == STORE)
                        address_mapping = store_mapping.pop_front();

                    if (tracer_if.pck.commit_instr[i].fu == CTRL_FLOW)
                        bp_instruction = bp.pop_front();
                    // the scoreboards issue entry still contains the immediate value as a result
                    // check if the write back is valid, if not we need to source the result from the register file
                    // as the most recent version of this register will be there.
                    if (tracer_if.pck.we_gpr[i] || tracer_if.pck.we_fpr[i]) begin
                        printInstr(issue_sbe, issue_commit_instruction, tracer_if.pck.wdata[i], address_mapping, tracer_if.pck.priv_lvl, tracer_if.pck.debug_mode, bp_instruction);
                    end else if (is_rd_fpr(commit_instruction.op)) begin
                        printInstr(issue_sbe, issue_commit_instruction, fp_reg_file[commit_instruction.rd], address_mapping, tracer_if.pck.priv_lvl, tracer_if.pck.debug_mode, bp_instruction);
                    end else begin
                        printInstr(issue_sbe, issue_commit_instruction, gp_reg_file[commit_instruction.rd], address_mapping, tracer_if.pck.priv_lvl, tracer_if.pck.debug_mode, bp_instruction);
                    end
                end
            end
            // --------------
            // Exceptions
            // --------------
            if (tracer_if.pck.exception.valid && !(tracer_if.pck.debug_mode && tracer_if.pck.exception.cause == riscv::BREAKPOINT)) begin
                // print exception
                printException(tracer_if.pck.commit_instr[0].pc, tracer_if.pck.exception.cause, tracer_if.pck.exception.tval);
            end
            // ----------------------
            // Commit Registers
            // ----------------------
            // update shadow reg files here
            for (int i = 0; i < 2; i++) begin
                if (tracer_if.pck.we_gpr[i] && tracer_if.pck.waddr[i] != 5'b0) begin
                    gp_reg_file[tracer_if.pck.waddr[i]] = tracer_if.pck.wdata[i];
                end else if (tracer_if.pck.we_fpr[i]) begin
                    fp_reg_file[tracer_if.pck.waddr[i]] = tracer_if.pck.wdata[i];
                end
            end
            // --------------
            // Flush Signals
            // --------------
            // flush un-issued instructions
            if (tracer_if.pck.flush_unissued) begin
                this.flushDecode();
            end
            // flush whole pipeline
            if (tracer_if.pck.flush) begin
                this.flush();
            end
        end

    endtask

    // flush all decoded instructions
    function void flushDecode ();
        decode_queue = {};
    endfunction

    // flush everything, we took an exception/interrupt
    function void flush ();
        this.flushDecode();
        // clear all elements in the queue
        issue_queue     = {};
        issue_sbe_queue = {};
        // also clear mappings
        store_mapping   = {};
        load_mapping    = {};
        bp              = {};
    endfunction

    function void printInstr(scoreboard_entry_t sbe, logic [31:0] instr, logic [63:0] result, logic [63:0] paddr, riscv::priv_lvl_t priv_lvl, logic debug_mode, branchpredict_t bp);
        instruction_trace_item iti = new ($time, clk_ticks, sbe, instr, this.gp_reg_file, this.fp_reg_file, result, paddr, priv_lvl, debug_mode, bp);
        // print instruction to console
        string print_instr = iti.printInstr();
        if (ENABLE_SPIKE_COMMIT_LOG && !debug_mode) begin
            $fwrite(this.commit_log, riscv::spikeCommitLog(sbe.pc, priv_lvl, instr, sbe.rd, result, is_rd_fpr(sbe.op)));
        end
        uvm_report_info( "Tracer",  print_instr, UVM_HIGH);
        $fwrite(this.f, {print_instr, "\n"});
    endfunction

    function void printException(logic [63:0] pc, logic [63:0] cause, logic [63:0] tval);
        exception_trace_item eti = new (pc, cause, tval);
        string print_ex = eti.printException();
        uvm_report_info( "Tracer",  print_ex, UVM_HIGH);
        $fwrite(this.f, {print_ex, "\n"});
    endfunction

    function void close();
        if (f) $fclose(this.f);
        if (ENABLE_SPIKE_COMMIT_LOG && this.commit_log) $fclose(this.commit_log);
    endfunction

endclass : instruction_tracer
