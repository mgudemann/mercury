%----------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%----------------------------------------------------------------------------%
% Copyright (C) 2009-2011 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%----------------------------------------------------------------------------%
%
% File: llds_out_instr.m.
% Main authors: conway, fjh, zs.
%
% This module defines the routines for printing out LLDS instructions.
%
%----------------------------------------------------------------------------%

:- module ll_backend.llds_out.llds_out_instr.
:- interface.

:- import_module ll_backend.llds.
:- import_module ll_backend.llds_out.llds_out_util.

:- import_module io.
:- import_module list.
:- import_module pair.
:- import_module set_tree234.

%----------------------------------------------------------------------------%

:- pred output_record_instruction_decls(llds_out_info::in, instruction::in,
    decl_set::in, decl_set::out, io::di, io::uo) is det.

:- type after_layout_label
    --->    not_after_layout_label
    ;       after_layout_label.

:- pred output_instruction_list(llds_out_info::in, list(instruction)::in,
    pair(label, set_tree234(label))::in, set_tree234(label)::in,
    after_layout_label::in, io::di, io::uo) is det.

    % Output an instruction and (if the third arg is yes) the comment.
    % This predicate is provided for debugging use only.
    %
:- pred output_debug_instruction_and_comment(llds_out_info::in,
    instr::in, string::in, io::di, io::uo) is det.

    % Output an instruction.
    % This predicate is provided for debugging use only.
    %
:- pred output_debug_instruction(llds_out_info::in, instr::in,
    io::di, io::uo) is det.

%----------------------------------------------------------------------------%
%----------------------------------------------------------------------------%

:- implementation.

:- import_module backend_libs.c_util.
:- import_module backend_libs.export.
:- import_module backend_libs.name_mangle.
:- import_module check_hlds.type_util.
:- import_module hlds.hlds_data.
:- import_module hlds.hlds_pred.
:- import_module ll_backend.layout.
:- import_module ll_backend.layout_out.
:- import_module ll_backend.llds_out.llds_out_code_addr.
:- import_module ll_backend.llds_out.llds_out_data.
:- import_module ll_backend.pragma_c_gen.
:- import_module mdbcomp.prim_data.
:- import_module parse_tree.mercury_to_mercury.
:- import_module parse_tree.prog_data.
:- import_module parse_tree.prog_type.

:- import_module assoc_list.
:- import_module bool.
:- import_module char.
:- import_module int.
:- import_module map.
:- import_module maybe.
:- import_module require.
:- import_module set.
:- import_module string.
:- import_module term.
:- import_module varset.

%----------------------------------------------------------------------------%
%
% Declare the things inside instructions that need to be declared.
%

output_record_instruction_decls(Info, Instr, !DeclSet, !IO) :-
    Instr = llds_instr(Uinstr, _),
    output_record_instr_decls(Info, Uinstr, !DeclSet, !IO).

:- pred output_record_instr_decls(llds_out_info::in, instr::in,
    decl_set::in, decl_set::out, io::di, io::uo) is det.

output_record_instr_decls(Info, Instr, !DeclSet, !IO) :-
    (
        ( Instr = comment(_)
        ; Instr = livevals(_)
        ; Instr = arbitrary_c_code(_, _, _)
        ; Instr = label(_)
        ; Instr = push_region_frame(_, _)
        ; Instr = use_and_maybe_pop_region_frame(_, _)
        ; Instr = discard_ticket
        ; Instr = prune_ticket
        ; Instr = incr_sp(_, _, _)
        ; Instr = decr_sp(_)
        ; Instr = decr_sp_and_return(_)
        )
    ;
        Instr = block(_TempR, _TempF, Instrs),
        list.foldl2(output_record_instruction_decls(Info), Instrs,
            !DeclSet, !IO)
    ;
        Instr = assign(Lval, Rval),
        output_record_lval_decls(Info, Lval, !DeclSet, !IO),
        output_record_rval_decls(Info, Rval, !DeclSet, !IO)
    ;
        Instr = keep_assign(Lval, Rval),
        output_record_lval_decls(Info, Lval, !DeclSet, !IO),
        output_record_rval_decls(Info, Rval, !DeclSet, !IO)
    ;
        Instr = llcall(Target, ContLabel, _, _, _, _),
        output_record_code_addr_decls(Info, Target, !DeclSet, !IO),
        output_record_code_addr_decls(Info, ContLabel, !DeclSet, !IO)
    ;
        Instr = mkframe(FrameInfo, MaybeFailureContinuation),
        (
            FrameInfo = ordinary_frame(_, _, yes(Struct)),
            Struct = foreign_proc_struct(StructName, StructFields,
                MaybeStructFieldsContext)
        ->
            DeclId = decl_foreign_proc_struct(StructName),
            ( decl_set_is_member(DeclId, !.DeclSet) ->
                Msg = "struct " ++ StructName ++ " has been declared already",
                unexpected(this_file, Msg)
            ;
                true
            ),
            io.write_string("struct ", !IO),
            io.write_string(StructName, !IO),
            io.write_string(" {\n", !IO),
            (
                MaybeStructFieldsContext = yes(StructFieldsContext),
                output_set_line_num(Info, StructFieldsContext, !IO),
                io.write_string(StructFields, !IO),
                output_reset_line_num(Info, !IO)
            ;
                MaybeStructFieldsContext = no,
                io.write_string(StructFields, !IO)
            ),
            io.write_string("\n};\n", !IO),
            decl_set_insert(DeclId, !DeclSet)
        ;
            true
        ),
        (
            MaybeFailureContinuation = yes(FailureContinuation),
            output_record_code_addr_decls(Info, FailureContinuation,
                !DeclSet, !IO)
        ;
            MaybeFailureContinuation = no
        )
    ;
        Instr = goto(CodeAddr),
        output_record_code_addr_decls(Info, CodeAddr, !DeclSet, !IO)
    ;
        Instr = computed_goto(Rval, _MaybeLabels),
        output_record_rval_decls(Info, Rval, !DeclSet, !IO)
    ;
        Instr = if_val(Rval, Target),
        output_record_rval_decls(Info, Rval, !DeclSet, !IO),
        output_record_code_addr_decls(Info, Target, !DeclSet, !IO)
    ;
        Instr = save_maxfr(Lval),
        output_record_lval_decls(Info, Lval, !DeclSet, !IO)
    ;
        Instr = restore_maxfr(Lval),
        output_record_lval_decls(Info, Lval, !DeclSet, !IO)
    ;
        Instr = incr_hp(Lval, _Tag, _, Rval, _, _, MaybeRegionRval,
            MaybeReuse),
        output_record_lval_decls(Info, Lval, !DeclSet, !IO),
        output_record_rval_decls(Info, Rval, !DeclSet, !IO),
        (
            MaybeRegionRval = yes(RegionRval),
            output_record_rval_decls(Info, RegionRval, !DeclSet, !IO)
        ;
            MaybeRegionRval = no
        ),
        (
            MaybeReuse = llds_reuse(ReuseRval, MaybeFlagLval),
            output_record_rval_decls(Info, ReuseRval, !DeclSet, !IO),
            (
                MaybeFlagLval = yes(FlagLval),
                output_record_lval_decls(Info, FlagLval, !DeclSet, !IO)
            ;
                MaybeFlagLval = no
            )
        ;
            MaybeReuse = no_llds_reuse
        )
    ;
        ( Instr = mark_hp(Lval)
        ; Instr = store_ticket(Lval)
        ; Instr = mark_ticket_stack(Lval)
        ; Instr = init_sync_term(Lval, _NumBranches, _ConjIdSlotNum)
        ),
        output_record_lval_decls(Info, Lval, !DeclSet, !IO)
    ;
        ( Instr = restore_hp(Rval)
        ; Instr = free_heap(Rval)
        ; Instr = prune_tickets_to(Rval)
        ; Instr = reset_ticket(Rval, _Reason)
        ),
        output_record_rval_decls(Info, Rval, !DeclSet, !IO)
    ;
        Instr = region_fill_frame(_FillOp, _EmbeddedFrame, IdRval,
            NumLval, AddrLval),
        output_record_rval_decls(Info, IdRval, !DeclSet, !IO),
        output_record_lval_decls(Info, NumLval, !DeclSet, !IO),
        output_record_lval_decls(Info, AddrLval, !DeclSet, !IO)
    ;
        Instr = region_set_fixed_slot(_SetOp, _EmbeddedFrame, ValueRval),
        output_record_rval_decls(Info, ValueRval, !DeclSet, !IO)
    ;
        Instr = foreign_proc_code(_, Comps, _, _, _, _, _, _, _, _),
        list.foldl2(output_record_foreign_proc_component_decls(Info), Comps,
            !DeclSet, !IO)
    ;
        Instr = fork_new_child(Lval, Child),
        output_record_lval_decls(Info, Lval, !DeclSet, !IO),
        output_record_code_addr_decls(Info, code_label(Child), !DeclSet, !IO)
    ;
        Instr = join_and_continue(Lval, Label),
        output_record_lval_decls(Info, Lval, !DeclSet, !IO),
        output_record_code_addr_decls(Info, code_label(Label), !DeclSet, !IO)
    ).

:- pred output_record_foreign_proc_component_decls(llds_out_info::in,
    foreign_proc_component::in, decl_set::in, decl_set::out,
    io::di, io::uo) is det.

output_record_foreign_proc_component_decls(Info, Component, !DeclSet, !IO) :-
    (
        Component = foreign_proc_inputs(Inputs),
        output_record_foreign_proc_input_rval_decls(Info, Inputs,
            !DeclSet, !IO)
    ;
        Component = foreign_proc_outputs(Outputs),
        output_record_foreign_proc_output_lval_decls(Info, Outputs,
            !DeclSet, !IO)
    ;
        ( Component = foreign_proc_raw_code(_, _, _, _)
        ; Component = foreign_proc_user_code(_, _, _)
        ; Component = foreign_proc_fail_to(_)
        ; Component = foreign_proc_noop
        )
    ).

%----------------------------------------------------------------------------%
%
% Output a list of instructions.
%

output_instruction_list(_, [], _, _, _, !IO).
output_instruction_list(Info, [Instr | Instrs], ProfInfo, WhileSet,
        AfterLayoutLabel0, !IO) :-
    Instr = llds_instr(Uinstr, Comment),
    ( Uinstr = label(Label) ->
        InternalLabelToLayoutMap = Info ^ lout_internal_label_to_layout,
        ( map.search(InternalLabelToLayoutMap, Label, _) ->
            AfterLayoutLabel = after_layout_label
        ;
            AfterLayoutLabel = not_after_layout_label
        ),
        (
            AfterLayoutLabel0 = after_layout_label,
            AfterLayoutLabel = after_layout_label
        ->
            % Make sure that the addresses of the two labels are distinct.
            io.write_string("\tMR_dummy_function_call();\n", !IO)
        ;
            true
        ),
        output_instruction_and_comment(Info, Uinstr, Comment, ProfInfo, !IO),
        ( set_tree234.contains(WhileSet, Label) ->
            io.write_string("\twhile (1) {\n", !IO),
            output_instruction_list_while(Info, Instrs, Label, ProfInfo,
                WhileSet, !IO)
            % The matching close brace is printed in output_instruction_list
            % when before the next label, before a goto that closes the loop,
            % or when we get to the end of Instrs.
        ;
            output_instruction_list(Info, Instrs, ProfInfo, WhileSet,
                AfterLayoutLabel, !IO)
        )
    ;
        output_instruction_and_comment(Info, Uinstr, Comment,
            ProfInfo, !IO),
        ( Uinstr = comment(_) ->
            AfterLayoutLabel = AfterLayoutLabel0
        ;
            AfterLayoutLabel = not_after_layout_label
        ),
        output_instruction_list(Info, Instrs, ProfInfo, WhileSet,
            AfterLayoutLabel, !IO)
    ).

:- pred output_instruction_list_while(llds_out_info::in,
    list(instruction)::in, label::in, pair(label,
    set_tree234(label))::in, set_tree234(label)::in, io::di, io::uo) is det.

output_instruction_list_while(_, [], _, _, _, !IO) :-
    io.write_string("\tbreak; } /* end while */\n", !IO).
output_instruction_list_while(Info, [Instr | Instrs], Label, ProfInfo,
        WhileSet, !IO) :-
    Instr = llds_instr(Uinstr, Comment),
    ( Uinstr = label(_) ->
        io.write_string("\tbreak; } /* end while */\n", !IO),
        output_instruction_list(Info, [Instr | Instrs],
            ProfInfo, WhileSet, not_after_layout_label, !IO)
    ; Uinstr = goto(code_label(Label)) ->
        io.write_string("\t/* continue */ } /* end while */\n", !IO),
        output_instruction_list(Info, Instrs, ProfInfo, WhileSet,
            not_after_layout_label, !IO)
    ; Uinstr = if_val(Rval, code_label(Label)) ->
        io.write_string("\tif (", !IO),
        output_test_rval(Info, Rval, !IO),
        io.write_string(")\n\t\tcontinue;\n", !IO),
        AutoComments = Info ^ lout_auto_comments,
        (
            AutoComments = yes,
            Comment \= ""
        ->
            io.write_string("\t\t/* ", !IO),
            io.write_string(Comment, !IO),
            io.write_string(" */\n", !IO)
        ;
            true
        ),
        output_instruction_list_while(Info, Instrs, Label, ProfInfo,
            WhileSet, !IO)
    ; Uinstr = block(TempR, TempF, BlockInstrs) ->
        output_block_start(TempR, TempF, !IO),
        output_instruction_list_while_block(Info, BlockInstrs, Label,
            ProfInfo, !IO),
        output_block_end(!IO),
        output_instruction_list_while(Info, Instrs, Label, ProfInfo,
            WhileSet, !IO)
    ;
        output_instruction_and_comment(Info, Uinstr, Comment, ProfInfo, !IO),
        output_instruction_list_while(Info, Instrs, Label, ProfInfo,
            WhileSet, !IO)
    ).

:- pred output_instruction_list_while_block(llds_out_info::in,
    list(instruction)::in, label::in, pair(label, set_tree234(label))::in,
    io::di, io::uo) is det.

output_instruction_list_while_block(_, [], _, _, !IO).
output_instruction_list_while_block(Info, [Instr | Instrs], Label, ProfInfo,
        !IO) :-
    Instr = llds_instr(Uinstr, Comment),
    ( Uinstr = label(_) ->
        unexpected(this_file, "label in block")
    ; Uinstr = goto(code_label(Label)) ->
        io.write_string("\tcontinue;\n", !IO),
        expect(unify(Instrs, []), this_file,
            "output_instruction_list_while_block: code after goto")
    ; Uinstr = if_val(Rval, code_label(Label)) ->
        io.write_string("\tif (", !IO),
        output_test_rval(Info, Rval, !IO),
        io.write_string(")\n\t\tcontinue;\n", !IO),
        AutoComments = Info ^ lout_auto_comments,
        (
            AutoComments = yes,
            Comment \= ""
        ->
            io.write_string("\t\t/* ", !IO),
            io.write_string(Comment, !IO),
            io.write_string(" */\n", !IO)
        ;
            true
        ),
        output_instruction_list_while_block(Info, Instrs, Label,
            ProfInfo, !IO)
    ; Uinstr = block(_, _, _) ->
        unexpected(this_file, "block in block")
    ;
        output_instruction_and_comment(Info, Uinstr, Comment, ProfInfo, !IO),
        output_instruction_list_while_block(Info, Instrs, Label,
            ProfInfo, !IO)
    ).

%----------------------------------------------------------------------------%
%
% Output an instruction for debugging.
%

    % output_debug_instruction_and_comment/5 is only for debugging.
    % Normally we use output_instruction_and_comment/6.
    %
output_debug_instruction_and_comment(Info, Instr, Comment, !IO) :-
    ContLabelSet = set_tree234.init,
    DummyModule = unqualified("DEBUG"),
    DummyPredName = "DEBUG",
    proc_id_to_int(hlds_pred.initial_proc_id, InitialProcIdInt),
    ProcLabel = ordinary_proc_label(DummyModule, pf_predicate, DummyModule,
        DummyPredName, 0, InitialProcIdInt),
    ProfInfo = entry_label(entry_label_local, ProcLabel) - ContLabelSet,
    output_instruction_and_comment(Info, Instr, Comment, ProfInfo, !IO).

    % output_debug_instruction/3 is only for debugging.
    % Normally we use output_instruction/4.
    %
output_debug_instruction(Info, Instr, !IO) :-
    ContLabelSet = set_tree234.init,
    DummyModule = unqualified("DEBUG"),
    DummyPredName = "DEBUG",
    proc_id_to_int(hlds_pred.initial_proc_id, InitialProcIdInt),
    ProcLabel = ordinary_proc_label(DummyModule, pf_predicate, DummyModule,
        DummyPredName, 0, InitialProcIdInt),
    ProfInfo = entry_label(entry_label_local, ProcLabel) - ContLabelSet,
    output_instruction(Info, Instr, ProfInfo, !IO).

%----------------------------------------------------------------------------%
%
% Output an instruction and a comment.
%

:- pred output_instruction_and_comment(llds_out_info::in, instr::in,
    string::in, pair(label, set_tree234(label))::in, io::di, io::uo) is det.

output_instruction_and_comment(Info, Instr, Comment, ProfInfo, !IO) :-
    AutoComments = Info ^ lout_auto_comments,
    (
        AutoComments = no,
        (
            ( Instr = comment(_)
            ; Instr = livevals(_)
            )
        ->
            true
        ;
            output_instruction(Info, Instr, ProfInfo, !IO)
        )
    ;
        AutoComments = yes,
        output_instruction(Info, Instr, ProfInfo, !IO),
        ( Comment = "" ->
            true
        ;
            io.write_string("\t\t/* ", !IO),
            io.write_string(Comment, !IO),
            io.write_string(" */\n", !IO)
        )
    ).

%----------------------------------------------------------------------------%
%
% Output a single instruction.
%

:- pred output_instruction(llds_out_info::in, instr::in,
    pair(label, set_tree234(label))::in, io::di, io::uo) is det.

output_instruction(Info, Instr, ProfInfo, !IO) :-
    (
        Instr = comment(Comment),
        % Ensure that any comments embedded inside Comment are made safe, i.e.
        % prevent the closing of embedded comments from closing the outer
        % comment. The fact that the code here is not very efficient doesn't
        % matter since we write out comments only with --auto-comments,
        % which we enable only when we want to debug the generated C code.
        io.write_string("/*", !IO),
        string.to_char_list(Comment, CommentChars),
        output_comment_chars('*', CommentChars, !IO),
        io.write_string("*/\n", !IO)
    ;
        Instr = livevals(LiveVals),
        io.write_string("/*\n* Live lvalues:\n", !IO),
        set.to_sorted_list(LiveVals, LiveValsList),
        output_livevals(Info, LiveValsList, !IO),
        io.write_string("*/\n", !IO)
    ;
        Instr = block(TempR, TempF, Instrs),
        output_block_start(TempR, TempF, !IO),
        output_instruction_list(Info, Instrs, ProfInfo, set_tree234.init,
            not_after_layout_label, !IO),
        output_block_end(!IO)
    ;
        Instr = assign(Lval, Rval),
        io.write_string("\t", !IO),
        output_lval_for_assign(Info, Lval, Type, !IO),
        io.write_string(" = ", !IO),
        output_rval_as_type(Info, Rval, Type, !IO),
        io.write_string(";\n", !IO)
    ;
        Instr = keep_assign(Lval, Rval),
        io.write_string("\t", !IO),
        output_lval_for_assign(Info, Lval, Type, !IO),
        io.write_string(" = ", !IO),
        output_rval_as_type(Info, Rval, Type, !IO),
        io.write_string(";\n", !IO)
    ;
        Instr = llcall(Target, ContLabel, LiveVals, _, _, _),
        ProfInfo = CallerLabel - _,
        output_call(Info, Target, ContLabel, CallerLabel, !IO),
        output_gc_livevals(Info, LiveVals, !IO)
    ;
        Instr = arbitrary_c_code(_, _, C_Code),
        io.write_string("\t", !IO),
        io.write_string(C_Code, !IO)
    ;
        Instr = mkframe(FrameInfo, MaybeFailCont),
        (
            FrameInfo = ordinary_frame(Msg, Num, MaybeStruct),
            (
                MaybeStruct = yes(foreign_proc_struct(StructName, _, _)),
                (
                    MaybeFailCont = yes(FailCont),
                    io.write_string("\tMR_mkpragmaframe(""", !IO),
                    c_util.output_quoted_string(Msg, !IO),
                    io.write_string(""", ", !IO),
                    io.write_int(Num, !IO),
                    io.write_string(",\n\t\t", !IO),
                    io.write_string(StructName, !IO),
                    io.write_string(", ", !IO),
                    output_code_addr(FailCont, !IO),
                    io.write_string(");\n", !IO)
                ;
                    MaybeFailCont = no,
                    io.write_string("\tMR_mkpragmaframe_no_redoip(""", !IO),
                    c_util.output_quoted_string(Msg, !IO),
                    io.write_string(""", ", !IO),
                    io.write_int(Num, !IO),
                    io.write_string(",\n\t\t", !IO),
                    io.write_string(StructName, !IO),
                    io.write_string(");\n", !IO)
                )
            ;
                MaybeStruct = no,
                (
                    MaybeFailCont = yes(FailCont),
                    io.write_string("\tMR_mkframe(""", !IO),
                    c_util.output_quoted_string(Msg, !IO),
                    io.write_string(""", ", !IO),
                    io.write_int(Num, !IO),
                    io.write_string(",\n\t\t", !IO),
                    output_code_addr(FailCont, !IO),
                    io.write_string(");\n", !IO)
                ;
                    MaybeFailCont = no,
                    io.write_string("\tMR_mkframe_no_redoip(""",
                        !IO),
                    c_util.output_quoted_string(Msg, !IO),
                    io.write_string(""", ", !IO),
                    io.write_int(Num, !IO),
                    io.write_string(");\n", !IO)
                )
            )
        ;
            FrameInfo = temp_frame(Kind),
            (
                Kind = det_stack_proc,
                io.write_string("\tMR_mkdettempframe(", !IO),
                (
                    MaybeFailCont = yes(FailCont),
                    output_code_addr(FailCont, !IO)
                ;
                    MaybeFailCont = no,
                    unexpected(this_file, "output_instruction: no failcont")
                ),
                io.write_string(");\n", !IO)
            ;
                Kind = nondet_stack_proc,
                io.write_string("\tMR_mktempframe(", !IO),
                (
                    MaybeFailCont = yes(FailCont),
                    output_code_addr(FailCont, !IO)
                ;
                    MaybeFailCont = no,
                    unexpected(this_file, "output_instruction: no failcont")
                ),
                io.write_string(");\n", !IO)
            )
        )
    ;
        Instr = label(Label),
        output_label_defn(Label, !IO),
        LocalThreadEngineBase = Info ^ lout_local_thread_engine_base,
        (
            LocalThreadEngineBase = yes,
            io.write_string("\tMR_MAYBE_INIT_LOCAL_THREAD_ENGINE_BASE\n", !IO)
        ;
            LocalThreadEngineBase = no
        ),
        maybe_output_update_prof_counter(Info, Label, ProfInfo, !IO)
    ;
        Instr = goto(CodeAddr),
        ProfInfo = CallerLabel - _,
        io.write_string("\t", !IO),
        output_goto(Info, CodeAddr, CallerLabel, !IO)
    ;
        Instr = computed_goto(Rval, MaybeLabels),
        io.write_string("\tMR_COMPUTED_GOTO(", !IO),
        output_rval_as_type(Info, Rval, lt_unsigned, !IO),
        io.write_string(",\n\t\t", !IO),
        output_label_list_or_not_reached(MaybeLabels, !IO),
        io.write_string(");\n", !IO)
    ;
        Instr = if_val(Rval, Target),
        ProfInfo = CallerLabel - _,
        io.write_string("\tif (", !IO),
        output_test_rval(Info, Rval, !IO),
        io.write_string(") {\n\t\t", !IO),
        output_goto(Info, Target, CallerLabel, !IO),
        io.write_string("\t}\n", !IO)
    ;
        Instr = save_maxfr(Lval),
        io.write_string("\tMR_save_maxfr(", !IO),
        output_lval(Info, Lval, !IO),
        io.write_string(");\n", !IO)
    ;
        Instr = restore_maxfr(Lval),
        io.write_string("\tMR_restore_maxfr(", !IO),
        output_lval(Info, Lval, !IO),
        io.write_string(");\n", !IO)
    ;
        Instr = incr_hp(Lval, MaybeTag, MaybeOffset, SizeRval, TypeMsg,
            MayUseAtomicAlloc, MaybeRegionRval, MaybeReuse),
        io.write_string("\t", !IO),
        (
            MaybeReuse = no_llds_reuse,
            output_incr_hp_no_reuse(Info, Lval, MaybeTag, MaybeOffset,
                SizeRval, TypeMsg, MayUseAtomicAlloc, MaybeRegionRval,
                ProfInfo, !IO)
        ;
            MaybeReuse = llds_reuse(ReuseRval, MaybeFlagLval),
            (
                MaybeTag = no,
                (
                    MaybeFlagLval = yes(FlagLval),
                    io.write_string("MR_reuse_or_alloc_heap_flag(", !IO),
                    output_lval_as_word(Info, Lval, !IO),
                    io.write_string(", ", !IO),
                    output_lval_as_word(Info, FlagLval, !IO)
                ;
                    MaybeFlagLval = no,
                    io.write_string("MR_reuse_or_alloc_heap(", !IO),
                    output_lval_as_word(Info, Lval, !IO)
                )
            ;
                MaybeTag = yes(Tag),
                (
                    MaybeFlagLval = yes(FlagLval),
                    io.write_string("MR_tag_reuse_or_alloc_heap_flag(", !IO),
                    output_lval_as_word(Info, Lval, !IO),
                    io.write_string(", ", !IO),
                    output_tag(Tag, !IO),
                    io.write_string(", ", !IO),
                    output_lval_as_word(Info, FlagLval, !IO)
                ;
                    MaybeFlagLval = no,
                    io.write_string("MR_tag_reuse_or_alloc_heap(", !IO),
                    output_lval_as_word(Info, Lval, !IO),
                    io.write_string(", ", !IO),
                    output_tag(Tag, !IO)
                )
            ),
            io.write_string(", ", !IO),
            output_rval(Info, ReuseRval, !IO),
            io.write_string(", ", !IO),
            output_incr_hp_no_reuse(Info, Lval, MaybeTag, MaybeOffset,
                SizeRval, TypeMsg, MayUseAtomicAlloc, MaybeRegionRval,
                ProfInfo, !IO),
            io.write_string(")", !IO)
        ),
        io.write_string(";\n", !IO)
    ;
        Instr = mark_hp(Lval),
        io.write_string("\tMR_mark_hp(", !IO),
        output_lval_as_word(Info, Lval, !IO),
        io.write_string(");\n", !IO)
    ;
        Instr = restore_hp(Rval),
        io.write_string("\tMR_restore_hp(", !IO),
        output_rval_as_type(Info, Rval, lt_word, !IO),
        io.write_string(");\n", !IO)
    ;
        Instr = free_heap(Rval),
        io.write_string("\tMR_free_heap(", !IO),
        output_rval_as_type(Info, Rval, lt_data_ptr, !IO),
        io.write_string(");\n", !IO)
    ;
        Instr = push_region_frame(StackId, EmbeddedFrame),
        (
            StackId = region_stack_ite,
            io.write_string("\tMR_push_region_ite_frame", !IO)
        ;
            StackId = region_stack_disj,
            io.write_string("\tMR_push_region_disj_frame", !IO)
        ;
            StackId = region_stack_commit,
            io.write_string("\tMR_push_region_commit_frame", !IO)
        ),
        io.write_string("(", !IO),
        output_embedded_frame_addr(Info, EmbeddedFrame, !IO),
        io.write_string(");", !IO),

        % The comment is to make the code easier to debug;
        % we can stop printing it out once that has been done.
        EmbeddedFrame = embedded_stack_frame_id(_StackId,
            FirstSlot, LastSlot),
        Comment = " /* " ++ int_to_string(FirstSlot) ++ ".." ++
            int_to_string(LastSlot) ++ " */",
        io.write_string(Comment, !IO),

        io.write_string("\n", !IO)
    ;
        Instr = region_fill_frame(FillOp, EmbeddedFrame, IdRval,
            NumLval, AddrLval),
        (
            FillOp = region_fill_ite_protect,
            io.write_string("\tMR_region_fill_ite_protect", !IO)
        ;
            FillOp = region_fill_ite_snapshot(removed_at_start_of_else),
            io.write_string("\tMR_region_fill_ite_snapshot_removed", !IO)
        ;
            FillOp = region_fill_ite_snapshot(not_removed_at_start_of_else),
            io.write_string("\tMR_region_fill_ite_snapshot_not_removed", !IO)
        ;
            FillOp = region_fill_semi_disj_protect,
            io.write_string("\tMR_region_fill_semi_disj_protect", !IO)
        ;
            FillOp = region_fill_disj_snapshot,
            io.write_string("\tMR_region_fill_disj_snapshot", !IO)
        ;
            FillOp = region_fill_commit,
            io.write_string("\tMR_region_fill_commit", !IO)
        ),
        io.write_string("(", !IO),
        output_embedded_frame_addr(Info, EmbeddedFrame, !IO),
        io.write_string(", ", !IO),
        output_rval(Info, IdRval, !IO),
        io.write_string(", ", !IO),
        output_lval(Info, NumLval, !IO),
        io.write_string(", ", !IO),
        output_lval(Info, AddrLval, !IO),
        io.write_string(");\n", !IO)
    ;
        Instr = region_set_fixed_slot(SetOp, EmbeddedFrame, ValueRval),
        (
            SetOp = region_set_ite_num_protects,
            io.write_string("\tMR_region_set_ite_num_protects", !IO)
        ;
            SetOp = region_set_ite_num_snapshots,
            io.write_string("\tMR_region_set_ite_num_snapshots", !IO)
        ;
            SetOp = region_set_disj_num_protects,
            io.write_string("\tMR_region_set_disj_num_protects", !IO)
        ;
            SetOp = region_set_disj_num_snapshots,
            io.write_string("\tMR_region_set_disj_num_snapshots", !IO)
        ;
            SetOp = region_set_commit_num_entries,
            io.write_string("\tMR_region_set_commit_num_entries", !IO)
        ),
        io.write_string("(", !IO),
        output_embedded_frame_addr(Info, EmbeddedFrame, !IO),
        io.write_string(", ", !IO),
        output_rval(Info, ValueRval, !IO),
        io.write_string(");\n", !IO)
    ;
        Instr = use_and_maybe_pop_region_frame(UseOp, EmbeddedFrame),
        (
            UseOp = region_ite_then(region_ite_semidet_cond),
            io.write_string("\tMR_use_region_ite_then_semidet", !IO)
        ;
            UseOp = region_ite_then(region_ite_nondet_cond),
            io.write_string("\tMR_use_region_ite_then_nondet", !IO)
        ;
            UseOp = region_ite_else(region_ite_semidet_cond),
            io.write_string("\tMR_use_region_ite_else_semidet", !IO)
        ;
            UseOp = region_ite_else(region_ite_nondet_cond),
            io.write_string("\tMR_use_region_ite_else_nondet", !IO)
        ;
            UseOp = region_ite_nondet_cond_fail,
            io.write_string("\tMR_use_region_ite_nondet_cond_fail", !IO)
        ;
            UseOp = region_disj_later,
            io.write_string("\tMR_use_region_disj_later", !IO)
        ;
            UseOp = region_disj_last,
            io.write_string("\tMR_use_region_disj_last", !IO)
        ;
            UseOp = region_disj_nonlast_semi_commit,
            io.write_string("\tMR_use_region_disj_nonlast_semi_commit", !IO)
        ;
            UseOp = region_commit_success,
            io.write_string("\tMR_use_region_commit_success", !IO)
        ;
            UseOp = region_commit_failure,
            io.write_string("\tMR_use_region_commit_failure", !IO)
        ),
        io.write_string("(", !IO),
        output_embedded_frame_addr(Info, EmbeddedFrame, !IO),
        io.write_string(");\n", !IO)
    ;
        Instr = store_ticket(Lval),
        io.write_string("\tMR_store_ticket(", !IO),
        output_lval_as_word(Info, Lval, !IO),
        io.write_string(");\n", !IO)
    ;
        Instr = reset_ticket(Rval, Reason),
        io.write_string("\tMR_reset_ticket(", !IO),
        output_rval_as_type(Info, Rval, lt_word, !IO),
        io.write_string(", ", !IO),
        output_reset_trail_reason(Reason, !IO),
        io.write_string(");\n", !IO)
    ;
        Instr = discard_ticket,
        io.write_string("\tMR_discard_ticket();\n", !IO)
    ;
        Instr = prune_ticket,
        io.write_string("\tMR_prune_ticket();\n", !IO)
    ;
        Instr = mark_ticket_stack(Lval),
        io.write_string("\tMR_mark_ticket_stack(", !IO),
        output_lval_as_word(Info, Lval, !IO),
        io.write_string(");\n", !IO)
    ;
        Instr = prune_tickets_to(Rval),
        io.write_string("\tMR_prune_tickets_to(", !IO),
        output_rval_as_type(Info, Rval, lt_word, !IO),
        io.write_string(");\n", !IO)
    ;
        Instr = incr_sp(N, _Msg, Kind),
        (
            Kind = stack_incr_leaf,
            ( N < max_leaf_stack_frame_size ->
                io.write_string("\tMR_incr_sp_leaf(", !IO)
            ;
                io.write_string("\tMR_incr_sp(", !IO)
            )
        ;
            Kind = stack_incr_nonleaf,
            io.write_string("\tMR_incr_sp(", !IO)
        ),
        io.write_int(N, !IO),
        io.write_string(");\n", !IO)
        % Use the code below instead of the code above if you want to run
        % tools/framesize on the output of the compiler.
        % io.write_string("\tMR_incr_sp_push_msg(", !IO),
        % io.write_int(N, !IO),
        % io.write_string(", """, !IO),
        % c_util.output_quoted_string(Msg, !IO),
        % io.write_string(""");\n", !IO)
    ;
        Instr = decr_sp(N),
        io.write_string("\tMR_decr_sp(", !IO),
        io.write_int(N, !IO),
        io.write_string(");\n", !IO)
    ;
        Instr = decr_sp_and_return(N),
        io.write_string("\tMR_decr_sp_and_return(", !IO),
        io.write_int(N, !IO),
        io.write_string(");\n", !IO)
    ;
        Instr = foreign_proc_code(Decls, Components, _, _, _, _, _,
            MaybeDefLabel, _, _),
        io.write_string("\t{\n", !IO),
        output_foreign_proc_decls(Decls, !IO),
        (
            MaybeDefLabel = no,
            list.foldl(output_foreign_proc_component(Info), Components, !IO)
        ;
            MaybeDefLabel = yes(DefLabel),
            InternalLabelToLayoutMap = Info ^ lout_internal_label_to_layout,
            map.lookup(InternalLabelToLayoutMap, DefLabel, DefLabelLayout),
            io.write_string("#define MR_HASH_DEF_LABEL_LAYOUT ", !IO),
            MangledModuleName = Info ^ lout_mangled_module_name,
            output_layout_slot_addr(use_layout_macro, MangledModuleName,
                DefLabelLayout, !IO),
            io.nl(!IO),
            list.foldl(output_foreign_proc_component(Info), Components, !IO),
            io.write_string("#undef MR_HASH_DEF_LABEL_LAYOUT\n", !IO)
        ),
        io.write_string("\t}\n", !IO)
    ;
        Instr = init_sync_term(Lval, NumConjuncts, TSStringIndex),
        io.write_string("\tMR_init_sync_term(", !IO),
        output_lval_as_word(Info, Lval, !IO),
        io.write_string(", ", !IO),
        io.write_int(NumConjuncts, !IO),
        io.write_string(", ", !IO),
        io.write_int(TSStringIndex, !IO),
        io.write_string(");\n", !IO)
    ;
        Instr = fork_new_child(Lval, Child),
        io.write_string("\tMR_fork_new_child(", !IO),
        output_lval_as_word(Info, Lval, !IO),
        io.write_string(", ", !IO),
        output_label_as_code_addr(Child, !IO),
        io.write_string(");\n", !IO)
    ;
        Instr = join_and_continue(Lval, Label),
        io.write_string("\tMR_join_and_continue(", !IO),
        output_lval(Info, Lval, !IO),
        io.write_string(", ", !IO),
        output_label_as_code_addr(Label, !IO),
        io.write_string(");\n", !IO)
    ).

%----------------------------------------------------------------------------%
%
% Code for the output of a comment instruction.
%

:- pred output_comment_chars(char::in, list(char)::in, io::di, io::uo) is det.

output_comment_chars(_PrevChar, [], !IO).
output_comment_chars(PrevChar, [Char | Chars], !IO) :-
    (
        PrevChar = ('/'),
        Char = ('*')
    ->
        io.write_string(" *", !IO)
    ;
        PrevChar = ('*'),
        Char = ('/')
    ->
        io.write_string(" /", !IO)
    ;
        io.write_char(Char, !IO)
    ),
    output_comment_chars(Char, Chars, !IO).

%----------------------------------------------------------------------------%
%
% Code for the output of a livevals instruction.
%

:- pred output_livevals(llds_out_info::in, list(lval)::in,
    io::di, io::uo) is det.

output_livevals(_, [], !IO).
output_livevals(Info, [Lval | Lvals], !IO) :-
    io.write_string("*\t", !IO),
    output_lval(Info, Lval, !IO),
    io.write_string("\n", !IO),
    output_livevals(Info, Lvals, !IO).

%----------------------------------------------------------------------------%
%
% Code for the output of a block instruction.
%

:- pred output_block_start(int::in, int::in, io::di, io::uo) is det.

output_block_start(TempR, TempF, !IO) :-
    io.write_string("\t{\n", !IO),
    ( TempR > 0 ->
        io.write_string("\tMR_Word ", !IO),
        output_temp_decls(TempR, "r", !IO),
        io.write_string(";\n", !IO)
    ;
        true
    ),
    ( TempF > 0 ->
        io.write_string("\tMR_Float ", !IO),
        output_temp_decls(TempF, "f", !IO),
        io.write_string(";\n", !IO)
    ;
        true
    ).

:- pred output_block_end(io::di, io::uo) is det.

output_block_end(!IO) :-
    io.write_string("\t}\n", !IO).

:- pred output_temp_decls(int::in, string::in, io::di, io::uo) is det.

output_temp_decls(N, Type, !IO) :-
    output_temp_decls_2(1, N, Type, !IO).

:- pred output_temp_decls_2(int::in, int::in, string::in, io::di, io::uo)
    is det.

output_temp_decls_2(Next, Max, Type, !IO) :-
    ( Next =< Max ->
        ( Next > 1 ->
            io.write_string(", ", !IO)
        ;
            true
        ),
        io.write_string("MR_temp", !IO),
        io.write_string(Type, !IO),
        io.write_int(Next, !IO),
        output_temp_decls_2(Next + 1, Max, Type, !IO)
    ;
        true
    ).

%----------------------------------------------------------------------------%
%
% Code for the output of a call instruction.
%

    % Note that we also do some optimization here by outputting `localcall'
    % rather than `call' for calls to local labels, or `call_localret' for
    % calls which return to local labels (i.e. most of them).
    %
    % We also reduce the size of the output by emitting shorthand forms of
    % the relevant macros when possible, allowing those shorthand macros
    % to apply mercury__ prefixes and possible MR_ENTRY() wrappers.
    %
:- pred output_call(llds_out_info::in, code_addr::in, code_addr::in,
    label::in, io::di, io::uo) is det.

output_call(Info, Target, Continuation, CallerLabel, !IO) :-
    io.write_string("\t", !IO),
    % For profiling, we ignore calls to do_call_closure and
    % do_call_class_method, because in general they lead to cycles in the call
    % graph that screw up the profile. By generating a `noprof_call' rather
    % than a `call', we ensure that time spent inside those routines
    % is credited to the caller, rather than to do_call_closure or
    % do_call_class_method itself. But if we do use a noprof_call,
    % we need to set MR_prof_ho_caller_proc, so that the callee knows
    % which proc it has been called from.
    (
        ( Target = do_call_closure(_)
        ; Target = do_call_class_method(_)
        )
    ->
        ProfileCall = no,
        io.write_string("MR_set_prof_ho_caller_proc(", !IO),
        output_label_as_code_addr(CallerLabel, !IO),
        io.write_string(");\n\t", !IO)
    ;
        ProfileCall = Info ^ lout_profile_calls
    ),
    (
        Target = code_label(Label),
        % We really shouldn't be calling internal labels ...
        label_is_external_to_c_module(Label) = no
    ->
        (
            ProfileCall = yes,
            io.write_string("MR_localcall(", !IO),
            output_label(Label, !IO),
            io.write_string(",\n\t\t", !IO),
            output_code_addr(Continuation, !IO)
        ;
            ProfileCall = no,
            code_addr_to_string_base(Continuation, BaseStr,
                NeedsPrefix, Wrapper),
            (
                NeedsPrefix = no,
                io.write_string("MR_noprof_localcall(", !IO),
                output_label_no_prefix(Label, !IO),
                io.write_string(",\n\t\t", !IO),
                io.write_string(BaseStr, !IO),
                output_code_addr_from_pieces(BaseStr,
                    NeedsPrefix, Wrapper, !IO)
            ;
                NeedsPrefix = yes,
                Wrapper = wrapper_entry,
                io.write_string("MR_np_localcall_ent(", !IO),
                output_label_no_prefix(Label, !IO),
                io.write_string(",\n\t\t", !IO),
                io.write_string(BaseStr, !IO)
            ;
                NeedsPrefix = yes,
                Wrapper = wrapper_label,
                io.write_string("MR_np_localcall_lab(", !IO),
                output_label_no_prefix(Label, !IO),
                io.write_string(",\n\t\t", !IO),
                io.write_string(BaseStr, !IO)
            ;
                NeedsPrefix = yes,
                Wrapper = wrapper_none,
                io.write_string("MR_np_localcall(", !IO),
                output_label_no_prefix(Label, !IO),
                io.write_string(",\n\t\t", !IO),
                output_code_addr_from_pieces(BaseStr,
                    NeedsPrefix, Wrapper, !IO)
            )
        )
    ;
        Continuation = code_label(ContLabel),
        label_is_external_to_c_module(ContLabel) = no
    ->
        (
            ProfileCall = yes,
            io.write_string("MR_call_localret(", !IO),
            output_code_addr(Target, !IO),
            io.write_string(",\n\t\t", !IO),
            output_label(ContLabel, !IO)
        ;
            ProfileCall = no,
            code_addr_to_string_base(Target, BaseStr, NeedsPrefix, Wrapper),
            (
                NeedsPrefix = no,
                io.write_string("MR_noprof_call_localret(", !IO),
                output_code_addr_from_pieces(BaseStr,
                    NeedsPrefix, Wrapper, !IO),
                io.write_string(",\n\t\t", !IO),
                output_label(ContLabel, !IO)
            ;
                NeedsPrefix = yes,
                Wrapper = wrapper_entry,
                io.write_string("MR_np_call_localret_ent(", !IO),
                io.write_string(BaseStr, !IO),
                io.write_string(",\n\t\t", !IO),
                output_label_no_prefix(ContLabel, !IO)
            ;
                NeedsPrefix = yes,
                Wrapper = wrapper_label,
                % We should never get here; the conditions that lead here
                % in this switch should have been caught by the first
                % if-then-else condition that tests Target.
                unexpected(this_file, "output_call: calling label")
            ;
                NeedsPrefix = yes,
                Wrapper = wrapper_none,
                io.write_string("MR_np_call_localret(", !IO),
                output_code_addr_from_pieces(BaseStr,
                    NeedsPrefix, Wrapper, !IO),
                io.write_string(",\n\t\t", !IO),
                output_label_no_prefix(ContLabel, !IO)
            )
        )
    ;
        (
            ProfileCall = yes,
            io.write_string("MR_call(", !IO)
        ;
            ProfileCall = no,
            io.write_string("MR_noprof_call(", !IO)
        ),
        output_code_addr(Target, !IO),
        io.write_string(",\n\t\t", !IO),
        output_code_addr(Continuation, !IO)
    ),
    (
        ProfileCall = yes,
        io.write_string(",\n\t\t", !IO),
        output_label_as_code_addr(CallerLabel, !IO)
    ;
        ProfileCall = no
    ),
    io.write_string(");\n", !IO).

:- pred output_gc_livevals(llds_out_info::in, list(liveinfo)::in,
    io::di, io::uo) is det.

output_gc_livevals(Info, LiveVals, !IO) :-
    AutoComments = Info ^ lout_auto_comments,
    (
        AutoComments = yes,
        io.write_string("/*\n", !IO),
        io.write_string("* Garbage collection livevals info\n", !IO),
        output_gc_livevals_2(Info, LiveVals, !IO),
        io.write_string("*/\n", !IO)
    ;
        AutoComments = no
    ).

:- pred output_gc_livevals_2(llds_out_info::in, list(liveinfo)::in,
    io::di, io::uo) is det.

output_gc_livevals_2(_, [], !IO).
output_gc_livevals_2(Info, [LiveInfo | LiveInfos], !IO) :-
    LiveInfo = live_lvalue(Locn, LiveValueType, TypeParams),
    io.write_string("*\t", !IO),
    output_layout_locn(Info, Locn, !IO),
    io.write_string("\t", !IO),
    output_live_value_type(LiveValueType, !IO),
    io.write_string("\t", !IO),
    map.to_assoc_list(TypeParams, TypeParamList),
    output_gc_livevals_params(Info, TypeParamList, !IO),
    io.write_string("\n", !IO),
    output_gc_livevals_2(Info, LiveInfos, !IO).

:- pred output_gc_livevals_params(llds_out_info::in,
    assoc_list(tvar, set(layout_locn))::in, io::di, io::uo) is det.

output_gc_livevals_params(_, [], !IO).
output_gc_livevals_params(Info, [Var - LocnSet | VarLocnSets], !IO) :-
    term.var_to_int(Var, VarInt),
    io.write_int(VarInt, !IO),
    io.write_string(" - ", !IO),
    set.to_sorted_list(LocnSet, Locns),
    output_layout_locns(Info, Locns, !IO),
    io.write_string("  ", !IO),
    output_gc_livevals_params(Info, VarLocnSets, !IO).

:- pred output_layout_locns(llds_out_info::in, list(layout_locn)::in,
    io::di, io::uo) is det.

output_layout_locns(_,[], !IO).
output_layout_locns(Info, [Locn | Locns], !IO) :-
    output_layout_locn(Info, Locn, !IO),
    (
        Locns = []
    ;
        Locns = [_ | _],
        io.write_string(" and ", !IO),
        output_layout_locns(Info, Locns, !IO)
    ).

:- pred output_layout_locn(llds_out_info::in, layout_locn::in,
    io::di, io::uo) is det.

output_layout_locn(Info, Locn, !IO) :-
    (
        Locn = locn_direct(Lval),
        output_lval(Info, Lval, !IO)
    ;
        Locn = locn_indirect(Lval, Offset),
        io.write_string("offset ", !IO),
        io.write_int(Offset, !IO),
        io.write_string(" from ", !IO),
        output_lval(Info, Lval, !IO)
    ).

:- pred output_live_value_type(live_value_type::in, io::di, io::uo) is det.

output_live_value_type(live_value_succip, !IO) :-
    io.write_string("type succip", !IO).
output_live_value_type(live_value_curfr, !IO) :-
    io.write_string("type curfr", !IO).
output_live_value_type(live_value_maxfr, !IO) :-
    io.write_string("type maxfr", !IO).
output_live_value_type(live_value_redofr, !IO) :-
    io.write_string("type redofr", !IO).
output_live_value_type(live_value_redoip, !IO) :-
    io.write_string("type redoip", !IO).
output_live_value_type(live_value_hp, !IO) :-
    io.write_string("type hp", !IO).
output_live_value_type(live_value_trail_ptr, !IO) :-
    io.write_string("type trail_ptr", !IO).
output_live_value_type(live_value_ticket, !IO) :-
    io.write_string("type ticket", !IO).
output_live_value_type(live_value_region_disj, !IO) :-
    io.write_string("type region disj", !IO).
output_live_value_type(live_value_region_commit, !IO) :-
    io.write_string("type region commit", !IO).
output_live_value_type(live_value_region_ite, !IO) :-
    io.write_string("type region ite", !IO).
output_live_value_type(live_value_unwanted, !IO) :-
    io.write_string("unwanted", !IO).
output_live_value_type(live_value_var(Var, Name, Type, LldsInst), !IO) :-
    io.write_string("var(", !IO),
    term.var_to_int(Var, VarInt),
    io.write_int(VarInt, !IO),
    io.write_string(", ", !IO),
    io.write_string(Name, !IO),
    io.write_string(", ", !IO),
    % XXX Fake type varset
    varset.init(NewTVarset),
    mercury_output_type(NewTVarset, no, Type, !IO),
    io.write_string(", ", !IO),
    (
        LldsInst = llds_inst_ground,
        io.write_string("ground", !IO)
    ;
        LldsInst = llds_inst_partial(Inst),
        % XXX Fake inst varset
        varset.init(NewIVarset),
        mercury_output_inst(Inst, NewIVarset, !IO)
    ),
    io.write_string(")", !IO).

%----------------------------------------------------------------------------%
%
% Code for the output of a label instruction.
%

:- pred output_label_defn(label::in, io::di, io::uo) is det.

output_label_defn(entry_label(entry_label_exported, ProcLabel), !IO) :-
    io.write_string("MR_define_entry(", !IO),
    output_label(entry_label(entry_label_exported, ProcLabel), !IO),
    io.write_string(");\n", !IO).
output_label_defn(entry_label(entry_label_local, ProcLabel), !IO) :-
    io.write_string("MR_def_static(", !IO),
    output_proc_label_no_prefix(ProcLabel, !IO),
    io.write_string(")\n", !IO).
output_label_defn(entry_label(entry_label_c_local, ProcLabel), !IO) :-
    io.write_string("MR_def_local(", !IO),
    output_proc_label_no_prefix(ProcLabel, !IO),
    io.write_string(")\n", !IO).
output_label_defn(internal_label(Num, ProcLabel), !IO) :-
    io.write_string("MR_def_label(", !IO),
    output_proc_label_no_prefix(ProcLabel, !IO),
    io.write_string(",", !IO),
    io.write_int(Num, !IO),
    io.write_string(")\n", !IO).

:- pred maybe_output_update_prof_counter(llds_out_info::in, label::in,
    pair(label, set_tree234(label))::in, io::di, io::uo) is det.

maybe_output_update_prof_counter(Info, Label, CallerLabel - ContLabelSet,
        !IO) :-
    % If ProfileTime is no, the definition of MR_update_prof_current_proc
    % is empty anyway.
    ProfileTime = Info ^ lout_profile_time,
    (
        set_tree234.contains(ContLabelSet, Label),
        ProfileTime = yes
    ->
        io.write_string("\tMR_update_prof_current_proc(MR_LABEL_AP(", !IO),
        output_label_no_prefix(CallerLabel, !IO),
        io.write_string("));\n", !IO)
    ;
        true
    ).

%----------------------------------------------------------------------------%
%
% Code for the output of a goto instruction.
%

:- pred output_goto(llds_out_info::in, code_addr::in, label::in,
    io::di, io::uo) is det.

output_goto(Info, Target, CallerLabel, !IO) :-
    (
        Target = code_label(Label),
        % Note that we do some optimization here: instead of always outputting
        % `MR_GOTO(<label>)', we output different things for each different
        % kind of label.
        ProfileCalls = Info ^ lout_profile_calls,
        (
            Label = entry_label(entry_label_exported, _),
            (
                ProfileCalls = yes,
                io.write_string("MR_tailcall(", !IO),
                output_label_as_code_addr(Label, !IO),
                io.write_string(",\n\t\t", !IO),
                output_label_as_code_addr(CallerLabel, !IO),
                io.write_string(");\n", !IO)
            ;
                ProfileCalls = no,
                io.write_string("MR_np_tailcall_ent(", !IO),
                output_label_no_prefix(Label, !IO),
                io.write_string(");\n", !IO)
            )
        ;
            Label = entry_label(entry_label_local, _),
            (
                ProfileCalls = yes,
                io.write_string("MR_tailcall(", !IO),
                output_label_as_code_addr(Label, !IO),
                io.write_string(",\n\t\t", !IO),
                output_label_as_code_addr(CallerLabel, !IO),
                io.write_string(");\n", !IO)
            ;
                ProfileCalls = no,
                io.write_string("MR_np_tailcall_ent(", !IO),
                output_label_no_prefix(Label, !IO),
                io.write_string(");\n", !IO)
            )
        ;
            Label = entry_label(entry_label_c_local, _),
            (
                ProfileCalls = yes,
                io.write_string("MR_localtailcall(", !IO),
                output_label(Label, !IO),
                io.write_string(",\n\t\t", !IO),
                output_label_as_code_addr(CallerLabel, !IO),
                io.write_string(");\n", !IO)
            ;
                ProfileCalls = no,
                io.write_string("MR_np_localtailcall(", !IO),
                output_label_no_prefix(Label, !IO),
                io.write_string(");\n", !IO)
            )
        ;
            Label = internal_label(_, _),
            io.write_string("MR_GOTO_LAB(", !IO),
            output_label_no_prefix(Label, !IO),
            io.write_string(");\n", !IO)
        )
    ;
        Target = code_imported_proc(ProcLabel),
        ProfileCalls = Info ^ lout_profile_calls,
        (
            ProfileCalls = yes,
            io.write_string("MR_tailcall(MR_ENTRY(", !IO),
            output_proc_label(ProcLabel, !IO),
            io.write_string("),\n\t\t", !IO),
            output_label_as_code_addr(CallerLabel, !IO),
            io.write_string(");\n", !IO)
        ;
            ProfileCalls = no,
            io.write_string("MR_np_tailcall_ent(", !IO),
            output_proc_label_no_prefix(ProcLabel, !IO),
            io.write_string(");\n", !IO)
        )
    ;
        Target = code_succip,
        io.write_string("MR_proceed();\n", !IO)
    ;
        Target = do_succeed(Last),
        (
            Last = no,
            io.write_string("MR_succeed();\n", !IO)
        ;
            Last = yes,
            io.write_string("MR_succeed_discard();\n", !IO)
        )
    ;
        Target = do_redo,
        UseMacro = Info ^ lout_use_macro_for_redo_fail,
        (
            UseMacro = yes,
            io.write_string("MR_redo();\n", !IO)
        ;
            UseMacro = no,
            io.write_string("MR_GOTO(MR_ENTRY(MR_do_redo));\n", !IO)
        )
    ;
        Target = do_fail,
        UseMacro = Info ^ lout_use_macro_for_redo_fail,
        (
            UseMacro = yes,
            io.write_string("MR_fail();\n", !IO)
        ;
            UseMacro = no,
            io.write_string("MR_GOTO(MR_ENTRY(MR_do_fail));\n", !IO)
        )
    ;
        Target = do_trace_redo_fail_shallow,
        io.write_string("MR_GOTO(MR_ENTRY(MR_do_trace_redo_fail_shallow));\n",
            !IO)
    ;
        Target = do_trace_redo_fail_deep,
        io.write_string("MR_GOTO(MR_ENTRY(MR_do_trace_redo_fail_deep));\n",
            !IO)
    ;
        Target = do_call_closure(Variant),
        % see comment in output_call for why we use `noprof_' etc. here
        io.write_string("MR_set_prof_ho_caller_proc(", !IO),
        output_label_as_code_addr(CallerLabel, !IO),
        io.write_string(");\n\t", !IO),
        io.write_string("MR_np_tailcall_ent(do_call_closure_", !IO),
        io.write_string(ho_call_variant_to_string(Variant), !IO),
        io.write_string(");\n", !IO)
    ;
        Target = do_call_class_method(Variant),
        % see comment in output_call for why we use `noprof_' etc. here
        io.write_string("MR_set_prof_ho_caller_proc(", !IO),
        output_label_as_code_addr(CallerLabel, !IO),
        io.write_string(");\n\t", !IO),
        io.write_string("MR_np_tailcall_ent(do_call_class_method_", !IO),
        io.write_string(ho_call_variant_to_string(Variant), !IO),
        io.write_string(");\n", !IO)
    ;
        Target = do_not_reached,
        io.write_string("MR_tailcall(MR_ENTRY(MR_do_not_reached),\n\t\t",
            !IO),
        output_label_as_code_addr(CallerLabel, !IO),
        io.write_string(");\n", !IO)
    ).

%----------------------------------------------------------------------------%
%
% Code for the output of a computed_goto instruction.
%

:- pred output_label_list_or_not_reached(list(maybe(label))::in,
    io::di, io::uo) is det.

output_label_list_or_not_reached([], !IO).
output_label_list_or_not_reached([MaybeLabel | MaybeLabels], !IO) :-
    output_label_or_not_reached(MaybeLabel, !IO),
    output_label_list_or_not_reached_2(MaybeLabels, !IO).

:- pred output_label_list_or_not_reached_2(list(maybe(label))::in,
    io::di, io::uo) is det.

output_label_list_or_not_reached_2([], !IO).
output_label_list_or_not_reached_2([MaybeLabel | MaybeLabels], !IO) :-
    io.write_string(" MR_AND\n\t\t", !IO),
    output_label_or_not_reached(MaybeLabel, !IO),
    output_label_list_or_not_reached_2(MaybeLabels, !IO).

:- pred output_label_or_not_reached(maybe(label)::in, io::di, io::uo) is det.

output_label_or_not_reached(MaybeLabel, !IO) :-
    (
        MaybeLabel = yes(Label),
        io.write_string("MR_LABEL_AP(", !IO),
        output_label_no_prefix(Label, !IO),
        io.write_string(")", !IO)
    ;
        MaybeLabel = no,
        io.write_string("MR_ENTRY(MR_do_not_reached)", !IO)
    ).

%----------------------------------------------------------------------------%
%
% Code for the output of an incr_hp instruction.
%

:- pred output_incr_hp_no_reuse(llds_out_info::in, lval::in, maybe(tag)::in,
    maybe(int)::in, rval::in, string::in, may_use_atomic_alloc::in,
    maybe(rval)::in, pair(label, set_tree234(label))::in, io::di, io::uo)
    is det.

output_incr_hp_no_reuse(Info, Lval, MaybeTag, MaybeOffset, Rval, TypeMsg,
        MayUseAtomicAlloc, MaybeRegionRval, ProfInfo, !IO) :-
    (
        MaybeRegionRval = yes(RegionRval),
        (
            MaybeTag = no,
            io.write_string("MR_alloc_in_region(", !IO),
            output_lval_as_word(Info, Lval, !IO)
        ;
            MaybeTag = yes(Tag),
            io.write_string("MR_tag_alloc_in_region(", !IO),
            output_lval_as_word(Info, Lval, !IO),
            io.write_string(", ", !IO),
            output_tag(Tag, !IO)
        ),
        io.write_string(", ", !IO),
        output_rval(Info, RegionRval, !IO),
        io.write_string(", ", !IO),
        output_rval_as_type(Info, Rval, lt_word, !IO),
        io.write_string(")", !IO)
    ;
        MaybeRegionRval = no,
        ProfMem = Info ^ lout_profile_memory,
        (
            ProfMem = yes,
            (
                MaybeTag = no,
                (
                    MayUseAtomicAlloc = may_not_use_atomic_alloc,
                    io.write_string("MR_offset_incr_hp_msg(", !IO)
                ;
                    MayUseAtomicAlloc = may_use_atomic_alloc,
                    io.write_string("MR_offset_incr_hp_atomic_msg(", !IO)
                ),
                output_lval_as_word(Info, Lval, !IO)
            ;
                MaybeTag = yes(Tag),
                (
                    MayUseAtomicAlloc = may_not_use_atomic_alloc,
                    io.write_string("MR_tag_offset_incr_hp_msg(", !IO)
                ;
                    MayUseAtomicAlloc = may_use_atomic_alloc,
                    io.write_string(
                        "MR_tag_offset_incr_hp_atomic_msg(", !IO)
                ),
                output_lval_as_word(Info, Lval, !IO),
                io.write_string(", ", !IO),
                output_tag(Tag, !IO)
            ),
            io.write_string(", ", !IO),
            (
                MaybeOffset = no,
                io.write_string("0, ", !IO)
            ;
                MaybeOffset = yes(Offset),
                io.write_int(Offset, !IO),
                io.write_string(", ", !IO)
            ),
            output_rval_as_type(Info, Rval, lt_word, !IO),
            io.write_string(", ", !IO),
            ProfInfo = CallerLabel - _,
            output_label(CallerLabel, !IO),
            io.write_string(", """, !IO),
            c_util.output_quoted_string(TypeMsg, !IO),
            io.write_string(""")", !IO)
        ;
            ProfMem = no,
            (
                MaybeTag = no,
                (
                    MaybeOffset = yes(_),
                    (
                        MayUseAtomicAlloc = may_not_use_atomic_alloc,
                        io.write_string("MR_offset_incr_hp(", !IO)
                    ;
                        MayUseAtomicAlloc = may_use_atomic_alloc,
                        io.write_string("MR_offset_incr_hp_atomic(", !IO)
                    )
                ;
                    MaybeOffset = no,
                    (
                        MayUseAtomicAlloc = may_not_use_atomic_alloc,
                        io.write_string("MR_alloc_heap(", !IO)
                    ;
                        MayUseAtomicAlloc = may_use_atomic_alloc,
                        io.write_string("MR_alloc_heap_atomic(", !IO)
                    )
                ),
                output_lval_as_word(Info, Lval, !IO)
            ;
                MaybeTag = yes(Tag),
                (
                    MaybeOffset = yes(_),
                    (
                        MayUseAtomicAlloc = may_not_use_atomic_alloc,
                        io.write_string("MR_tag_offset_incr_hp(", !IO)
                    ;
                        MayUseAtomicAlloc = may_use_atomic_alloc,
                        io.write_string(
                            "MR_tag_offset_incr_hp_atomic(", !IO)
                    ),
                    output_lval_as_word(Info, Lval, !IO),
                    io.write_string(", ", !IO),
                    output_tag(Tag, !IO)
                ;
                    MaybeOffset = no,
                    (
                        MayUseAtomicAlloc = may_not_use_atomic_alloc,
                        io.write_string("MR_tag_alloc_heap(", !IO)
                    ;
                        MayUseAtomicAlloc = may_use_atomic_alloc,
                        io.write_string("MR_tag_alloc_heap_atomic(", !IO)
                    ),
                    output_lval_as_word(Info, Lval, !IO),
                    io.write_string(", ", !IO),
                    io.write_int(Tag, !IO)
                )
            ),
            io.write_string(", ", !IO),
            (
                MaybeOffset = yes(Offset),
                io.write_int(Offset, !IO),
                io.write_string(", ", !IO)
            ;
                MaybeOffset = no
            ),
            output_rval_as_type(Info, Rval, lt_word, !IO),
            io.write_string(")", !IO)
        )
    ).

%----------------------------------------------------------------------------%
%
% Code for the output of push_region_frame, region_fill_frame,
% region_set_fixed_slot and use_and_maybe_pop_region_frame instructions.
%

    % Our stacks grow upwards in that new stack frames have higher addresses
    % than old stack frames, but within in each stack frame, we compute the
    % address of stackvar N or framevar N by *subtracting* N from the address
    % of the top of (the non-fixed part of) the stack frame, so that e.g.
    % framevar N+1 is actually stored at a *lower* address than framevar N.
    %
    % The C code we interact with refers to embedded stack frames by the
    % starting (i.e. lowest) address.
    %
:- pred output_embedded_frame_addr(llds_out_info::in,
    embedded_stack_frame_id::in, io::di, io::uo) is det.

output_embedded_frame_addr(Info, EmbeddedFrame, !IO) :-
    EmbeddedFrame = embedded_stack_frame_id(MainStackId,
        _FirstSlot, LastSlot),
    FrameStartRval = stack_slot_num_to_lval_ref(MainStackId, LastSlot),
    output_rval_as_type(Info, FrameStartRval, lt_data_ptr, !IO).

:- func max_leaf_stack_frame_size = int.

% This should be kept in sync with the value of MR_stack_margin_size
% in runtime/mercury_wrapper.c. See the documentation there.
max_leaf_stack_frame_size = 128.

%----------------------------------------------------------------------------%
%
% Code for the output of reset_ticket instructions.
%

:- pred output_reset_trail_reason(reset_trail_reason::in, io::di, io::uo)
    is det.

output_reset_trail_reason(reset_reason_undo, !IO) :-
    io.write_string("MR_undo", !IO).
output_reset_trail_reason(reset_reason_commit, !IO) :-
    io.write_string("MR_commit", !IO).
output_reset_trail_reason(reset_reason_solve, !IO) :-
    io.write_string("MR_solve", !IO).
output_reset_trail_reason(reset_reason_exception, !IO) :-
    io.write_string("MR_exception", !IO).
output_reset_trail_reason(reset_reason_retry, !IO) :-
    io.write_string("MR_retry", !IO).
output_reset_trail_reason(reset_reason_gc, !IO) :-
    io.write_string("MR_gc", !IO).

%----------------------------------------------------------------------------%
%
% Code for the output of foreign_proc_code instructions.
%

:- pred output_foreign_proc_component(llds_out_info::in,
    foreign_proc_component::in, io::di, io::uo) is det.

output_foreign_proc_component(Info, Component, !IO) :-
    (
        Component = foreign_proc_inputs(Inputs),
        output_foreign_proc_inputs(Info, Inputs, !IO)
    ;
        Component = foreign_proc_outputs(Outputs),
        output_foreign_proc_outputs(Info, Outputs, !IO)
    ;
        Component = foreign_proc_user_code(MaybeContext, _, C_Code),
        ( C_Code = "" ->
            true
        ;
                % We should start the C_Code on a new line,
                % just in case it starts with a proprocessor directive.
            (
                MaybeContext = yes(Context),
                io.write_string("{\n", !IO),
                output_set_line_num(Info, Context, !IO),
                io.write_string(C_Code, !IO),
                io.write_string(";}\n", !IO),
                output_reset_line_num(Info, !IO)
            ;
                MaybeContext = no,
                io.write_string("{\n", !IO),
                io.write_string(C_Code, !IO),
                io.write_string(";}\n", !IO)
            )
        )
    ;
        Component = foreign_proc_raw_code(_, _, _, C_Code),
        io.write_string(C_Code, !IO)
    ;
        Component = foreign_proc_fail_to(Label),
        io.write_string(
            "if (!" ++ foreign_proc_succ_ind_name ++ ") MR_GOTO_LAB(", !IO),
        output_label_no_prefix(Label, !IO),
        io.write_string(");\n", !IO)
    ;
        Component = foreign_proc_noop
    ).

    % Output the local variable declarations at the top of the
    % foreign_proc code for C.
    %
:- pred output_foreign_proc_decls(list(foreign_proc_decl)::in, io::di, io::uo)
    is det.

output_foreign_proc_decls([], !IO).
output_foreign_proc_decls([Decl | Decls], !IO) :-
    (
        % Apart from special cases, the local variables are MR_Words
        Decl = foreign_proc_arg_decl(_Type, TypeString, VarName),
        io.write_string("\t", !IO),
        io.write_string(TypeString, !IO),
        io.write_string("\t", !IO),
        io.write_string(VarName, !IO),
        io.write_string(";\n", !IO)
    ;
        Decl = foreign_proc_struct_ptr_decl(StructTag, VarName),
        io.write_string("\tstruct ", !IO),
        io.write_string(StructTag, !IO),
        io.write_string("\t*", !IO),
        io.write_string(VarName, !IO),
        io.write_string(";\n", !IO)
    ),
    output_foreign_proc_decls(Decls, !IO).

    % Output declarations for any rvals used to initialize the inputs.
    %
:- pred output_record_foreign_proc_input_rval_decls(llds_out_info::in,
    list(foreign_proc_input)::in, decl_set::in, decl_set::out,
    io::di, io::uo) is det.

output_record_foreign_proc_input_rval_decls(_, [], !DeclSet, !IO).
output_record_foreign_proc_input_rval_decls(Info, [Input | Inputs],
        !DeclSet, !IO) :-
    Input = foreign_proc_input(_VarName, _VarType, _IsDummy, _OrigType, Rval,
        _, _),
    output_record_rval_decls_tab(Info, Rval, !DeclSet, !IO),
    output_record_foreign_proc_input_rval_decls(Info, Inputs, !DeclSet, !IO).

    % Output the input variable assignments at the top of the foreign code
    % for C.
    %
:- pred output_foreign_proc_inputs(llds_out_info::in,
    list(foreign_proc_input)::in, io::di, io::uo) is det.

output_foreign_proc_inputs(_, [], !IO).
output_foreign_proc_inputs(Info, [Input | Inputs], !IO) :-
    Input = foreign_proc_input(VarName, VarType, IsDummy, _OrigType, _Rval,
        _MaybeForeignTypeInfo, _BoxPolicy),
    (
        IsDummy = is_dummy_type,
        (
            % Avoid outputting an assignment for builtin dummy types.
            % For other dummy types we must output an assignment because
            % code in the foreign_proc body may examine the value.
            type_to_ctor_and_args(VarType, VarTypeCtor, []),
            check_builtin_dummy_type_ctor(VarTypeCtor) =
                is_builtin_dummy_type_ctor
        ->
            true
        ;
            io.write_string("\t" ++ VarName ++ " = 0;\n", !IO)
        )
    ;
        IsDummy = is_not_dummy_type,
        output_foreign_proc_input(Info, Input, !IO)
    ),
    output_foreign_proc_inputs(Info, Inputs, !IO).

    % Output an input variable assignment at the top of the foreign code
    % for C.
    %
:- pred output_foreign_proc_input(llds_out_info::in, foreign_proc_input::in,
    io::di, io::uo) is det.

output_foreign_proc_input(Info, Input, !IO) :-
    Input = foreign_proc_input(VarName, _VarType, _IsDummy, OrigType, Rval,
        MaybeForeignTypeInfo, BoxPolicy),
    io.write_string("\t", !IO),
    (
        BoxPolicy = always_boxed,
        io.write_string(VarName, !IO),
        io.write_string(" = ", !IO),
        output_rval_as_type(Info, Rval, lt_word, !IO)
    ;
        BoxPolicy = native_if_possible,
        (
            MaybeForeignTypeInfo = yes(ForeignTypeInfo),
            ForeignTypeInfo = foreign_proc_type(ForeignType, Assertions),
            % For foreign types for which c_type_is_word_sized_int_or_ptr
            % succeeds, the code in the else branch is not only correct,
            % it also generates faster code than would be generated by
            % the then branch, because MR_MAYBE_UNBOX_FOREIGN_TYPE
            % invokes memcpy when given a word-sized type.
            (
                (
                    c_type_is_word_sized_int_or_ptr(ForeignType)
                ;
                    list.member(foreign_type_can_pass_as_mercury_type,
                        Assertions)
                )
            ->
                % Note that for this cast to be correct the foreign
                % type must be a word sized integer or pointer type.
                io.write_string(VarName, !IO),
                io.write_string(" = ", !IO),
                io.write_string("(" ++ ForeignType ++ ") ", !IO),
                output_rval_as_type(Info, Rval, lt_word, !IO)
            ;
                io.write_string("MR_MAYBE_UNBOX_FOREIGN_TYPE(", !IO),
                io.write_string(ForeignType, !IO),
                io.write_string(", ", !IO),
                output_rval_as_type(Info, Rval, lt_word, !IO),
                io.write_string(", ", !IO),
                io.write_string(VarName, !IO),
                io.write_string(")", !IO)
            )
        ;
            MaybeForeignTypeInfo = no,
            io.write_string(VarName, !IO),
            io.write_string(" = ", !IO),
            ( OrigType = builtin_type(builtin_type_string) ->
                output_llds_type_cast(lt_string, !IO),
                output_rval_as_type(Info, Rval, lt_word, !IO)
            ; OrigType = builtin_type(builtin_type_float) ->
                output_rval_as_type(Info, Rval, lt_float, !IO)
            ;
                output_rval_as_type(Info, Rval, lt_word, !IO)
            )
        )
    ),
    io.write_string(";\n", !IO).

    % Output declarations for any lvals used for the outputs.
    %
:- pred output_record_foreign_proc_output_lval_decls(llds_out_info::in,
    list(foreign_proc_output)::in, decl_set::in, decl_set::out,
    io::di, io::uo) is det.

output_record_foreign_proc_output_lval_decls(_, [], !DeclSet, !IO).
output_record_foreign_proc_output_lval_decls(Info, [Output | Outputs],
        !DeclSet, !IO) :-
    Output = foreign_proc_output(Lval, _VarType, _IsDummy, _OrigType,
        _VarName, _, _),
    output_record_lval_decls_tab(Info, Lval, !DeclSet, !IO),
    output_record_foreign_proc_output_lval_decls(Info, Outputs,
        !DeclSet, !IO).

    % Output the output variable assignments at the bottom of the foreign code
    % for C.
    %
:- pred output_foreign_proc_outputs(llds_out_info::in,
    list(foreign_proc_output)::in, io::di, io::uo) is det.

output_foreign_proc_outputs(_, [], !IO).
output_foreign_proc_outputs(Info, [Output | Outputs], !IO) :-
    Output = foreign_proc_output(_Lval, _VarType, IsDummy, _OrigType,
        _VarName, _MaybeForeignType, _BoxPolicy),
    (
        IsDummy = is_dummy_type
    ;
        IsDummy = is_not_dummy_type,
        output_foreign_proc_output(Info, Output, !IO)
    ),
    output_foreign_proc_outputs(Info, Outputs, !IO).

    % Output a output variable assignment at the bottom of the foreign code
    % for C.
    %
:- pred output_foreign_proc_output(llds_out_info::in, foreign_proc_output::in,
    io::di, io::uo) is det.

output_foreign_proc_output(Info, Output, !IO) :-
    Output = foreign_proc_output(Lval, _VarType, _IsDummy, OrigType, VarName,
        MaybeForeignType, BoxPolicy),
    io.write_string("\t", !IO),
    (
        BoxPolicy = always_boxed,
        output_lval_as_word(Info, Lval, !IO),
        io.write_string(" = ", !IO),
        io.write_string(VarName, !IO)
    ;
        BoxPolicy = native_if_possible,
        (
            MaybeForeignType = yes(ForeignTypeInfo),
            ForeignTypeInfo = foreign_proc_type(ForeignType, Assertions),
            (
                list.member(foreign_type_can_pass_as_mercury_type, Assertions)
            ->
                output_lval_as_word(Info, Lval, !IO),
                io.write_string(" = ", !IO),
                output_llds_type_cast(lt_word, !IO),
                io.write_string(VarName, !IO)
            ;
                io.write_string("MR_MAYBE_BOX_FOREIGN_TYPE(", !IO),
                io.write_string(ForeignType, !IO),
                io.write_string(", ", !IO),
                io.write_string(VarName, !IO),
                io.write_string(", ", !IO),
                output_lval_as_word(Info, Lval, !IO),
                io.write_string(")", !IO)
            )
        ;
            MaybeForeignType = no,
            output_lval_as_word(Info, Lval, !IO),
            io.write_string(" = ", !IO),
            ( OrigType = builtin_type(BuiltinType) ->
                (
                    BuiltinType = builtin_type_string,
                    output_llds_type_cast(lt_word, !IO),
                    io.write_string(VarName, !IO)
                ;
                    BuiltinType = builtin_type_float,
                    io.write_string("MR_float_to_word(", !IO),
                    io.write_string(VarName, !IO),
                    io.write_string(")", !IO)
                ;
                    BuiltinType = builtin_type_char,
                    % Characters must be cast to MR_UnsignedChar to
                    % prevent sign-extension.
                    io.write_string("(MR_UnsignedChar) ", !IO),
                    io.write_string(VarName, !IO)
                ;
                    BuiltinType = builtin_type_int,
                    io.write_string(VarName, !IO)
                )
            ;
                io.write_string(VarName, !IO)
            )
        )
    ),
    io.write_string(";\n", !IO).

%----------------------------------------------------------------------------%

:- func this_file = string.

this_file = "llds_out_instr.m".

%---------------------------------------------------------------------------%
:- end_module llds_out_instr.
%---------------------------------------------------------------------------%
